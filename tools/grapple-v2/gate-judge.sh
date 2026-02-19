#!/usr/bin/env bash
# Gate 5: Judge (Composite Verdict)
set -euo pipefail
GATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${GATE_DIR}/lib.sh"

# Required env vars — gate results are passed as file paths to avoid ARG_MAX
: "${GATE2_RESULTS_FILE:?}" "${GATE3_RESULTS_FILE:?}" "${GATE4_RESULTS_FILE:?}" "${OVERRIDES:=[]}"

GATE2_RESULTS=$(jq '.' "$GATE2_RESULTS_FILE" 2>/dev/null || echo '{}')
GATE3_RESULTS=$(jq '.' "$GATE3_RESULTS_FILE" 2>/dev/null || echo '{}')
GATE4_RESULTS=$(jq '.' "$GATE4_RESULTS_FILE" 2>/dev/null || echo '{}')

# Pre-check: if any gate has hard_fail=true AND no override → auto-REJECT without LLM
_check_hard_fail() {
  local gate_num="$1" gate_results="$2"
  local has_hard_fail
  has_hard_fail=$(echo "$gate_results" | jq -r '.hard_fail // false')

  if [[ "$has_hard_fail" == "true" ]]; then
    # Check if there's an override for this gate
    local has_override
    has_override=$(echo "$OVERRIDES" | jq --arg g "gate${gate_num}" '[.[] | select(.gate == $g)] | length')
    if [[ "$has_override" -eq 0 ]]; then
      return 1  # hard fail, no override
    fi
  fi
  return 0
}

HARD_FAIL_REASONS=()

if ! _check_hard_fail 2 "$GATE2_RESULTS"; then
  HARD_FAIL_REASONS+=("Gate 2: hard fail (low score or critical findings)")
fi
if ! _check_hard_fail 3 "$GATE3_RESULTS"; then
  HARD_FAIL_REASONS+=("Gate 3: hard fail (unwired symbols)")
fi
if ! _check_hard_fail 4 "$GATE4_RESULTS"; then
  HARD_FAIL_REASONS+=("Gate 4: hard fail (unsatisfied requirements or unjustified scope violations)")
fi

# Auto-REJECT if any unoverridden hard fail — save tokens
if [[ ${#HARD_FAIL_REASONS[@]} -gt 0 ]]; then
  REASONS_JSON=$(printf '%s\n' "${HARD_FAIL_REASONS[@]}" | jq -R . | jq -s .)
  jq -n \
    --argjson reasons "$REASONS_JSON" \
    '{
      "verdict": "REJECT",
      "composite_score": 0,
      "hard_fail_triggered": true,
      "hard_fail_reasons": $reasons,
      "override_flags": [],
      "warnings": [],
      "required_actions": $reasons,
      "summary": "Auto-REJECT: one or more gates hard-failed without override."
    }'
  exit 2
fi

# No hard fails (or all overridden) — run LLM for nuanced verdict
check_circuit_breaker "coding" || exit 1

# Write gate results to ctx dir for template substitution (awk-based, safe for JSON)
if [[ -n "${GRAPPLE_CTX_DIR:-}" && -d "${GRAPPLE_CTX_DIR}" ]]; then
  echo "$GATE2_RESULTS" > "${GRAPPLE_CTX_DIR}/gate2_results.json"
  echo "$GATE3_RESULTS" > "${GRAPPLE_CTX_DIR}/gate3_results.json"
  echo "$GATE4_RESULTS" > "${GRAPPLE_CTX_DIR}/gate4_results.json"
fi

export GATE2_RESULTS GATE3_RESULTS GATE4_RESULTS OVERRIDES
PROMPT_FILE=$(make_prompt_file "${GATE_DIR}/prompts/judge.md.tmpl")

# Judge uses Opus 4.6 for heavy reasoning
GATE_MODEL="${GATE5_MODEL:-anthropic/claude-opus-4-6}"
GATE_FALLBACK="${GATE5_FALLBACK:-codex.claude.gg/gpt-5.3-codex}"
GATE_TIMEOUT="${GATE5_TIMEOUT:-180}"

GATE_JSON=$(run_gate "gate5_judge" "$GATE_TIMEOUT" "$GATE_MODEL" "$GATE_FALLBACK" "$PROMPT_FILE") || true

if [[ -z "$GATE_JSON" ]]; then
  err "Gate 5: Failed to parse judge output"
  jq -n '{
    "verdict": "REJECT",
    "composite_score": 0,
    "hard_fail_triggered": false,
    "hard_fail_reasons": [],
    "override_flags": [],
    "warnings": ["Gate 5 failed to produce valid JSON"],
    "required_actions": [],
    "summary": "Gate 5 judge failed to produce valid output. Defaulting to REJECT."
  }'
  exit 2
fi

# Map verdict to exit code: 0=APPROVE, 1=REVISE, 2=REJECT
VERDICT=$(echo "$GATE_JSON" | jq -r '.verdict // "REJECT"' | tr '[:lower:]' '[:upper:]')

case "$VERDICT" in
  APPROVE)
    echo "$GATE_JSON" | jq '. + {"hard_fail": false}'
    exit 0
    ;;
  REVISE)
    echo "$GATE_JSON" | jq '. + {"hard_fail": false}'
    exit 1
    ;;
  *)
    echo "$GATE_JSON" | jq '. + {"hard_fail": true}'
    exit 2
    ;;
esac
