#!/usr/bin/env bash
set -euo pipefail

TASK_SUMMARY=""
PROJECT="/home/brk"
LOG_PATH=""
CHANGED_FILES=""
WHY_FAILED=""
ROUNDS="[]"
RISK="medium"
ACTION="needs redesign"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --task) TASK_SUMMARY="$2"; shift 2 ;;
    --project) PROJECT="$2"; shift 2 ;;
    --log-path) LOG_PATH="$2"; shift 2 ;;
    --changed-files) CHANGED_FILES="$2"; shift 2 ;;
    --why-failed) WHY_FAILED="$2"; shift 2 ;;
    --rounds-json) ROUNDS="$2"; shift 2 ;;
    --risk) RISK="$2"; shift 2 ;;
    --action) ACTION="$2"; shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

mkdir -p /home/brk/tools/grapple-v3/logs

if [[ -z "$LOG_PATH" ]]; then
  TS="$(date -u +%Y%m%dT%H%M%SZ)"
  LOG_PATH="/home/brk/tools/grapple-v3/logs/${TS}.json"
fi

# Ensure forensic log exists (append if already present)
if [[ ! -f "$LOG_PATH" ]]; then
  cat > "$LOG_PATH" <<JSON
{
  "timestamp_utc": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "task_summary": $(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$TASK_SUMMARY"),
  "project": $(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$PROJECT"),
  "changed_files": $(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$CHANGED_FILES"),
  "why_failed": $(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$WHY_FAILED"),
  "risk": $(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$RISK"),
  "action": $(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$ACTION"),
  "rounds": $ROUNDS
}
JSON
fi

WHAT_TRIED="$(python3 - <<'PY' "$ROUNDS"
import json,sys
try:
  rounds=json.loads(sys.argv[1])
except Exception:
  rounds=[]
lines=[]
for r in rounds:
  if not isinstance(r,dict):
    continue
  n=r.get('round','?')
  v=r.get('judge',{}).get('verdict','?') if isinstance(r.get('judge'),dict) else '?'
  reason=r.get('judge',{}).get('reason','') if isinstance(r.get('judge'),dict) else ''
  lines.append(f"- R{n}: {v} — {reason}".strip())
print("\n".join(lines) if lines else "- No rounds captured")
PY
)"

MSG=$(cat <<EOF
🚨 Grapple escalation — ${TASK_SUMMARY:-unknown task}

What changed: ${CHANGED_FILES:-unknown}
Why failed: ${WHY_FAILED:-No reason provided}
What was tried: ${WHAT_TRIED}
Risk: ${RISK} — ${WHY_FAILED:-see log}
Action: ${ACTION}

Full log: ${LOG_PATH#/home/brk/}
EOF
)

openclaw message send --channel telegram -t 1260478841 -m "$MSG" >/dev/null

echo "$LOG_PATH"
