#!/usr/bin/env bash
# Gate 3: Integration / Invocation Proof
set -euo pipefail
GATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${GATE_DIR}/lib.sh"

# Required env vars (large ones loaded from ctx files)
load_ctx_vars
: "${TASK_DESCRIPTION:?}" "${DIFF_CONTENT:?}" "${INVOCATION_CONTRACT:?}"
: "${FILE_TREE:=}" "${TRUST_PATTERNS_DATA:=}" "${CHANGED_FILES_LIST:=}"

# Validate contract schema before wasting tokens
if ! validate_contract "$INVOCATION_CONTRACT"; then
  echo '{"invocation_map":[],"unwired_symbols":[],"verdict":"FAIL","summary":"Contract schema validation failed. Fix the invocation contract before review.","hard_fail":true}'
  exit 1
fi

# Circuit breaker check
check_circuit_breaker "coding" || exit 1

# Build prompt
export TASK_DESCRIPTION INVOCATION_CONTRACT TRUST_PATTERNS_DATA CHANGED_FILES_LIST
PROMPT_FILE=$(make_prompt_file "${GATE_DIR}/prompts/integrator.md.tmpl")

# Run gate
GATE_MODEL="${GATE3_MODEL:-codex.claude.gg/gpt-5.3-codex}"
GATE_FALLBACK="${GATE3_FALLBACK:-anthropic/claude-opus-4-6}"
GATE_TIMEOUT="${GATE3_TIMEOUT:-180}"

GATE_JSON=$(run_gate "gate3_integrator" "$GATE_TIMEOUT" "$GATE_MODEL" "$GATE_FALLBACK" "$PROMPT_FILE") || true

if [[ -z "$GATE_JSON" ]]; then
  err "Gate 3: Failed to parse integrator output"
  echo '{"invocation_map":[],"unwired_symbols":[],"verdict":"FAIL","summary":"Gate 3 failed to produce valid JSON","hard_fail":true}'
  exit 3
fi

# Check for hard fail: unwired_symbols non-empty AND no trust pattern match
UNWIRED_COUNT=$(echo "$GATE_JSON" | jq '[.unwired_symbols // [] | .[]] | length')

if [[ "$UNWIRED_COUNT" -gt 0 ]]; then
  # Check if all unwired symbols are covered by trust patterns
  if [[ -n "$TRUST_PATTERNS_DATA" ]]; then
    UNCOVERED=$(echo "$GATE_JSON" | jq '[.unwired_symbols[] | select(.trust_pattern == null or .trust_pattern == "")] | length')
  else
    UNCOVERED="$UNWIRED_COUNT"
  fi

  if [[ "$UNCOVERED" -gt 0 ]]; then
    echo "$GATE_JSON" | jq '. + {"hard_fail": true}'
    exit 1
  fi
fi

echo "$GATE_JSON" | jq '. + {"hard_fail": false}'
exit 0
