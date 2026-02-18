#!/usr/bin/env bash
# grapple-pipeline.sh — Automatic code review pipeline
# Flow: Preflight → Writer → Capture → Skip → Lint Gate → Review → Fix Loop → Judge → Verdict
#
# Usage:
#   grapple-pipeline.sh --task "implement auth middleware" [--repo /path/to/repo]
#   grapple-pipeline.sh --task "desc" --story-mode --story-prd <prd> --story-id <id> --skip-writer
#
# Exit codes: 0=approved, 1=rejected, 2=blocked_precheck, 3=aborted, 4=error

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GRAPPLE_DIR="${GRAPPLE_DIR:-.grapple}"
MAX_ROUNDS=3
WRITER_MODEL="anthropic/claude-opus-4-6"
REVIEWER_MODEL="codex.claude.gg/gpt-5.3-codex"
JUDGE_MODEL="anthropic/claude-opus-4-6"
LOW_CONFIDENCE_THRESHOLD=60

# ── Colors ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

# ── State ────────────────────────────────────────────────────────────────────
TASK=""
REPO=""
TRACE_ROUNDS=()
FINAL_VERDICT=""
FINAL_EXIT=4
START_TIME=$(date +%s)
BASELINE_SHA=""

# ── Logging ──────────────────────────────────────────────────────────────────
log()  { echo -e "${BLUE}[grapple]${NC} $*" >&2; }
ok()   { echo -e "${GREEN}[grapple ✓]${NC} $*" >&2; }
warn() { echo -e "${YELLOW}[grapple ⚠]${NC} $*" >&2; }
err()  { echo -e "${RED}[grapple ✗]${NC} $*" >&2; }
step() { echo -e "${CYAN}[grapple →]${NC} $*" >&2; }

# ── Usage ────────────────────────────────────────────────────────────────────
usage() {
  cat <<'EOF'
Usage: grapple-pipeline.sh --task "description" [--repo /path]

Options:
  --task <desc>      Task description for the writer (required)
  --repo <path>      Repository path (default: current directory)
  --writer-model     Override writer model
  --reviewer-model   Override reviewer model
  --judge-model      Override judge model
  --max-rounds       Override max fix rounds (default: 3)
  --dry-run          Show what would happen without executing
  --story-mode       Enable story mode (scope review to story changes)
  --story-prd <path> PRD file path (story mode)
  --story-id <id>    Story ID (story mode)
  --skip-writer      Skip writer step (changes already made externally)
EOF
  exit 1
}

# ── Parse Args ───────────────────────────────────────────────────────────────
DRY_RUN=false
STORY_MODE=false
STORY_PRD=""
STORY_ID=""
SKIP_WRITER=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --task)           TASK="$2"; shift 2 ;;
    --repo)           REPO="$2"; shift 2 ;;
    --writer-model)   WRITER_MODEL="$2"; shift 2 ;;
    --reviewer-model) REVIEWER_MODEL="$2"; shift 2 ;;
    --judge-model)    JUDGE_MODEL="$2"; shift 2 ;;
    --max-rounds)     MAX_ROUNDS="$2"; shift 2 ;;
    --dry-run)        DRY_RUN=true; shift ;;
    --story-mode)     STORY_MODE=true; shift ;;
    --story-prd)      STORY_PRD="$2"; shift 2 ;;
    --story-id)       STORY_ID="$2"; shift 2 ;;
    --skip-writer)    SKIP_WRITER=true; shift ;;
    -h|--help)        usage ;;
    *)                err "Unknown option: $1"; usage ;;
  esac
done

[[ -z "$TASK" ]] && { err "Missing --task"; usage; }
REPO="${REPO:-$(pwd)}"
cd "$REPO"

# ── Ensure .grapple dir ─────────────────────────────────────────────────────
mkdir -p "$GRAPPLE_DIR"

# ── Load skip policy ────────────────────────────────────────────────────────
POLICY_FILE="${GRAPPLE_DIR}/policy.yml"
# Default skip patterns (used if policy.yml doesn't exist or can't be parsed)
SKIP_EXTENSIONS="png|jpg|jpeg|gif|ico|svg|woff|woff2|ttf|eot|mp3|mp4|webm|zip|tar|gz|bz2|7z|bin|exe|dll|so|dylib|pdf|lock|min.js|min.css|map"
SKIP_DIRS="vendor|node_modules|dist|build|.next|__pycache__|.git|coverage|.nyc_output"
SKIP_FILES="package-lock.json|yarn.lock|pnpm-lock.yaml|Cargo.lock|go.sum|composer.lock|Gemfile.lock|poetry.lock|Pipfile.lock"
DOCS_EXTENSIONS="md|txt|rst|adoc|org|csv|json|yaml|yml|toml|ini|cfg|conf|env.example"

# ── Helper: write trace JSON ────────────────────────────────────────────────
write_trace() {
  local verdict="$1" exit_code="$2" summary="$3"
  local end_time=$(date +%s)
  local duration=$((end_time - START_TIME))

  # Build rounds JSON array
  local rounds_json="["
  local first=true
  for r in "${TRACE_ROUNDS[@]}"; do
    if $first; then first=false; else rounds_json+=","; fi
    rounds_json+="$r"
  done
  rounds_json+="]"

  cat > "${GRAPPLE_DIR}/last-run.json" <<EOJSON
{
  "version": "1.0",
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "task": $(printf '%s' "$TASK" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))'),
  "repo": "$REPO",
  "verdict": "$verdict",
  "exit_code": $exit_code,
  "duration_seconds": $duration,
  "writer_model": "$WRITER_MODEL",
  "reviewer_model": "$REVIEWER_MODEL",
  "judge_model": "$JUDGE_MODEL",
  "baseline_sha": "$BASELINE_SHA",
  "final_sha": "$(git rev-parse HEAD 2>/dev/null || echo 'unknown')",
  "story_mode": $($STORY_MODE && echo 'true' || echo 'false'),
  "story_prd": $(printf '%s' "$STORY_PRD" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))'),
  "story_id": $(printf '%s' "$STORY_ID" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))'),
  "rounds": $rounds_json,
  "summary": $(printf '%s' "$summary" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))')
}
EOJSON
  ok "Trace written to ${GRAPPLE_DIR}/last-run.json"
}

# ── Helper: check if file should be skipped ─────────────────────────────────
should_skip_file() {
  local file="$1"
  local basename=$(basename "$file")
  local ext="${basename##*.}"
  local dir=$(dirname "$file")

  # Skip by directory
  if echo "$dir" | grep -qEi "(^|/)(${SKIP_DIRS})(/|$)"; then
    return 0
  fi

  # Skip by exact filename
  if echo "$basename" | grep -qEi "^(${SKIP_FILES})$"; then
    return 0
  fi

  # Skip by extension (binary/asset)
  if echo "$ext" | grep -qEi "^(${SKIP_EXTENSIONS})$"; then
    return 0
  fi

  # Skip generated files (common patterns)
  if echo "$file" | grep -qEi "(generated|\.gen\.|\.auto\.|\.pb\.go|_pb2\.py|\.g\.dart)"; then
    return 0
  fi

  return 1
}

# ── Helper: check if file is docs-only ──────────────────────────────────────
is_docs_file() {
  local file="$1"
  local ext="${file##*.}"
  if echo "$ext" | grep -qEi "^(${DOCS_EXTENSIONS})$"; then
    return 0
  fi
  return 1
}

# ── Helper: run linters on files ────────────────────────────────────────────
run_lint_gate() {
  local files=("$@")
  local lint_failed=false
  local lint_output=""

  # Detect available linters and run on relevant files
  local ts_files=() py_files=() go_files=() rs_files=()

  for f in "${files[@]}"; do
    case "${f##*.}" in
      ts|tsx|js|jsx|mjs|cjs) ts_files+=("$f") ;;
      py) py_files+=("$f") ;;
      go) go_files+=("$f") ;;
      rs) rs_files+=("$f") ;;
    esac
  done

  # TypeScript/JavaScript: eslint or tsc
  if [[ ${#ts_files[@]} -gt 0 ]]; then
    if command -v npx &>/dev/null && [[ -f "node_modules/.bin/eslint" || -f ".eslintrc"* || -f "eslint.config"* ]]; then
      step "Running ESLint on ${#ts_files[@]} file(s)..."
      if ! npx eslint --no-error-on-unmatched-pattern "${ts_files[@]}" 2>&1; then
        lint_failed=true
      fi
    fi
    if command -v npx &>/dev/null && [[ -f "tsconfig.json" ]]; then
      step "Running TypeScript check..."
      if ! npx tsc --noEmit 2>&1; then
        lint_failed=true
      fi
    fi
  fi

  # Python: pyright or mypy, then ruff or flake8
  if [[ ${#py_files[@]} -gt 0 ]]; then
    if command -v pyright &>/dev/null; then
      step "Running Pyright on ${#py_files[@]} file(s)..."
      if ! pyright "${py_files[@]}" 2>&1; then
        lint_failed=true
      fi
    elif command -v mypy &>/dev/null; then
      step "Running mypy on ${#py_files[@]} file(s)..."
      if ! mypy "${py_files[@]}" 2>&1; then
        lint_failed=true
      fi
    fi
    if command -v ruff &>/dev/null; then
      step "Running Ruff on ${#py_files[@]} file(s)..."
      if ! ruff check "${py_files[@]}" 2>&1; then
        lint_failed=true
      fi
    fi
  fi

  # Go
  if [[ ${#go_files[@]} -gt 0 ]] && command -v go &>/dev/null; then
    step "Running go vet..."
    if ! go vet ./... 2>&1; then
      lint_failed=true
    fi
  fi

  # Rust
  if [[ ${#rs_files[@]} -gt 0 ]] && command -v cargo &>/dev/null; then
    step "Running cargo check..."
    if ! cargo check 2>&1; then
      lint_failed=true
    fi
  fi

  if $lint_failed; then
    return 1
  fi
  return 0
}

# ── Helper: parse review JSON from opencode output ──────────────────────────
parse_review_json() {
  local output="$1"
  # Extract JSON block from output — look for the review JSON structure
  # Try to find JSON between ```json ... ``` or raw JSON with verdict field
  local json=""

  # Method 1: fenced code block
  json=$(echo "$output" | sed -n '/```json/,/```/p' | sed '1d;$d' | head -100)

  # Method 2: raw JSON object with verdict
  if [[ -z "$json" ]] || ! echo "$json" | python3 -c "import sys,json; json.load(sys.stdin)" 2>/dev/null; then
    json=$(echo "$output" | python3 -c "
import sys, json, re
text = sys.stdin.read()
# Find JSON objects containing 'verdict'
matches = re.findall(r'\{[^{}]*\"verdict\"[^{}]*\}', text, re.DOTALL)
if not matches:
    # Try multiline JSON
    matches = re.findall(r'\{(?:[^{}]|\{[^{}]*\})*\"verdict\"(?:[^{}]|\{[^{}]*\})*\}', text, re.DOTALL)
if matches:
    # Validate and print the last match (most likely the final verdict)
    for m in reversed(matches):
        try:
            obj = json.loads(m)
            print(json.dumps(obj))
            sys.exit(0)
        except:
            continue
sys.exit(1)
" 2>/dev/null)
  fi

  if [[ -n "$json" ]]; then
    echo "$json"
    return 0
  fi
  return 1
}

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 1: PREFLIGHT
# ═══════════════════════════════════════════════════════════════════════════════
step "STEP 1: Preflight checks"

if ! git rev-parse --is-inside-work-tree &>/dev/null; then
  err "Not a git repository: $REPO"
  write_trace "ERROR" 4 "Not a git repository"
  exit 4
fi

if ! command -v opencode &>/dev/null; then
  err "opencode not found in PATH"
  write_trace "ERROR" 4 "opencode not available"
  exit 4
fi

BASELINE_SHA=$(git rev-parse HEAD)
ok "Preflight passed — repo=$(basename "$REPO") sha=${BASELINE_SHA:0:8}"

if $DRY_RUN; then
  log "DRY RUN — would execute pipeline with task: $TASK"
  log "  Writer: $WRITER_MODEL | Reviewer: $REVIEWER_MODEL | Judge: $JUDGE_MODEL"
  log "  Max rounds: $MAX_ROUNDS"
  if $STORY_MODE; then
    log "  Story mode: $STORY_ID from $STORY_PRD"
  fi
  if $SKIP_WRITER; then
    log "  Writer: SKIPPED (--skip-writer)"
  fi
  exit 0
fi

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 2: WRITER — Execute the task (skip if --skip-writer)
# ═══════════════════════════════════════════════════════════════════════════════

if $SKIP_WRITER; then
  log "STEP 2: Skipping writer (--skip-writer, changes already present)"
else
  step "STEP 2: Writer executing task"

  WRITER_OUTPUT=$(timeout 600 opencode run \
    --model "$WRITER_MODEL" \
    --variant high \
    "$TASK" 2>&1) || {
    EXIT=$?
    if [[ $EXIT -eq 124 ]]; then
      err "Writer timed out after 600s"
      write_trace "ERROR" 4 "Writer timed out"
      exit 4
    fi
    warn "Writer exited with code $EXIT (may still have produced changes)"
  }

  ok "Writer completed"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 3: CAPTURE — Find changed files
# ═══════════════════════════════════════════════════════════════════════════════
step "STEP 3: Capturing changed files"

# Get all changed files (staged + unstaged + untracked new files)
CHANGED_FILES=()
while IFS= read -r file; do
  [[ -n "$file" ]] && CHANGED_FILES+=("$file")
done < <(git diff --name-only HEAD 2>/dev/null; git diff --name-only --cached 2>/dev/null; git ls-files --others --exclude-standard 2>/dev/null)

# Deduplicate
if [[ ${#CHANGED_FILES[@]} -gt 0 ]]; then
  readarray -t CHANGED_FILES < <(printf '%s\n' "${CHANGED_FILES[@]}" | sort -u)
fi

if [[ ${#CHANGED_FILES[@]} -eq 0 ]]; then
  warn "No files changed by writer"
  write_trace "SKIPPED" 0 "Writer produced no changes"
  exit 0
fi

ok "Found ${#CHANGED_FILES[@]} changed file(s)"

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 4: SKIP CHECK — Filter non-reviewable files
# ═══════════════════════════════════════════════════════════════════════════════
step "STEP 4: Skip check — filtering non-reviewable files"

REVIEWABLE_FILES=()
SKIPPED_FILES=()
DOCS_ONLY=true

for file in "${CHANGED_FILES[@]}"; do
  if should_skip_file "$file"; then
    SKIPPED_FILES+=("$file")
    continue
  fi
  if ! is_docs_file "$file"; then
    DOCS_ONLY=false
  fi
  REVIEWABLE_FILES+=("$file")
done

# If all reviewable files are docs-only, skip
if $DOCS_ONLY && [[ ${#REVIEWABLE_FILES[@]} -gt 0 ]]; then
  ok "All changes are docs-only — skipping review"
  write_trace "SKIPPED" 0 "Docs-only changes: ${REVIEWABLE_FILES[*]}"
  exit 0
fi

if [[ ${#SKIPPED_FILES[@]} -gt 0 ]]; then
  log "Skipped ${#SKIPPED_FILES[@]} file(s): ${SKIPPED_FILES[*]}"
fi

if [[ ${#REVIEWABLE_FILES[@]} -eq 0 ]]; then
  ok "No reviewable files after filtering — skipping"
  write_trace "SKIPPED" 0 "All files filtered by skip policy"
  exit 0
fi

ok "${#REVIEWABLE_FILES[@]} file(s) to review"

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 5: LINT GATE — Fail fast on broken code
# ═══════════════════════════════════════════════════════════════════════════════
step "STEP 5: Lint gate"

LINT_OUTPUT=""
if ! LINT_OUTPUT=$(run_lint_gate "${REVIEWABLE_FILES[@]}" 2>&1); then
  err "Lint gate FAILED — not sending to review"
  echo "$LINT_OUTPUT" >&2
  write_trace "BLOCKED_PRECHECK" 2 "Lint/typecheck failed: $(echo "$LINT_OUTPUT" | tail -5 | tr '\n' ' ')"
  exit 2
fi

ok "Lint gate passed"

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 6+7: REVIEW + FIX LOOP
# ═══════════════════════════════════════════════════════════════════════════════

# Build diff context for reviewer
build_review_context() {
  local diff_content
  diff_content=$(git diff HEAD -- "${REVIEWABLE_FILES[@]}" 2>/dev/null)
  if [[ -z "$diff_content" ]]; then
    diff_content=$(git diff -- "${REVIEWABLE_FILES[@]}" 2>/dev/null)
  fi
  # Also include untracked file contents
  for f in "${REVIEWABLE_FILES[@]}"; do
    if ! git ls-files --error-unmatch "$f" &>/dev/null 2>&1; then
      diff_content+=$'\n'"--- /dev/null"$'\n'"+++ b/$f"$'\n'
      diff_content+=$(cat "$f" 2>/dev/null | head -500)
    fi
  done
  echo "$diff_content"
}

ROUND=0
CURRENT_VERDICT=""
PREV_FINDINGS=""

while [[ $ROUND -lt $MAX_ROUNDS ]]; do
  ROUND=$((ROUND + 1))
  step "STEP 6: Review round $ROUND/$MAX_ROUNDS"

  DIFF_CONTEXT=$(build_review_context)
  FILES_LIST=$(printf '%s\n' "${REVIEWABLE_FILES[@]}")

  REVIEW_PROMPT="You are a critical code reviewer. Review these changes thoroughly.

CHANGED FILES:
${FILES_LIST}

DIFF:
${DIFF_CONTEXT}

TASK THAT WAS IMPLEMENTED:
${TASK}"

  # Add story context if in story mode
  if $STORY_MODE && [[ -n "$STORY_PRD" ]] && [[ -n "$STORY_ID" ]]; then
    REVIEW_PROMPT+="

STORY CONTEXT:
This change is part of story ${STORY_ID} from PRD: ${STORY_PRD}
Review ONLY the changes relevant to this story scope. Do not flag issues in unrelated code."
  fi

  REVIEW_PROMPT+="

INTEGRATION SAFETY (mandatory checks):
- Check all modified imports and verify they resolve to existing modules
- Verify API contracts (function signatures, return types) are not broken for callers
- Flag any changes to shared interfaces or exported symbols that could break dependents
- Confirm new dependencies are actually installed/available

INTENT VERIFICATION (mandatory checks):
- Compare the diff against the original task description
- Flag any files modified that are outside the task's stated scope
- Reject changes that add unrelated features or refactors not requested
- Verify the change actually addresses the stated problem (not just adjacent code)

You MUST output a JSON object (inside a \`\`\`json code fence) with this exact structure:
{
  \"verdict\": \"APPROVE\" | \"REVISE\" | \"REJECT\" | \"BLOCK\",
  \"confidence\": <0-100>,
  \"findings\": [
    {
      \"severity\": \"critical\" | \"major\" | \"minor\",
      \"category\": \"security\" | \"correctness\" | \"performance\" | \"style\" | \"architecture\" | \"integration\" | \"intent\",
      \"file\": \"path/to/file\",
      \"line\": <number or null>,
      \"description\": \"what's wrong\",
      \"suggestion\": \"how to fix\"
    }
  ],
  \"required_actions\": [\"action 1\", \"action 2\"],
  \"summary\": \"one paragraph review summary\"
}

VERDICT RULES:
- APPROVE: Code is good, no critical/major issues
- REVISE: Fixable issues found, writer should address them
- REJECT: Fundamental design problems, needs rethinking
- BLOCK: Security vulnerability or critical defect that must not ship

Be thorough. Quality over speed."

  REVIEW_OUTPUT=$(timeout 600 opencode run \
    --model "$REVIEWER_MODEL" \
    --variant high \
    "$REVIEW_PROMPT" 2>&1) || {
    EXIT=$?
    if [[ $EXIT -eq 124 ]]; then
      err "Reviewer timed out in round $ROUND"
      write_trace "ERROR" 4 "Reviewer timed out in round $ROUND"
      exit 4
    fi
    warn "Reviewer exited with code $EXIT"
  }

  # Parse review JSON
  REVIEW_JSON=""
  if ! REVIEW_JSON=$(parse_review_json "$REVIEW_OUTPUT"); then
    err "Failed to parse review JSON in round $ROUND — defaulting to REVISE"
    REVIEW_JSON='{"verdict":"REVISE","confidence":50,"findings":[],"required_actions":["Review output was unparseable — manual check needed"],"summary":"Reviewer output could not be parsed into structured JSON."}'
  fi

  CURRENT_VERDICT=$(echo "$REVIEW_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('verdict','REVISE'))" 2>/dev/null || echo "REVISE")
  CURRENT_CONFIDENCE=$(echo "$REVIEW_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('confidence',50))" 2>/dev/null || echo "50")
  CURRENT_FINDINGS=$(echo "$REVIEW_JSON" | python3 -c "import sys,json; print(json.dumps(json.load(sys.stdin).get('findings',[])))" 2>/dev/null || echo "[]")

  # Record round trace
  TRACE_ROUNDS+=("{\"round\":$ROUND,\"verdict\":\"$CURRENT_VERDICT\",\"confidence\":$CURRENT_CONFIDENCE,\"review\":$REVIEW_JSON}")

  ok "Round $ROUND verdict: $CURRENT_VERDICT (confidence: $CURRENT_CONFIDENCE)"

  # ── Check if we're done ──────────────────────────────────────────────────
  if [[ "$CURRENT_VERDICT" == "APPROVE" ]]; then
    ok "Reviewer approved!"
    FINAL_VERDICT="APPROVED"
    FINAL_EXIT=0
    break
  fi

  if [[ "$CURRENT_VERDICT" == "BLOCK" ]]; then
    err "Reviewer BLOCKED — critical defect"
    FINAL_VERDICT="REJECTED"
    FINAL_EXIT=1
    break
  fi

  if [[ "$CURRENT_VERDICT" == "REJECT" ]]; then
    warn "Reviewer REJECTED — will escalate to judge"
    break
  fi

  # REVISE — check if we should continue fixing
  if [[ $ROUND -ge $MAX_ROUNDS ]]; then
    warn "Hit max rounds ($MAX_ROUNDS) — escalating to judge"
    break
  fi

  # ── No-progress detection ────────────────────────────────────────────────
  if [[ -n "$PREV_FINDINGS" ]] && [[ "$PREV_FINDINGS" == "$CURRENT_FINDINGS" ]]; then
    warn "No progress detected — same findings as previous round"
    FINAL_VERDICT="ABORTED_NO_PROGRESS"
    FINAL_EXIT=3
    write_trace "ABORTED_NO_PROGRESS" 3 "Fix loop made no progress after $ROUND rounds"
    exit 3
  fi
  PREV_FINDINGS="$CURRENT_FINDINGS"

  # ── STEP 7: Writer fixes issues ─────────────────────────────────────────
  step "STEP 7: Writer fixing issues (round $ROUND)"

  REQUIRED_ACTIONS=$(echo "$REVIEW_JSON" | python3 -c "
import sys,json
data = json.load(sys.stdin)
actions = data.get('required_actions', [])
findings = data.get('findings', [])
parts = []
for a in actions:
    parts.append(f'- {a}')
for f in findings:
    if f.get('severity') in ('critical', 'major'):
        parts.append(f\"- Fix {f.get('severity')} {f.get('category','issue')} in {f.get('file','?')}: {f.get('description','')}\")
print('\n'.join(parts))
" 2>/dev/null || echo "- Fix all issues from review")

  FIX_PROMPT="You previously implemented this task: ${TASK}

The code reviewer found issues that need fixing. Address ALL of the following:

${REQUIRED_ACTIONS}

Reviewer summary: $(echo "$REVIEW_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('summary',''))" 2>/dev/null)

Fix these issues in the existing code. Do not rewrite from scratch — make targeted fixes."

  FIX_OUTPUT=$(timeout 600 opencode run \
    --model "$WRITER_MODEL" \
    --variant high \
    "$FIX_PROMPT" 2>&1) || {
    EXIT=$?
    warn "Writer fix exited with code $EXIT"
  }

  ok "Writer fix round $ROUND completed"

  # Re-run lint gate after fixes
  step "Re-running lint gate after fixes..."
  if ! LINT_OUTPUT=$(run_lint_gate "${REVIEWABLE_FILES[@]}" 2>&1); then
    err "Lint gate FAILED after fix round $ROUND"
    echo "$LINT_OUTPUT" >&2
    write_trace "BLOCKED_PRECHECK" 2 "Lint failed after fix round $ROUND"
    exit 2
  fi
  ok "Lint gate passed after fix"

  # Update changed files list
  while IFS= read -r file; do
    [[ -n "$file" ]] && CHANGED_FILES+=("$file")
  done < <(git diff --name-only HEAD 2>/dev/null; git diff --name-only --cached 2>/dev/null; git ls-files --others --exclude-standard 2>/dev/null)
  readarray -t CHANGED_FILES < <(printf '%s\n' "${CHANGED_FILES[@]}" | sort -u)

  # Re-filter
  REVIEWABLE_FILES=()
  for file in "${CHANGED_FILES[@]}"; do
    should_skip_file "$file" && continue
    REVIEWABLE_FILES+=("$file")
  done
done

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 8: JUDGE (if needed)
# ═══════════════════════════════════════════════════════════════════════════════

if [[ -z "$FINAL_VERDICT" ]]; then
  # Need judge: REJECT, or hit max rounds with REVISE, or low confidence
  if [[ "$CURRENT_VERDICT" == "REJECT" ]] || [[ $ROUND -ge $MAX_ROUNDS ]] || [[ $CURRENT_CONFIDENCE -lt $LOW_CONFIDENCE_THRESHOLD ]]; then
    step "STEP 8: Escalating to Judge"

    DIFF_CONTEXT=$(build_review_context)

    JUDGE_PROMPT="You are a senior engineering judge. You must make a final decision on this code.

TASK: ${TASK}

CHANGED FILES:
$(printf '%s\n' "${REVIEWABLE_FILES[@]}")

CURRENT DIFF:
${DIFF_CONTEXT}

REVIEW HISTORY (${#TRACE_ROUNDS[@]} rounds):
$(printf '%s\n' "${TRACE_ROUNDS[@]}")

The reviewer's last verdict was: ${CURRENT_VERDICT} (confidence: ${CURRENT_CONFIDENCE})

Your job: Look at the code objectively. Consider the reviewer's findings AND the writer's implementation.

Output a JSON object (inside a \`\`\`json code fence):
{
  \"verdict\": \"APPROVE\" | \"REJECT\",
  \"confidence\": <0-100>,
  \"reasoning\": \"detailed explanation of your decision\",
  \"summary\": \"one-line summary\"
}

You can ONLY output APPROVE or REJECT. No middle ground. Make the call."

    JUDGE_OUTPUT=$(timeout 600 opencode run \
      --model "$JUDGE_MODEL" \
      --variant high \
      "$JUDGE_PROMPT" 2>&1) || {
      EXIT=$?
      warn "Judge exited with code $EXIT"
    }

    JUDGE_JSON=""
    if JUDGE_JSON=$(parse_review_json "$JUDGE_OUTPUT"); then
      JUDGE_VERDICT=$(echo "$JUDGE_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin).get('verdict','REJECT'))" 2>/dev/null || echo "REJECT")
      TRACE_ROUNDS+=("{\"round\":\"judge\",\"verdict\":\"$JUDGE_VERDICT\",\"review\":$JUDGE_JSON}")

      if [[ "$JUDGE_VERDICT" == "APPROVE" ]]; then
        ok "Judge APPROVED"
        FINAL_VERDICT="APPROVED"
        FINAL_EXIT=0
      else
        err "Judge REJECTED"
        FINAL_VERDICT="REJECTED"
        FINAL_EXIT=1
      fi
    else
      err "Failed to parse judge output — defaulting to REJECT (safe default)"
      FINAL_VERDICT="REJECTED"
      FINAL_EXIT=1
      TRACE_ROUNDS+=("{\"round\":\"judge\",\"verdict\":\"REJECT\",\"review\":{\"verdict\":\"REJECT\",\"reasoning\":\"Judge output unparseable\"}}")
    fi
  fi
fi

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 9: OUTPUT
# ═══════════════════════════════════════════════════════════════════════════════
step "STEP 9: Final output"

SUMMARY="Pipeline completed in $ROUND round(s). Verdict: $FINAL_VERDICT."
write_trace "$FINAL_VERDICT" "$FINAL_EXIT" "$SUMMARY"

case "$FINAL_VERDICT" in
  APPROVED)
    ok "═══ APPROVED ═══ Pipeline passed after $ROUND round(s)"
    ;;
  REJECTED)
    err "═══ REJECTED ═══ Code did not pass review"
    ;;
  ABORTED_NO_PROGRESS)
    warn "═══ ABORTED ═══ Fix loop made no progress"
    ;;
  *)
    err "═══ ERROR ═══ Unexpected state: $FINAL_VERDICT"
    FINAL_EXIT=4
    ;;
esac

exit $FINAL_EXIT
