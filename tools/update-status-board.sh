#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOARD_FILE="/home/brk/status_board.txt"
HEALTH_LOG="/tmp/api_healthcheck.log"

# ── Timestamp (Istanbul) ─────────────────────────────────────────────
TIMESTAMP=$(TZ="Europe/Istanbul" date +"%H:%M Istanbul — %b %d, %Y")

# ── Worker status from worker-log.py ─────────────────────────────────
WORKER_STATUS=$(python3 "${SCRIPT_DIR}/worker-log.py" status 2>/dev/null || echo "⚠️ Worker log unavailable")

# ── Circuit breaker ──────────────────────────────────────────────────
CB_FILE="${SCRIPT_DIR}/circuit_breaker.json"
CB_STATUS=""
if [[ -f "$CB_FILE" ]]; then
  CB_STATUS=$(python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    cb = json.load(f)
parts = []
for cat, state in cb.items():
    icon = '🟢' if state.get('state') == 'closed' else '🔴'
    parts.append(f'{icon} {cat}: {state.get(\"state\", \"?\")} (fails: {state.get(\"failures\", 0)})')
print('\n'.join(parts))
" "$CB_FILE" 2>/dev/null || echo "⚠️ CB parse error")
else
  CB_STATUS="No state file"
fi

# ── API Health (from old underscore script) ──────────────────────────
HEALTH=""
if [[ -f "$HEALTH_LOG" ]]; then
  for provider in "img.claude.gg" "app.claude.gg" "codex.claude.gg" "GateAI" "Brave Search" "Vertex Wrapper" "Vertex Native"; do
    LINE=$(tail -14 "$HEALTH_LOG" | grep "$provider" | tail -1 || true)
    if echo "$LINE" | grep -q "OK"; then
      HEALTH="${HEALTH}  ✅ ${provider}"$'\n'
    elif echo "$LINE" | grep -q "FAIL"; then
      HEALTH="${HEALTH}  ❌ ${provider}"$'\n'
    elif echo "$LINE" | grep -q "SKIP"; then
      HEALTH="${HEALTH}  ⏭️ ${provider}"$'\n'
    fi
  done
fi

# ── Project status (from status_board.txt) ───────────────────────────
PROJECT_STATUS=""
if [[ -f "$BOARD_FILE" ]]; then
  PROJECT_STATUS=$(cat "$BOARD_FILE")
fi

# ── Build message ────────────────────────────────────────────────────
MSG="🕐 ${TIMESTAMP}

${WORKER_STATUS}"

if [[ -n "$HEALTH" ]]; then
  MSG="${MSG}

🔌 API Health:
${HEALTH}"
fi

if [[ -n "$PROJECT_STATUS" ]]; then
  MSG="${MSG}

📋 Projects:
${PROJECT_STATUS}"
fi

# ── Push to Telegram ─────────────────────────────────────────────────
openclaw message edit --channel telegram -t 1260478841 --message-id 843 -m "$MSG"

echo "$MSG"
echo ""
echo "✅ Status board pushed to Telegram (msg 843)"
