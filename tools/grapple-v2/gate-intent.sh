#!/usr/bin/env bash
# Gate 4: Intent Auditor (Spec Alignment Proof)
set -euo pipefail
GATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${GATE_DIR}/lib.sh"

# Required env vars (large ones loaded from ctx files)
load_ctx_vars
: "${TASK_DESCRIPTION:?}" "${DIFF_CONTENT:?}"
: "${TASK_TYPE:=}" "${ACCEPTANCE_CRITERIA:=}" "${INVOCATION_CONTRACT:=}" "${CHANGED_FILES_LIST:=}"

# Auto-detect task_type if not set
if [[ -z "$TASK_TYPE" ]]; then
  if [[ -n "$ACCEPTANCE_CRITERIA" ]]; then
    TASK_TYPE="structured"
  else
    TASK_TYPE="ad_hoc"
  fi
fi
export TASK_TYPE

# Circuit breaker check
check_circuit_breaker "coding" || exit 1

# Build prompt
export TASK_DESCRIPTION ACCEPTANCE_CRITERIA INVOCATION_CONTRACT CHANGED_FILES_LIST
PROMPT_FILE=$(make_prompt_file "${GATE_DIR}/prompts/intent.md.tmpl")

# Run gate
GATE_MODEL="${GATE4_MODEL:-codex.claude.gg/gpt-5.3-codex}"
GATE_FALLBACK="${GATE4_FALLBACK:-anthropic/claude-opus-4-6}"
GATE_TIMEOUT="${GATE4_TIMEOUT:-180}"

GATE_JSON=$(run_gate "gate4_intent" "$GATE_TIMEOUT" "$GATE_MODEL" "$GATE_FALLBACK" "$PROMPT_FILE") || true

if [[ -z "$GATE_JSON" ]]; then
  err "Gate 4: Failed to parse intent auditor output"
  echo '{"task_type":"'"$TASK_TYPE"'","traceability":[],"scope_violations":[],"verdict":"FAIL","summary":"Gate 4 failed to produce valid JSON","hard_fail":true}'
  exit 3
fi

# Hard fail logic depends on task type
if [[ "$TASK_TYPE" == "structured" ]]; then
  # Hard fail if any criterion is UNMAPPED/UNSATISFIED
  UNMAPPED=$(echo "$GATE_JSON" | jq '[.traceability // [] | .[] | select(.status == "UNMAPPED" or .status == "UNSATISFIED")] | length')
  if [[ "$UNMAPPED" -gt 0 ]]; then
    echo "$GATE_JSON" | jq '. + {"hard_fail": true}'
    exit 1
  fi
else
  # ad_hoc: hard fail only on unjustified scope violations
  UNJUSTIFIED=$(echo "$GATE_JSON" | jq '[.scope_violations // [] | .[] | select(.justification == null or .justification == "" or .justification == "none provided")] | length')
  if [[ "$UNJUSTIFIED" -gt 0 ]]; then
    echo "$GATE_JSON" | jq '. + {"hard_fail": true}'
    exit 1
  fi
fi

echo "$GATE_JSON" | jq '. + {"hard_fail": false}'
exit 0
