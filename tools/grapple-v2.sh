#!/usr/bin/env bash
# grapple-v2.sh — 5-Gate Review Pipeline Orchestrator
# See grapple-v2-prd.md for full specification.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/grapple-v2/lib.sh"

# ── Defaults ─────────────────────────────────────────────────────────────────
TASK_DESCRIPTION=""
INVOCATION_CONTRACT=""
SCOPED_FILES=""
TRUST_PATTERNS=""
OVERRIDE_LOG="[]"
NO_FIX=false
SKIP_GATES=""
EXHAUSTIVE=false
TASK_TYPE=""
ACCEPTANCE_CRITERIA=""
MAX_ROUNDS=3
WORK_DIR="$(pwd)"
TRACE_DIR=""
DRY_RUN=false
PIPELINE_TIMEOUT=900

# ── Arg Parsing ──────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --task)
      TASK_DESCRIPTION="$2"; shift 2 ;;
    --contract)
      INVOCATION_CONTRACT="$2"; shift 2 ;;
    --files)
      SCOPED_FILES="$2"; shift 2 ;;
    --trust-patterns)
      TRUST_PATTERNS="$2"; shift 2 ;;
    --override)
      # Parse gate:symbol:reason and append to JSON array
      IFS=':' read -r _ov_gate _ov_symbol _ov_reason <<< "$2"
      OVERRIDE_LOG=$(echo "$OVERRIDE_LOG" | jq \
        --arg gate "$_ov_gate" \
        --arg symbol "$_ov_symbol" \
        --arg reason "$_ov_reason" \
        '. + [{"gate": $gate, "symbol": $symbol, "reason": $reason, "flagged_by_judge": false}]')
      shift 2 ;;
    --no-fix)
      NO_FIX=true; shift ;;
    --skip-gates)
      SKIP_GATES="$2"; shift 2 ;;
    --exhaustive)
      EXHAUSTIVE=true; shift ;;
    --task-type)
      TASK_TYPE="$2"; shift 2 ;;
    --max-rounds)
      MAX_ROUNDS="$2"; shift 2 ;;
    --dir)
      WORK_DIR="$2"; shift 2 ;;
    --trace-dir)
      TRACE_DIR="$2"; shift 2 ;;
    --dry-run)
      DRY_RUN=true; shift ;;
    -h|--help)
      cat <<'USAGE'
Usage: grapple-v2.sh --task <description> [options]

Required:
  --task <description>          Task description

Options:
  --contract <text>             Invocation contract (entry_point, trigger, proof_method)
  --files <file1,file2,...>     Scope review to specific files
  --trust-patterns <file>       YAML file with project wiring patterns
  --override <gate:symbol:reason>  Per-symbol override (repeatable)
  --no-fix                      Review-only mode (skip Gate 1 writer)
  --skip-gates <1,3,4>          Skip specific gates (comma-separated)
  --exhaustive                  Run all gates even after hard fail
  --task-type <structured|ad_hoc>  Override auto-detection
  --max-rounds <n>              Max REVISE rounds (default: 3)
  --dir <path>                  Working directory (default: pwd)
  --trace-dir <path>            Trace output directory (default: .grapple/)
  --dry-run                     Print config without executing

Exit codes: 0=APPROVE, 1=REVISE, 2=REJECT, 3=ERROR, 4=TIMEOUT
USAGE
      exit 0 ;;
    *)
      err "Unknown flag: $1"; exit 3 ;;
  esac
done

# ── Validate Required Args ───────────────────────────────────────────────────
if [[ -z "$TASK_DESCRIPTION" ]]; then
  err "--task is required"
  exit 3
fi

# ── Setup ────────────────────────────────────────────────────────────────────
cd "$WORK_DIR"
TRACE_DIR="${TRACE_DIR:-${WORK_DIR}/.grapple}"
mkdir -p "$TRACE_DIR"
TRACE_FILE="${TRACE_DIR}/last-run.json"

# Trap cleanup
trap cleanup_temps EXIT

# Helper: check if a gate is skipped
_gate_skipped() {
  local gate="$1"
  # --no-fix implies skip gate 1
  if [[ "$gate" == "1" && "$NO_FIX" == "true" ]]; then
    return 0
  fi
  if [[ -n "$SKIP_GATES" ]]; then
    echo "$SKIP_GATES" | tr ',' '\n' | grep -qx "$gate"
    return $?
  fi
  return 1
}

# Require commands
require_cmd jq opencode git || { err "Missing required commands"; exit 3; }

# Circuit breaker
if ! check_circuit_breaker "coding"; then
  err "Circuit breaker BLOCKED for coding — aborting"
  exit 3
fi

# Validate contract if Gate 3 not skipped
if ! _gate_skipped 3; then
  if [[ -z "$INVOCATION_CONTRACT" ]]; then
    err "Invocation contract required when Gate 3 is active. Use --contract or --skip-gates 3"
    exit 3
  fi
  if ! validate_contract "$INVOCATION_CONTRACT"; then
    exit 3
  fi
fi

# Auto-detect task_type
if [[ -z "$TASK_TYPE" ]]; then
  if echo "$TASK_DESCRIPTION" | grep -qiE '(acceptance criteria|requirements?:|\b[0-9]+\.\s)'; then
    TASK_TYPE="structured"
    # Extract acceptance criteria from task description
    ACCEPTANCE_CRITERIA=$(echo "$TASK_DESCRIPTION" | sed -n '/[Aa]cceptance [Cc]riteria/,$ p' || true)
  else
    TASK_TYPE="ad_hoc"
  fi
fi

# Load trust patterns file content if provided
TRUST_PATTERNS_CONTENT=""
if [[ -n "$TRUST_PATTERNS" && -f "$TRUST_PATTERNS" ]]; then
  TRUST_PATTERNS_CONTENT=$(cat "$TRUST_PATTERNS")
fi

# Compute initial diff hash
INITIAL_DIFF_HASH=$(compute_diff_hash "$WORK_DIR")

# Build review context
CHANGED_FILES_LIST=""
if [[ -n "$SCOPED_FILES" ]]; then
  CHANGED_FILES_LIST="$SCOPED_FILES"
else
  CHANGED_FILES_LIST=$(git -C "${WORK_DIR}" diff --cached --name-only --diff-filter=ACMR 2>/dev/null || \
                       git -C "${WORK_DIR}" diff --name-only --diff-filter=ACMR HEAD 2>/dev/null || true)
  if [[ -z "$CHANGED_FILES_LIST" ]]; then
    CHANGED_FILES_LIST=$(git -C "${WORK_DIR}" diff --name-only HEAD~1 2>/dev/null || true)
  fi
fi

# Build skipped gates list for trace
SKIPPED_GATES_JSON="[]"
if [[ -n "$SKIP_GATES" ]]; then
  SKIPPED_GATES_JSON=$(echo "$SKIP_GATES" | tr ',' '\n' | jq -R . | jq -s .)
fi
if [[ "$NO_FIX" == "true" ]]; then
  SKIPPED_GATES_JSON=$(echo "$SKIPPED_GATES_JSON" | jq '. + ["1"] | unique')
fi

# ── Dry Run ──────────────────────────────────────────────────────────────────
if [[ "$DRY_RUN" == "true" ]]; then
  jq -n \
    --arg task "$TASK_DESCRIPTION" \
    --arg contract "$INVOCATION_CONTRACT" \
    --arg task_type "$TASK_TYPE" \
    --arg work_dir "$WORK_DIR" \
    --arg trace_dir "$TRACE_DIR" \
    --arg diff_hash "$INITIAL_DIFF_HASH" \
    --arg files "$CHANGED_FILES_LIST" \
    --argjson max_rounds "$MAX_ROUNDS" \
    --argjson exhaustive "$EXHAUSTIVE" \
    --argjson no_fix "$NO_FIX" \
    --argjson skip_gates "$SKIPPED_GATES_JSON" \
    --argjson overrides "$OVERRIDE_LOG" \
    '{
      mode: "dry-run",
      task: $task,
      contract: $contract,
      task_type: $task_type,
      work_dir: $work_dir,
      trace_dir: $trace_dir,
      diff_hash: $diff_hash,
      changed_files: $files,
      max_rounds: $max_rounds,
      exhaustive: $exhaustive,
      no_fix: $no_fix,
      skip_gates: $skip_gates,
      overrides: $overrides
    }'
  exit 0
fi

# ── Build Heavy Context (after dry-run check) ───────────────────────────────
# Cap FILE_TREE to avoid env size overflow (ARG_MAX)
FILE_TREE=$(find . -maxdepth 3 -not -path './.git/*' -not -path './node_modules/*' \
  -not -path './.grapple/*' 2>/dev/null | head -500 | sort || true)

DIFF_CONTENT=$(git diff HEAD 2>/dev/null || git diff --cached 2>/dev/null || true)
REVIEW_CONTEXT=$(build_review_context "$WORK_DIR")

# Write large context to temp files to avoid ARG_MAX overflow on export
_CTX_DIR=$(mktemp -d /tmp/grapple-ctx-XXXXXX)
_GRAPPLE_TEMPS+=("$_CTX_DIR")
echo "$FILE_TREE" > "$_CTX_DIR/file_tree.txt"
echo "$DIFF_CONTENT" > "$_CTX_DIR/diff_content.txt"
echo "$REVIEW_CONTEXT" > "$_CTX_DIR/review_context.txt"
export GRAPPLE_CTX_DIR="$_CTX_DIR"

# ── Pipeline State ───────────────────────────────────────────────────────────
ROUND=0
PREV_DIFF_HASH="$INITIAL_DIFF_HASH"
ROUNDS_JSON="[]"
FINAL_VERDICT=""
PIPELINE_START=$(date +%s)
BASELINE_SHA=$(git rev-parse HEAD 2>/dev/null || echo "unknown")

log "Starting Grapple v2 pipeline"
log "Task: ${TASK_DESCRIPTION:0:100}..."
log "Task type: $TASK_TYPE | Max rounds: $MAX_ROUNDS | Exhaustive: $EXHAUSTIVE"

# ── Main Pipeline Loop ───────────────────────────────────────────────────────
while true; do
  (( ROUND++ )) || true
  ROUND_START=$(date +%s)

  if (( ROUND > MAX_ROUNDS )); then
    warn "Max rounds ($MAX_ROUNDS) exceeded — exiting with REVISE"
    FINAL_VERDICT="REVISE"
    break
  fi

  log "═══ Round $ROUND / $MAX_ROUNDS ═══"

  # Check pipeline timeout
  ELAPSED=$(( $(date +%s) - PIPELINE_START ))
  if (( ELAPSED > PIPELINE_TIMEOUT )); then
    err "Pipeline timeout (${PIPELINE_TIMEOUT}s) exceeded"
    FINAL_VERDICT="TIMEOUT"
    break
  fi

  # ── Gate 1: Writer ───────────────────────────────────────────────────────
  if ! _gate_skipped 1; then
    log "Gate 1: Running writer..."

    WRITER_MODEL="${GATE1_MODEL:-anthropic/claude-opus-4-6}"
    export TASK_DESCRIPTION INVOCATION_CONTRACT REVIEW_CONTEXT
    WRITER_PROMPT_FILE=$(make_prompt_file "${SCRIPT_DIR}/grapple-v2/prompts/writer.md.tmpl")

    WRITER_EXIT=0
    timeout 300 opencode run -m "$WRITER_MODEL" \
      "Execute the coding task in the attached file. Follow its instructions exactly." \
      --file "$WRITER_PROMPT_FILE" > /dev/null 2>&1 || WRITER_EXIT=$?

    if (( WRITER_EXIT == 124 )); then
      err "Gate 1: Writer timed out (300s)"
      FINAL_VERDICT="TIMEOUT"
      break
    elif (( WRITER_EXIT != 0 )); then
      err "Gate 1: Writer failed with exit code $WRITER_EXIT"
      FINAL_VERDICT="ERROR"
      break
    fi

    ok "Gate 1: Writer completed"

    # Capture diff after writer
    DIFF_CONTENT=$(git diff HEAD 2>/dev/null || git diff --cached 2>/dev/null || true)
    CHANGED_FILES_LIST=$(git diff --name-only HEAD 2>/dev/null || git diff --cached --name-only 2>/dev/null || true)
    REVIEW_CONTEXT=$(build_review_context "$WORK_DIR")

    # Update ctx files with fresh content
    echo "$DIFF_CONTENT" > "$_CTX_DIR/diff_content.txt"
    echo "$REVIEW_CONTEXT" > "$_CTX_DIR/review_context.txt"

    # Diff hash check for round 2+
    CURRENT_DIFF_HASH=$(compute_diff_hash "$WORK_DIR")
    if (( ROUND > 1 )); then
      if [[ "$CURRENT_DIFF_HASH" == "$PREV_DIFF_HASH" ]]; then
        err "Writer produced identical diff after revision feedback. Human intervention required."
        FINAL_VERDICT="REJECT"
        break
      fi
    fi
    PREV_DIFF_HASH="$CURRENT_DIFF_HASH"

    # Lint gate (best-effort)
    if command -v npx &>/dev/null && [[ -f "package.json" ]]; then
      log "Running lint gate..."
      # Read file list into array to handle spaces in filenames safely
      _lint_files=()
      while IFS= read -r _lf; do [[ -n "$_lf" ]] && _lint_files+=("$_lf"); done <<< "$CHANGED_FILES_LIST"
      if [[ ${#_lint_files[@]} -gt 0 ]]; then
        npx eslint --no-error-on-unmatched-pattern "${_lint_files[@]}" 2>"${TRACE_DIR}/lint.stderr.log" || \
          warn "Lint gate: some issues found (non-blocking)"
      fi
    fi
  else
    log "Gate 1: Skipped"
    CURRENT_DIFF_HASH=$(compute_diff_hash "$WORK_DIR")
  fi

  # ── Incremental context for round 2+ ────────────────────────────────────
  if (( ROUND > 1 )); then
    log "Round $ROUND: using incremental review context"
    # Delta diff is already captured above (DIFF_CONTENT is current state)
  fi

  # ── Export env vars for gate scripts ─────────────────────────────────────
  # Large vars (DIFF_CONTENT, REVIEW_CONTEXT, FILE_TREE) are in $GRAPPLE_CTX_DIR files
  # to avoid ARG_MAX overflow. Gate scripts should read from files if GRAPPLE_CTX_DIR is set.
  export TASK_DESCRIPTION CHANGED_FILES_LIST
  export INVOCATION_CONTRACT
  export TRUST_PATTERNS_DATA="$TRUST_PATTERNS_CONTENT"
  export TASK_TYPE ACCEPTANCE_CRITERIA
  export GRAPPLE_ROUND="$ROUND"
  export GRAPPLE_CTX_DIR

  # ── Parallel Gates 2, 3, 4 ──────────────────────────────────────────────
  GATE2_OUTPUT_FILE=$(mktemp /tmp/grapple-gate2-XXXXXX.json)
  GATE3_OUTPUT_FILE=$(mktemp /tmp/grapple-gate3-XXXXXX.json)
  GATE4_OUTPUT_FILE=$(mktemp /tmp/grapple-gate4-XXXXXX.json)
  _GRAPPLE_TEMPS+=("$GATE2_OUTPUT_FILE" "$GATE3_OUTPUT_FILE" "$GATE4_OUTPUT_FILE")

  GATE2_PID="" GATE3_PID="" GATE4_PID=""
  GATE2_EXIT=0 GATE3_EXIT=0 GATE4_EXIT=0

  # Gate 2: Reviewer
  if ! _gate_skipped 2; then
    log "Gate 2: Launching reviewer..."
    bash "${SCRIPT_DIR}/grapple-v2/gate-reviewer.sh" > "$GATE2_OUTPUT_FILE" 2>"${TRACE_DIR}/gate2.stderr.log" &
    GATE2_PID=$!
  else
    log "Gate 2: Skipped"
    echo '{"findings":[],"score":100,"summary":"Gate 2 skipped","verdict":"PASS","hard_fail":false}' > "$GATE2_OUTPUT_FILE"
  fi

  # Gate 3: Integrator
  if ! _gate_skipped 3; then
    log "Gate 3: Launching integrator..."
    bash "${SCRIPT_DIR}/grapple-v2/gate-integrator.sh" > "$GATE3_OUTPUT_FILE" 2>"${TRACE_DIR}/gate3.stderr.log" &
    GATE3_PID=$!
  else
    log "Gate 3: Skipped"
    echo '{"invocation_map":[],"unwired_symbols":[],"summary":"Gate 3 skipped","verdict":"PASS","hard_fail":false}' > "$GATE3_OUTPUT_FILE"
  fi

  # Gate 4: Intent Auditor
  if ! _gate_skipped 4; then
    log "Gate 4: Launching intent auditor..."
    bash "${SCRIPT_DIR}/grapple-v2/gate-intent.sh" > "$GATE4_OUTPUT_FILE" 2>"${TRACE_DIR}/gate4.stderr.log" &
    GATE4_PID=$!
  else
    log "Gate 4: Skipped"
    echo '{"task_type":"'"$TASK_TYPE"'","traceability":[],"scope_violations":[],"summary":"Gate 4 skipped","verdict":"PASS","hard_fail":false}' > "$GATE4_OUTPUT_FILE"
  fi

  # Wait for gates and capture exit codes
  if [[ -n "$GATE2_PID" ]]; then
    wait "$GATE2_PID" && GATE2_EXIT=0 || GATE2_EXIT=$?
  fi
  if [[ -n "$GATE3_PID" ]]; then
    wait "$GATE3_PID" && GATE3_EXIT=0 || GATE3_EXIT=$?
  fi
  if [[ -n "$GATE4_PID" ]]; then
    wait "$GATE4_PID" && GATE4_EXIT=0 || GATE4_EXIT=$?
  fi

  # Log gate results (0=pass, 1=soft fail, 2=reject, 3=crash)
  [[ $GATE2_EXIT -eq 0 ]] && ok "Gate 2: PASS" || { [[ $GATE2_EXIT -eq 3 ]] && err "Gate 2: CRASH (exit $GATE2_EXIT)" || warn "Gate 2: FAIL (exit $GATE2_EXIT)"; }
  [[ $GATE3_EXIT -eq 0 ]] && ok "Gate 3: PASS" || { [[ $GATE3_EXIT -eq 3 ]] && err "Gate 3: CRASH (exit $GATE3_EXIT)" || warn "Gate 3: FAIL (exit $GATE3_EXIT)"; }
  [[ $GATE4_EXIT -eq 0 ]] && ok "Gate 4: PASS" || { [[ $GATE4_EXIT -eq 3 ]] && err "Gate 4: CRASH (exit $GATE4_EXIT)" || warn "Gate 4: FAIL (exit $GATE4_EXIT)"; }

  # ── Crash resilience: validate gate output files ────────────────────────
  for _gn in 2 3 4; do
    eval "_gfile=\$GATE${_gn}_OUTPUT_FILE"
    if [[ ! -s "$_gfile" ]] || ! jq -e '.' "$_gfile" >/dev/null 2>&1; then
      err "Gate ${_gn} CRASH: no valid JSON output"
      cat "${TRACE_DIR}/gate${_gn}.stderr.log" 2>/dev/null | tail -20 >&2
      echo "{\"hard_fail\":true,\"crash\":true,\"summary\":\"Gate ${_gn} failed to produce valid output\"}" > "$_gfile"
    fi
  done

  # ── Short-circuit check (parse hard_fail from JSON, not exit codes) ─────
  GATE2_HARD_FAIL=$(jq -r '.hard_fail // false' "$GATE2_OUTPUT_FILE" 2>/dev/null || echo "true")
  GATE3_HARD_FAIL=$(jq -r '.hard_fail // false' "$GATE3_OUTPUT_FILE" 2>/dev/null || echo "true")
  GATE4_HARD_FAIL=$(jq -r '.hard_fail // false' "$GATE4_OUTPUT_FILE" 2>/dev/null || echo "true")

  ANY_HARD_FAIL=false
  if [[ "$GATE2_HARD_FAIL" == "true" || "$GATE3_HARD_FAIL" == "true" || "$GATE4_HARD_FAIL" == "true" ]]; then
    ANY_HARD_FAIL=true
  fi

  if [[ "$ANY_HARD_FAIL" == "true" && "$EXHAUSTIVE" != "true" ]]; then
    warn "Short-circuit: gate hard-fail detected, proceeding to Judge with REJECT signal"
  fi

  # ── Gate 5: Judge ────────────────────────────────────────────────────────
  log "Gate 5: Running judge..."

  export GATE2_RESULTS_FILE="$GATE2_OUTPUT_FILE"
  export GATE3_RESULTS_FILE="$GATE3_OUTPUT_FILE"
  export GATE4_RESULTS_FILE="$GATE4_OUTPUT_FILE"
  export OVERRIDES="$OVERRIDE_LOG"

  GATE5_OUTPUT_FILE=$(mktemp /tmp/grapple-gate5-XXXXXX.json)
  _GRAPPLE_TEMPS+=("$GATE5_OUTPUT_FILE")

  JUDGE_EXIT=0
  bash "${SCRIPT_DIR}/grapple-v2/gate-judge.sh" > "$GATE5_OUTPUT_FILE" 2>"${TRACE_DIR}/gate5.stderr.log" || JUDGE_EXIT=$?

  GATE5_RESULTS=$(cat "$GATE5_OUTPUT_FILE" 2>/dev/null)
  [[ -z "$GATE5_RESULTS" ]] && GATE5_RESULTS='{}'
  JUDGE_VERDICT=$(echo "$GATE5_RESULTS" | jq -r '.verdict // "REJECT"' 2>/dev/null || echo "REJECT")

  # ── Record round in trace ────────────────────────────────────────────────
  ROUND_TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  ROUND_ENTRY=$(jq -n \
    --argjson round "$ROUND" \
    --arg timestamp "$ROUND_TIMESTAMP" \
    --argjson gate2 "$(jq '.' "$GATE2_OUTPUT_FILE" 2>/dev/null || echo '{}')" \
    --argjson gate3 "$(jq '.' "$GATE3_OUTPUT_FILE" 2>/dev/null || echo '{}')" \
    --argjson gate4 "$(jq '.' "$GATE4_OUTPUT_FILE" 2>/dev/null || echo '{}')" \
    --argjson gate5 "$(echo "$GATE5_RESULTS" | jq '.' 2>/dev/null || echo '{}')" \
    --arg diff_hash "${CURRENT_DIFF_HASH:-$INITIAL_DIFF_HASH}" \
    '{
      round: $round,
      timestamp: $timestamp,
      gate2: $gate2,
      gate3: $gate3,
      gate4: $gate4,
      gate5: $gate5,
      diff_hash: $diff_hash
    }')
  ROUNDS_JSON=$(echo "$ROUNDS_JSON" | jq --argjson entry "$ROUND_ENTRY" '. + [$entry]')

  # ── Verdict Handling ─────────────────────────────────────────────────────
  case "$JUDGE_VERDICT" in
    APPROVE)
      ok "Verdict: APPROVE (round $ROUND)"
      FINAL_VERDICT="APPROVE"
      break
      ;;
    REVISE)
      warn "Verdict: REVISE (round $ROUND / $MAX_ROUNDS)"
      if (( ROUND >= MAX_ROUNDS )); then
        warn "Max rounds reached — final verdict: REVISE"
        FINAL_VERDICT="REVISE"
        break
      fi
      # Loop continues to next round
      ;;
    REJECT)
      err "Verdict: REJECT (round $ROUND)"
      FINAL_VERDICT="REJECT"
      break
      ;;
    *)
      err "Unknown verdict from judge: $JUDGE_VERDICT"
      FINAL_VERDICT="ERROR"
      break
      ;;
  esac
done

# ── Write Final Trace ────────────────────────────────────────────────────────
PIPELINE_END=$(date +%s)
DURATION=$(( PIPELINE_END - PIPELINE_START ))
FINAL_SHA=$(git rev-parse HEAD 2>/dev/null || echo "unknown")
FINAL_DIFF_HASH=$(compute_diff_hash "$WORK_DIR")

# Map verdict to exit code
case "$FINAL_VERDICT" in
  APPROVE) EXIT_CODE=0 ;;
  REVISE)  EXIT_CODE=1 ;;
  REJECT)  EXIT_CODE=2 ;;
  ERROR)   EXIT_CODE=3 ;;
  TIMEOUT) EXIT_CODE=4 ;;
  *)       EXIT_CODE=3 ;;
esac

# Initialize trace file and write all fields via write_trace (shared function)
echo '{}' > "$TRACE_FILE"
write_trace "$TRACE_FILE" \
  '.version = $v | .timestamp = $ts | .task = $task | .task_type = $tt | .contract = $c | .repo = $r | .verdict = $vd | .exit_code = $ec | .duration_seconds = $dur | .baseline_sha = $bs | .final_sha = $fs | .diff_hash = $dh | .rounds = $rds | .final_verdict = $vd | .overrides = $ov | .skipped_gates = $sg' \
  --arg v "2.0" \
  --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
  --arg task "$TASK_DESCRIPTION" \
  --arg tt "$TASK_TYPE" \
  --arg c "$INVOCATION_CONTRACT" \
  --arg r "$WORK_DIR" \
  --arg vd "$FINAL_VERDICT" \
  --argjson ec "$EXIT_CODE" \
  --argjson dur "$DURATION" \
  --arg bs "$BASELINE_SHA" \
  --arg fs "$FINAL_SHA" \
  --arg dh "$FINAL_DIFF_HASH" \
  --argjson rds "$ROUNDS_JSON" \
  --argjson ov "$OVERRIDE_LOG" \
  --argjson sg "$SKIPPED_GATES_JSON"

log "Trace written to $TRACE_FILE"
log "Pipeline finished: $FINAL_VERDICT (${DURATION}s, $ROUND round(s))"

exit "$EXIT_CODE"
