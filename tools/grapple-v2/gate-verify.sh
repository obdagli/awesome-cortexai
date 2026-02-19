#!/usr/bin/env bash
# Gate 0: Verify — runs project-specific test/lint/build checks BEFORE LLM gates.
# If code doesn't pass execution checks, no point wasting tokens on AI review.
#
# Reads .grapple-ci.yml from WORK_DIR, or auto-detects from project files.
# Outputs structured JSON with check results and verdict.
set -euo pipefail

GATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${GATE_DIR}/lib.sh"

WORK_DIR="${WORK_DIR:-$(pwd)}"
cd "$WORK_DIR"

DEFAULT_TIMEOUT=120

# ── YAML Parser (python3, no pip deps) ───────────────────────────────────────
# Parses .grapple-ci.yml into JSON array of check objects.
# Each check: {"name": str, "command": str, "timeout": int, "required": bool}
parse_ci_config() {
  local config_file="$1"
  python3 -c "
import sys, json, re

config_file = sys.argv[1]
checks = []

with open(config_file) as f:
    lines = f.readlines()

current = None
in_checks = False

for line in lines:
    stripped = line.rstrip()

    # Top-level 'checks:' key
    if re.match(r'^checks:\s*$', stripped):
        in_checks = True
        continue

    if not in_checks:
        continue

    # New check item (- name: ...)
    m = re.match(r'^\s+-\s+name:\s*(.+)', stripped)
    if m:
        if current:
            checks.append(current)
        current = {
            'name': m.group(1).strip().strip('\"').strip(\"'\"),
            'command': '',
            'timeout': $DEFAULT_TIMEOUT,
            'required': True
        }
        continue

    if current is None:
        continue

    # command: ...
    m = re.match(r'^\s+command:\s*(.+)', stripped)
    if m:
        current['command'] = m.group(1).strip().strip('\"').strip(\"'\")
        continue

    # timeout: ...
    m = re.match(r'^\s+timeout:\s*(\d+)', stripped)
    if m:
        current['timeout'] = int(m.group(1))
        continue

    # required: ...
    m = re.match(r'^\s+required:\s*(true|false)', stripped, re.IGNORECASE)
    if m:
        current['required'] = m.group(1).lower() == 'true'
        continue

    # Non-indented line means end of checks block
    if not stripped.startswith(' ') and not stripped.startswith('\t') and stripped:
        break

if current:
    checks.append(current)

print(json.dumps(checks))
" "$config_file"
}

# ── Auto-detect checks from project files ────────────────────────────────────
auto_detect_checks() {
  local checks="[]"

  if [[ -f "package.json" ]]; then
    # Node.js project — check for scripts
    local has_lint has_test has_build
    has_lint=$(python3 -c "import json; d=json.load(open('package.json')); print('yes' if 'lint' in d.get('scripts',{}) else 'no')" 2>/dev/null || echo "no")
    has_test=$(python3 -c "import json; d=json.load(open('package.json')); print('yes' if 'test' in d.get('scripts',{}) else 'no')" 2>/dev/null || echo "no")
    has_build=$(python3 -c "import json; d=json.load(open('package.json')); print('yes' if 'build' in d.get('scripts',{}) else 'no')" 2>/dev/null || echo "no")

    # Detect package manager
    local pm="npm"
    [[ -f "pnpm-lock.yaml" ]] && pm="pnpm"
    [[ -f "yarn.lock" ]] && pm="yarn"
    [[ -f "bun.lockb" ]] && pm="bun"

    if [[ "$has_lint" == "yes" ]]; then
      checks=$(echo "$checks" | jq --arg cmd "$pm run lint" '. + [{"name":"lint","command":$cmd,"timeout":60,"required":true}]')
    fi
    if [[ "$has_test" == "yes" ]]; then
      checks=$(echo "$checks" | jq --arg cmd "$pm test" '. + [{"name":"test","command":$cmd,"timeout":120,"required":true}]')
    fi
    if [[ "$has_build" == "yes" ]]; then
      checks=$(echo "$checks" | jq --arg cmd "$pm run build" '. + [{"name":"build","command":$cmd,"timeout":120,"required":true}]')
    fi
    echo "$checks"
    return 0
  fi

  if [[ -f "pyproject.toml" ]]; then
    # Python project
    if command -v ruff &>/dev/null; then
      checks=$(echo "$checks" | jq '. + [{"name":"lint","command":"ruff check .","timeout":60,"required":true}]')
    elif command -v flake8 &>/dev/null; then
      checks=$(echo "$checks" | jq '. + [{"name":"lint","command":"flake8 .","timeout":60,"required":true}]')
    fi
    if command -v pytest &>/dev/null; then
      checks=$(echo "$checks" | jq '. + [{"name":"test","command":"pytest --tb=short -q","timeout":120,"required":true}]')
    fi
    echo "$checks"
    return 0
  fi

  if [[ -f "Makefile" ]]; then
    # Check for common make targets
    if grep -q '^lint:' Makefile 2>/dev/null; then
      checks=$(echo "$checks" | jq '. + [{"name":"lint","command":"make lint","timeout":60,"required":true}]')
    fi
    if grep -q '^test:' Makefile 2>/dev/null; then
      checks=$(echo "$checks" | jq '. + [{"name":"test","command":"make test","timeout":120,"required":true}]')
    fi
    if grep -q '^build:' Makefile 2>/dev/null; then
      checks=$(echo "$checks" | jq '. + [{"name":"build","command":"make build","timeout":120,"required":true}]')
    fi
    echo "$checks"
    return 0
  fi

  # Nothing detected
  echo "[]"
  return 1
}

# ── Run a single check ───────────────────────────────────────────────────────
run_check() {
  local name="$1"
  local command="$2"
  local check_timeout="$3"
  local required="$4"

  local start_time end_time duration exit_code output

  start_time=$(date +%s%N)
  output=$(timeout "$check_timeout" bash -c "$command" 2>&1) && exit_code=0 || exit_code=$?
  end_time=$(date +%s%N)

  # Duration in seconds with 1 decimal
  duration=$(python3 -c "print(round(($end_time - $start_time) / 1e9, 1))")

  # Timeout returns 124
  if (( exit_code == 124 )); then
    output="TIMEOUT after ${check_timeout}s"
  fi

  # Truncate output to 4KB to keep JSON manageable
  if (( ${#output} > 4096 )); then
    output="${output:0:4000}... [truncated, ${#output} bytes total]"
  fi

  local passed=false
  (( exit_code == 0 )) && passed=true

  jq -n \
    --arg name "$name" \
    --argjson passed "$passed" \
    --argjson duration "$duration" \
    --arg output "$output" \
    --argjson required "$required" \
    '{name: $name, passed: $passed, duration: $duration, output: $output, required: $required}'
}

# ── Main ─────────────────────────────────────────────────────────────────────
CHECKS_JSON="[]"
CONFIG_FILE="${WORK_DIR}/.grapple-ci.yml"

if [[ -f "$CONFIG_FILE" ]]; then
  log "Gate 0: Loading checks from .grapple-ci.yml"
  CHECKS_JSON=$(parse_ci_config "$CONFIG_FILE")
elif CHECKS_JSON=$(auto_detect_checks) && [[ "$CHECKS_JSON" != "[]" ]]; then
  log "Gate 0: Auto-detected checks from project files"
else
  # Nothing to verify — SKIP
  log "Gate 0: No .grapple-ci.yml and no project files detected — SKIP"
  jq -n '{checks: [], verdict: "SKIP", summary: "No verify configuration found and no project files detected", hard_fail: false}'
  exit 0
fi

# Validate we have checks
NUM_CHECKS=$(echo "$CHECKS_JSON" | jq 'length')
if (( NUM_CHECKS == 0 )); then
  log "Gate 0: Config found but no checks defined — SKIP"
  jq -n '{checks: [], verdict: "SKIP", summary: "Config found but no checks defined", hard_fail: false}'
  exit 0
fi

log "Gate 0: Running $NUM_CHECKS check(s)..."

# Run each check and collect results
RESULTS="[]"
TOTAL_PASS=0
TOTAL_FAIL=0
REQUIRED_FAIL=0

for i in $(seq 0 $(( NUM_CHECKS - 1 ))); do
  CHECK_NAME=$(echo "$CHECKS_JSON" | jq -r ".[$i].name")
  CHECK_CMD=$(echo "$CHECKS_JSON" | jq -r ".[$i].command")
  CHECK_TIMEOUT=$(echo "$CHECKS_JSON" | jq -r ".[$i].timeout")
  CHECK_REQUIRED=$(echo "$CHECKS_JSON" | jq -r ".[$i].required")

  log "  Running: $CHECK_NAME ($CHECK_CMD)"
  RESULT=$(run_check "$CHECK_NAME" "$CHECK_CMD" "$CHECK_TIMEOUT" "$CHECK_REQUIRED")

  PASSED=$(echo "$RESULT" | jq -r '.passed')
  DURATION=$(echo "$RESULT" | jq -r '.duration')

  if [[ "$PASSED" == "true" ]]; then
    ok "  ✓ $CHECK_NAME (${DURATION}s)"
    (( TOTAL_PASS++ )) || true
  else
    err "  ✗ $CHECK_NAME (${DURATION}s)"
    (( TOTAL_FAIL++ )) || true
    if [[ "$CHECK_REQUIRED" == "true" ]]; then
      (( REQUIRED_FAIL++ )) || true
    fi
  fi

  RESULTS=$(echo "$RESULTS" | jq --argjson r "$RESULT" '. + [$r]')
done

# Determine verdict
VERDICT="PASS"
HARD_FAIL=false
if (( REQUIRED_FAIL > 0 )); then
  VERDICT="FAIL"
  HARD_FAIL=true
elif (( TOTAL_FAIL > 0 )); then
  VERDICT="PASS"  # Non-required failures don't block
fi

SUMMARY="${TOTAL_PASS} passed, ${TOTAL_FAIL} failed (${REQUIRED_FAIL} required failures)"

log "Gate 0: $VERDICT — $SUMMARY"

# Output structured JSON
jq -n \
  --argjson checks "$RESULTS" \
  --arg verdict "$VERDICT" \
  --arg summary "$SUMMARY" \
  --argjson hard_fail "$HARD_FAIL" \
  '{checks: $checks, verdict: $verdict, summary: $summary, hard_fail: $hard_fail}'

if [[ "$HARD_FAIL" == "true" ]]; then
  exit 1
fi
exit 0
