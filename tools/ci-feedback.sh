#!/usr/bin/env bash
# ci-feedback.sh — Post-commit hook that runs Gate 0 (Verify)
# Skips if already inside grapple pipeline (GRAPPLE_RUNNING=1).
# Writes result to .grapple/last-verify.json.
# On failure, sends Telegram alert.
set -euo pipefail

# Skip if running inside grapple pipeline
if [[ "${GRAPPLE_RUNNING:-}" == "1" ]]; then
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE_VERIFY="${SCRIPT_DIR}/grapple-v2/gate-verify.sh"

if [[ ! -x "$GATE_VERIFY" ]]; then
  echo "[ci-feedback] gate-verify.sh not found at $GATE_VERIFY" >&2
  exit 1
fi

WORK_DIR="${WORK_DIR:-$(pwd)}"
GRAPPLE_DIR="${WORK_DIR}/.grapple"
mkdir -p "$GRAPPLE_DIR"

OUTPUT_FILE="${GRAPPLE_DIR}/last-verify.json"

# Run Gate 0
EXIT_CODE=0
WORK_DIR="$WORK_DIR" bash "$GATE_VERIFY" > "$OUTPUT_FILE" 2>/dev/null || EXIT_CODE=$?

# Parse result
VERDICT=$(jq -r '.verdict // "UNKNOWN"' "$OUTPUT_FILE" 2>/dev/null || echo "UNKNOWN")
SUMMARY=$(jq -r '.summary // "no summary"' "$OUTPUT_FILE" 2>/dev/null || echo "no summary")
HARD_FAIL=$(jq -r '.hard_fail // false' "$OUTPUT_FILE" 2>/dev/null || echo "false")

if [[ "$HARD_FAIL" == "true" ]]; then
  # Send Telegram alert
  COMMIT_SHA=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
  BRANCH=$(git branch --show-current 2>/dev/null || echo "unknown")
  PROJECT=$(basename "$WORK_DIR")

  MSG="⚠️ Verify FAILED after commit
Project: ${PROJECT}
Branch: ${BRANCH}
Commit: ${COMMIT_SHA}
Summary: ${SUMMARY}"

  if command -v openclaw &>/dev/null; then
    openclaw message send --channel telegram -t 1260478841 -m "$MSG" 2>/dev/null || true
  fi
fi

exit 0
