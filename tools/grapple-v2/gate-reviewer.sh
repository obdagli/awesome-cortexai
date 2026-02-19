#!/usr/bin/env bash
# Gate 2: Code Quality Review
set -euo pipefail
GATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${GATE_DIR}/lib.sh"

# Required env vars (large ones loaded from ctx files)
load_ctx_vars
: "${TASK_DESCRIPTION:?}" "${DIFF_CONTENT:?}" "${REVIEW_CONTEXT:=}" "${CHANGED_FILES_LIST:=}"

# Circuit breaker check
check_circuit_breaker "coding" || exit 1

# Build prompt
export TASK_DESCRIPTION CHANGED_FILES_LIST
PROMPT_FILE=$(make_prompt_file "${GATE_DIR}/prompts/reviewer.md.tmpl")

# Run gate
GATE_MODEL="${GATE2_MODEL:-codex.claude.gg/gpt-5.3-codex}"
GATE_FALLBACK="${GATE2_FALLBACK:-anthropic/claude-opus-4-6}"
GATE_TIMEOUT="${GATE2_TIMEOUT:-180}"

GATE_JSON=$(run_gate "gate2_reviewer" "$GATE_TIMEOUT" "$GATE_MODEL" "$GATE_FALLBACK" "$PROMPT_FILE") || true

if [[ -z "$GATE_JSON" ]]; then
  err "Gate 2: Failed to parse reviewer output"
  echo '{"findings":[],"score":0,"summary":"Gate 2 failed to produce valid JSON","verdict":"REJECT","hard_fail":true}'
  exit 3
fi

# Normalize output format — handle single finding object or findings array
if echo "$GATE_JSON" | jq -e '.findings' >/dev/null 2>&1; then
  : # Already has findings wrapper — good
elif echo "$GATE_JSON" | jq -e '.category' >/dev/null 2>&1; then
  # Single finding object — wrap it
  GATE_JSON=$(echo "$GATE_JSON" | jq '{findings: [.], score: (if .severity == "critical" then 25 elif .severity == "major" then 60 else 80 end), summary: .description, verdict: (if .severity == "critical" then "REJECT" elif .severity == "major" then "REVISE" else "APPROVE" end)}')
elif echo "$GATE_JSON" | jq -e 'type == "array"' >/dev/null 2>&1; then
  # Array of findings — wrap it
  GATE_JSON=$(echo "$GATE_JSON" | jq '{findings: ., score: (100 - ([.[] | if .severity == "critical" then 25 elif .severity == "major" then 10 else 2 end] | add // 0)), summary: "Auto-wrapped findings array", verdict: (if any(.[]; .severity == "critical") then "REJECT" elif any(.[]; .severity == "major") then "REVISE" else "APPROVE" end)}')
fi

# Check for hard fail
SCORE=$(echo "$GATE_JSON" | jq '(.score // 0) | floor')
HAS_CRITICAL=$(echo "$GATE_JSON" | jq '[(.findings // [])[] | select(.severity == "critical")] | length')

if [[ "$SCORE" -lt 50 ]] || [[ "$HAS_CRITICAL" -gt 0 ]]; then
  echo "$GATE_JSON" | jq '. + {"hard_fail": true}'
  exit 1
fi

echo "$GATE_JSON" | jq '. + {"hard_fail": false}'
exit 0
