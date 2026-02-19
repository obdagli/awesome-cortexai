#!/usr/bin/env bash
# grapple-v2/lib.sh — Shared functions for the 5-gate review pipeline
# Sourced by gate scripts and orchestrator. Never executed directly.
#
# Constraints (from PRD):
#   - All JSON composition via jq (NO shell string interpolation)
#   - All LLM calls via `opencode run --file <tempfile>`
#   - Temp files registered in array, cleaned via trap EXIT
#   - Token budget: 100K per gate
#   - Model fallback: primary + fallback

set -euo pipefail

# ── Colors ───────────────────────────────────────────────────────────────────
readonly _RED='\033[0;31m'
readonly _GREEN='\033[0;32m'
readonly _YELLOW='\033[1;33m'
readonly _BLUE='\033[0;34m'
readonly _CYAN='\033[0;36m'
readonly _NC='\033[0m'

# ── Temp File Registry ───────────────────────────────────────────────────────
declare -a _GRAPPLE_TEMPS=()

# ── 1. Colored Logging ──────────────────────────────────────────────────────
log()  { printf '%b[grapple]%b %s\n' "$_BLUE"   "$_NC" "$*" >&2; }
warn() { printf '%b[grapple ⚠]%b %s\n' "$_YELLOW" "$_NC" "$*" >&2; }
err()  { printf '%b[grapple ✗]%b %s\n' "$_RED"    "$_NC" "$*" >&2; }
ok()   { printf '%b[grapple ✓]%b %s\n' "$_GREEN"  "$_NC" "$*" >&2; }

# ── 1b. Load Large Context from Files ───────────────────────────────────────
# Gate scripts call this to load DIFF_CONTENT, REVIEW_CONTEXT, FILE_TREE
# from temp files written by the orchestrator (avoids ARG_MAX overflow).
load_ctx_vars() {
  if [[ -n "${GRAPPLE_CTX_DIR:-}" && -d "$GRAPPLE_CTX_DIR" ]]; then
    [[ -f "$GRAPPLE_CTX_DIR/diff_content.txt" ]] && DIFF_CONTENT=$(cat "$GRAPPLE_CTX_DIR/diff_content.txt")
    [[ -f "$GRAPPLE_CTX_DIR/review_context.txt" ]] && REVIEW_CONTEXT=$(cat "$GRAPPLE_CTX_DIR/review_context.txt")
    [[ -f "$GRAPPLE_CTX_DIR/file_tree.txt" ]] && FILE_TREE=$(cat "$GRAPPLE_CTX_DIR/file_tree.txt")
  fi
}

# ── 2. Require Command ──────────────────────────────────────────────────────
# Usage: require_cmd jq opencode git
require_cmd() {
  local cmd
  for cmd in "$@"; do
    if ! command -v "$cmd" &>/dev/null; then
      err "Required command not found: $cmd"
      return 1
    fi
  done
}

# ── 3. Build Review Context ─────────────────────────────────────────────────
# Captures changed file contents with safety limits.
# Args: $1 = repo path (default: .)
# Outputs: file contents to stdout
# Limits: 5000 files, 500KB total, 500 lines / 50KB per file
build_review_context() {
  local repo="${1:-.}"
  local max_files=5000
  local byte_budget=512000  # 500KB
  local bytes_used=0
  local files_captured=0
  local truncated=false

  if [[ ! -d "$repo" ]]; then
    err "build_review_context: repo directory does not exist: $repo"
    return 1
  fi

  if ! (cd "$repo" && git rev-parse --is-inside-work-tree &>/dev/null); then
    err "build_review_context: not a git repository: $repo"
    return 1
  fi

  local changed_files
  if (cd "$repo" && git rev-parse --verify HEAD~1 &>/dev/null); then
    changed_files=$(cd "$repo" && git diff --name-only --diff-filter=ACMR HEAD~1..HEAD 2>/dev/null || true)
  else
    # Initial commit fallback
    changed_files=$(cd "$repo" && git show HEAD --format="" --diff-filter=ACMR --name-only 2>/dev/null || true)
    if [[ -z "$changed_files" ]]; then
      changed_files=$(cd "$repo" && git diff --cached --name-only --diff-filter=ACMR 2>/dev/null || true)
    fi
  fi

  while IFS= read -r file; do
    [[ -z "$file" ]] && continue
    [[ ! -f "$repo/$file" ]] && continue

    if (( files_captured >= max_files )); then
      truncated=true
      warn "File capture: hit $max_files file cap"
      break
    fi

    local content
    content=$(head -500 "$repo/$file" 2>/dev/null | head -c 50000 || true)
    local content_size=${#content}

    if (( bytes_used + content_size > byte_budget )); then
      truncated=true
      warn "File capture: hit 500KB byte budget at $files_captured files"
      break
    fi

    printf '=== %s ===\n%s\n\n' "$file" "$content"
    (( bytes_used += content_size ))
    (( files_captured++ ))
  done <<< "$changed_files"

  # Write capture stats to stderr for trace logging
  if [[ "$truncated" == "true" ]]; then
    warn "File capture truncated: $files_captured files, $bytes_used bytes"
  else
    log "File capture: $files_captured files, $bytes_used bytes"
  fi
}

# ── 4. Parse Gate JSON ───────────────────────────────────────────────────────
# Extracts the first JSON object from LLM output (first '{' to last '}').
# Args: $1 = raw LLM output (string or file path with -f flag)
# Outputs: parsed JSON to stdout, returns 1 on failure
parse_gate_json() {
  local input=""
  if [[ "${1:-}" == "-f" ]]; then
    input=$(cat "$2" 2>/dev/null || true)
  else
    input="${1:-}"
  fi

  [[ -z "$input" ]] && { err "parse_gate_json: empty input"; return 1; }

  # Use python3 to find the first valid JSON object (robust against prose with braces)
  local result rc=0
  result=$(echo "$input" | python3 -c "
import sys, json
text = sys.stdin.read()
start = text.find('{')
while start != -1:
    depth = 0
    for i in range(start, len(text)):
        if text[i] == '{': depth += 1
        elif text[i] == '}': depth -= 1
        if depth == 0:
            try:
                obj = json.loads(text[start:i+1])
                print(json.dumps(obj))
                sys.exit(0)
            except json.JSONDecodeError:
                break
    start = text.find('{', start + 1)
sys.exit(1)
" 2>/dev/null) || rc=$?

  if [[ $rc -eq 0 && -n "$result" ]]; then
    echo "$result"
    return 0
  else
    err "parse_gate_json: no valid JSON object found in output"
    return 1
  fi
}

# ── 4b. Extract text from opencode --format json output ──────────────────────
# Reads JSONL events from opencode --format json and concatenates all "text" parts.
# Args: $1 = file containing JSONL output (with -f flag) or stdin
# Outputs: concatenated assistant text to stdout
extract_opencode_text() {
  local input=""
  if [[ "${1:-}" == "-f" && -n "${2:-}" ]]; then
    input=$(cat "$2" 2>/dev/null || true)
  else
    input=$(cat)
  fi

  [[ -z "$input" ]] && return 1

  echo "$input" | python3 -c "
import sys, json
parts = []
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        evt = json.loads(line)
        if evt.get('type') == 'text' and 'part' in evt:
            t = evt['part'].get('text', '')
            if t:
                parts.append(t)
    except (json.JSONDecodeError, KeyError):
        continue
print(''.join(parts))
" 2>/dev/null
}

# ── 5. Write Trace ──────────────────────────────────────────────────────────
# Write or update trace file using jq. No shell string interpolation for JSON.
# Args: $1 = trace file path, $2 = jq filter, $3... = jq --arg pairs
# Example: write_trace trace.json '.gates.gate2 = $val' --argjson val "$json"
write_trace() {
  local trace_file="$1"; shift
  local filter="$1"; shift

  if [[ ! -f "$trace_file" ]]; then
    echo '{}' > "$trace_file"
  fi

  local tmp
  tmp=$(mktemp)
  _GRAPPLE_TEMPS+=("$tmp")

  if jq "$filter" "$@" "$trace_file" > "$tmp" 2>/dev/null; then
    mv "$tmp" "$trace_file"
  else
    err "write_trace: jq filter failed: $filter"
    rm -f "$tmp"
    return 1
  fi
}

# ── 6. Check Circuit Breaker ────────────────────────────────────────────────
# Sources circuit-breaker.sh and checks the given category.
# Args: $1 = category (coding, search, media, general)
# Returns: 0 if OK, 1 if BLOCKED
check_circuit_breaker() {
  local category="${1:-coding}"
  local _lib_dir
  _lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  local cb_script="${_lib_dir}/../circuit-breaker.sh"

  if [[ ! -f "$cb_script" ]]; then
    warn "Circuit breaker script not found at $cb_script — skipping check"
    return 0
  fi

  # Save and override SCRIPT_DIR so circuit-breaker.sh finds its state file
  local _saved_script_dir="${SCRIPT_DIR:-}"
  SCRIPT_DIR="$(cd "$(dirname "$cb_script")" && pwd)"

  # shellcheck disable=SC1090
  source "$cb_script"

  # Restore SCRIPT_DIR
  SCRIPT_DIR="$_saved_script_dir"

  if cb_check "$category" 2>/dev/null; then
    return 0
  else
    err "Circuit breaker BLOCKED for category: $category"
    return 1
  fi
}

# ── 7. Make Prompt File ─────────────────────────────────────────────────────
# Creates a temp file from a template using envsubst. Registers for cleanup.
# Args: $1 = template path
# Outputs: path to temp file on stdout
make_prompt_file() {
  local template="$1"

  if [[ ! -f "$template" ]]; then
    err "make_prompt_file: template not found: $template"
    return 1
  fi

  local tmpfile
  tmpfile=$(mktemp --suffix=.md)
  _GRAPPLE_TEMPS+=("$tmpfile")

  # Use perl for template expansion to avoid ARG_MAX issues with envsubst.
  # Large vars (DIFF_CONTENT, REVIEW_CONTEXT, FILE_TREE) are read from ctx files;
  # smaller vars are read from the shell environment.
  local ctx="${GRAPPLE_CTX_DIR:-}"
  cp "$template" "$tmpfile"

  # Replace large vars from ctx files first
  if [[ -n "$ctx" && -d "$ctx" ]]; then
    for varname in DIFF_CONTENT REVIEW_CONTEXT FILE_TREE GATE2_RESULTS GATE3_RESULTS GATE4_RESULTS; do
      local fpath=""
      # Convert VAR_NAME to filename in ctx dir
      case "$varname" in
        DIFF_CONTENT)    fpath="$ctx/diff_content.txt" ;;
        REVIEW_CONTEXT)  fpath="$ctx/review_context.txt" ;;
        FILE_TREE)       fpath="$ctx/file_tree.txt" ;;
        GATE2_RESULTS)   fpath="$ctx/gate2_results.json" ;;
        GATE3_RESULTS)   fpath="$ctx/gate3_results.json" ;;
        GATE4_RESULTS)   fpath="$ctx/gate4_results.json" ;;
      esac
      if [[ -f "$fpath" ]] && grep -q "\${${varname}}" "$tmpfile"; then
        # Use awk index()+substr() for literal string replacement (not regex).
        # gsub() treats the pattern as regex, so ${VAR} metacharacters ($, {, })
        # would fail to match. index() does literal matching — safe for any placeholder.
        awk -v var="\${${varname}}" -v fpath="$fpath" '
          BEGIN {
            while ((getline line < fpath) > 0) { content = content (content ? "\n" : "") line }
          }
          {
            while ((idx = index($0, var)) > 0) {
              $0 = substr($0, 1, idx-1) content substr($0, idx + length(var))
            }
            print
          }
        ' "$tmpfile" > "${tmpfile}.tmp" && mv "${tmpfile}.tmp" "$tmpfile"
      fi
    done
  fi

  # Replace remaining small vars via envsubst (only small vars are exported)
  local small_vars='${TASK_DESCRIPTION} ${TASK_TYPE} ${INVOCATION_CONTRACT} ${ACCEPTANCE_CRITERIA} ${CHANGED_FILES_LIST} ${TRUST_PATTERNS_DATA} ${GRAPPLE_ROUND} ${OVERRIDES}'
  envsubst "$small_vars" < "$tmpfile" > "${tmpfile}.tmp" && mv "${tmpfile}.tmp" "$tmpfile"

  echo "$tmpfile"
}

# ── 8. Cleanup Temps ────────────────────────────────────────────────────────
# Removes all registered temp files. Intended as a trap EXIT handler.
cleanup_temps() {
  local f
  for f in "${_GRAPPLE_TEMPS[@]:-}"; do
    if [[ -n "$f" && -d "$f" ]]; then
      rm -rf "$f"
    elif [[ -n "$f" && -f "$f" ]]; then
      rm -f "$f"
    fi
  done
  _GRAPPLE_TEMPS=()
}

# Register cleanup on EXIT (idempotent — safe to source multiple times)
trap cleanup_temps EXIT

# ── 9. Validate Contract ────────────────────────────────────────────────────
# Checks that invocation contract has non-empty entry_point, trigger, proof_method.
# Args: $1 = contract text (multiline string)
# Returns: 0 if valid, 1 if invalid (with error message to stderr)
validate_contract() {
  local contract="${1:-${INVOCATION_CONTRACT:-}}"

  if [[ -z "$contract" ]]; then
    err "validate_contract: contract is empty"
    return 1
  fi

  local field value label
  for field in "entry_point:Entry point" "trigger:Trigger" "proof_method:Proof(?:\s*method)?"; do
    local key="${field%%:*}"
    label="${field#*:}"

    # Extract value after "Label:" — case insensitive, flexible formatting
    value=$(echo "$contract" | grep -ioP "${label}\s*:\s*\K.+" | head -1 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

    if [[ -z "$value" ]]; then
      err "Contract schema validation failed: $key is empty. Fix the invocation contract before review."
      return 1
    fi

    # Reject placeholder values (case-insensitive, strip trailing punctuation)
    local value_clean value_upper
    value_clean=$(echo "$value" | sed 's/[[:space:].,;:!?]*$//')
    value_upper=$(echo "$value_clean" | tr '[:lower:]' '[:upper:]')
    if [[ "$value_upper" == "TBD" || "$value_upper" == "TODO" || "$value_upper" == "N/A" ]]; then
      err "Contract schema validation failed: $key is a placeholder ($value). Fix the invocation contract before review."
      return 1
    fi
  done

  return 0
}

# ── 10. Compute Diff Hash ───────────────────────────────────────────────────
# SHA-256 of current diff for caching / identical-diff detection.
# Uses smart fallback chain: HEAD~1..HEAD → show HEAD (initial) → cached
# Args: $1 = repo path (default: .)
# Outputs: "sha256:<hash>" to stdout
compute_diff_hash() {
  local repo="${1:-.}"
  local diff_output=""

  if (cd "$repo" && git rev-parse --verify HEAD~1 &>/dev/null); then
    diff_output=$(cd "$repo" && git diff HEAD~1..HEAD 2>/dev/null || true)
  else
    # Initial commit — no HEAD~1
    diff_output=$(cd "$repo" && git show HEAD --format="" --diff-filter=ACMR 2>/dev/null || true)
    if [[ -z "$diff_output" ]]; then
      diff_output=$(cd "$repo" && git diff --cached 2>/dev/null || true)
    fi
  fi

  local hash
  hash=$(echo "$diff_output" | sha256sum | awk '{print $1}')
  echo "sha256:${hash}"
}

# ── 11. Run Gate ─────────────────────────────────────────────────────────────
# Generic gate runner. Runs an LLM call via opencode, captures output, parses JSON.
#
# Args:
#   $1 = gate name (for logging, e.g. "gate2_reviewer")
#   $2 = timeout in seconds
#   $3 = primary model
#   $4 = fallback model
#   $5 = prompt file path (created by make_prompt_file)
#
# Outputs: parsed JSON to stdout
# Returns: 0 on success, 1 on failure/hard-fail, 2 on timeout
run_gate() {
  local gate_name="$1"
  local gate_timeout="$2"
  local primary_model="$3"
  local fallback_model="$4"
  local prompt_file="$5"

  if [[ ! -f "$prompt_file" ]]; then
    err "run_gate($gate_name): prompt file not found: $prompt_file"
    return 1
  fi

  local output_file
  output_file=$(mktemp)
  _GRAPPLE_TEMPS+=("$output_file")

  local model="$primary_model"
  local fallback_used=false
  local attempt=0
  local max_attempts=2  # primary + 1 fallback

  while (( attempt < max_attempts )); do
    (( attempt++ ))
    log "run_gate($gate_name): attempt $attempt with model=$model, timeout=${gate_timeout}s"

    local exit_code=0
    local raw_output_file
    raw_output_file=$(mktemp)
    _GRAPPLE_TEMPS+=("$raw_output_file")

    timeout "$gate_timeout" opencode run -m "$model" \
      "Execute the review task in the attached file. Follow its instructions exactly and respond with ONLY the JSON object specified." \
      --file "$prompt_file" --format json \
      > "$raw_output_file" 2>/dev/null || exit_code=$?

    # Extract assistant text from JSONL events into output_file
    if [[ -s "$raw_output_file" ]]; then
      extract_opencode_text -f "$raw_output_file" > "$output_file"
    fi

    # Timeout returns 124
    if (( exit_code == 124 )); then
      warn "run_gate($gate_name): timeout after ${gate_timeout}s"
      if (( attempt < max_attempts )); then
        model="$fallback_model"
        fallback_used=true
        warn "run_gate($gate_name): falling back to $model"
        continue
      fi
      # Return partial output if available
      if [[ -s "$output_file" ]]; then
        warn "run_gate($gate_name): returning partial output after timeout"
        cat "$output_file"
      fi
      return 2
    fi

    # Non-zero exit (API error, rate limit, etc.)
    if (( exit_code != 0 )); then
      warn "run_gate($gate_name): opencode exited with code $exit_code"
      if (( attempt < max_attempts )); then
        model="$fallback_model"
        fallback_used=true
        warn "run_gate($gate_name): falling back to $model"
        continue
      fi
      return 1
    fi

    # Success — try to parse JSON from output
    local parsed_json
    if parsed_json=$(parse_gate_json -f "$output_file"); then
      if [[ "$fallback_used" == "true" ]]; then
        # Inject fallback metadata into the result
        parsed_json=$(echo "$parsed_json" | jq \
          --arg req "$primary_model" \
          --arg act "$model" \
          --arg reason "primary model failed on attempt $((attempt - 1))" \
          '. + {"_model_fallback": {"requested": $req, "actual": $act, "reason": $reason}}')
      fi
      echo "$parsed_json"
      return 0
    else
      err "run_gate($gate_name): failed to parse JSON from output"
      if (( attempt < max_attempts )); then
        model="$fallback_model"
        fallback_used=true
        warn "run_gate($gate_name): falling back to $model (parse failure)"
        continue
      fi
      return 1
    fi
  done

  return 1
}

# ── Resolve SCRIPT_DIR if not already set ────────────────────────────────────
SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
