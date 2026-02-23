#!/usr/bin/env bash
set -euo pipefail

TASK="${1:-}"
if [[ -z "$TASK" ]]; then
  echo "Usage: grapple-v3/grapple.sh \"task description\" [--project /path/to/repo] [--dry-run]" >&2
  exit 2
fi
shift || true

PROJECT="/home/brk"
DRY_RUN="false"
MAX_RETRIES=2

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project) PROJECT="$2"; shift 2 ;;
    --dry-run) DRY_RUN="true"; shift ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

mkdir -p /tmp/grapple-v3/events /tmp/grapple-v3/reviewed /tmp/grapple-v3/locks /home/brk/tools/grapple-v3/logs

RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$RANDOM-$RANDOM"
IDEMPOTENCY_KEY="grapple-v3-${RUN_ID}"
EVENT_FILE="/tmp/grapple-v3/events/${RUN_ID}.session-complete.json"
REVIEWED_MARKER="/tmp/grapple-v3/reviewed/${RUN_ID}.done"
LOCK_FILE="/tmp/grapple-v3/locks/grapple-v3.lock"
LOG_PATH="/home/brk/tools/grapple-v3/logs/${RUN_ID}.json"

cd "$PROJECT"

ROUND=0
ATTEMPT=0
VERDICT="retry"
RISK="medium"
WHY_FAILED=""
ACTION="accept"
HOOK_RECEIVED=false
WRITER_FAILED=false
WRITER_EXIT_CODE=0
WRITER_COMMITTED_THIS_ROUND=false
PRE_HEAD=""

ROUNDS_JSON='[]'

append_round() {
  local round_json="$1"
  ROUNDS_JSON="$(python3 - <<'PY' "$ROUNDS_JSON" "$round_json"
import json,sys
arr=json.loads(sys.argv[1])
obj=json.loads(sys.argv[2])
arr.append(obj)
print(json.dumps(arr, ensure_ascii=False))
PY
)"
}

trigger_review_once() {
  if [[ -f "$REVIEWED_MARKER" ]]; then
    return 0
  fi

  # local lock for fallback path idempotency
  exec 9>"$LOCK_FILE"
  flock -n 9 || { echo "Another grapple run in progress" >&2; exit 1; }

  if [[ -f "$REVIEWED_MARKER" ]]; then
    return 0
  fi

  local review_json judge_json retry_prompt diff_excerpt
  diff_excerpt="$(git diff --unified=0 HEAD 2>/dev/null | head -200 || true)"

  review_json="$({ /home/brk/tools/grapple-v3/reviewer.sh --project "$PROJECT" --round "$ROUND" --task "$TASK"; } | tail -n 1)"
  judge_json="$({ /home/brk/tools/grapple-v3/judge.sh --project "$PROJECT" --round "$ROUND" --review-json "$review_json" --history-json "$ROUNDS_JSON"; } | tail -n 1)"

  VERDICT="$(python3 - <<'PY' "$judge_json"
import json,sys
try:o=json.loads(sys.argv[1]);print(o.get('verdict','escalate'))
except Exception:print('escalate')
PY
)"
  WHY_FAILED="$(python3 - <<'PY' "$judge_json"
import json,sys
try:o=json.loads(sys.argv[1]);print(o.get('reason',''))
except Exception:print('judge parse error')
PY
)"
  RISK="$(python3 - <<'PY' "$judge_json"
import json,sys
try:o=json.loads(sys.argv[1]);print(o.get('risk','medium'))
except Exception:print('high')
PY
)"
  retry_prompt="$(python3 - <<'PY' "$judge_json"
import json,sys
try:o=json.loads(sys.argv[1]);print(o.get('retry_prompt',''))
except Exception:print('')
PY
)"

  append_round "$(python3 - <<'PY' "$ROUND" "$review_json" "$judge_json" "$diff_excerpt"
import json,sys
r,review,judge,diff = sys.argv[1:5]
obj={
  "round": int(r),
  "reviewer": json.loads(review) if review.strip().startswith('{') else {"raw":review},
  "judge": json.loads(judge) if judge.strip().startswith('{') else {"raw":judge},
  "diff_excerpt": diff,
}
print(json.dumps(obj, ensure_ascii=False))
PY
)"

  touch "$REVIEWED_MARKER"

  if [[ "$VERDICT" == "retry" ]]; then
    TASK="$TASK

[GRAPPLE RETRY FEEDBACK - ROUND ${ROUND}]
${retry_prompt}
"
  fi
}

while (( ATTEMPT <= MAX_RETRIES )); do
  ROUND=$((ATTEMPT+1))
  export GRAPPLE_V3_RUN_ID="$RUN_ID"
  export GRAPPLE_V3_EVENT_FILE="$EVENT_FILE"
  export GRAPPLE_V3_IDEMPOTENCY_KEY="$IDEMPOTENCY_KEY"

  PRE_HEAD="$(git rev-parse HEAD 2>/dev/null || true)"
  WRITER_COMMITTED_THIS_ROUND=false

  if [[ "$DRY_RUN" == "true" ]]; then
    echo "[dry-run] would run: opencode run \"$TASK\""
  else
    if opencode run "$TASK" --dir "$PROJECT"; then
      :
    else
      WRITER_EXIT_CODE=$?
      WRITER_FAILED=true
      VERDICT="escalate"
      WHY_FAILED="writer failed with exit code ${WRITER_EXIT_CODE}"
      RISK="high"
      ACTION="writer failure"
      echo "Writer run failed (exit=${WRITER_EXIT_CODE}); skipping review" >&2
      break
    fi
  fi

  POST_HEAD="$(git rev-parse HEAD 2>/dev/null || true)"
  if [[ -n "$PRE_HEAD" && -n "$POST_HEAD" && "$PRE_HEAD" != "$POST_HEAD" ]]; then
    WRITER_COMMITTED_THIS_ROUND=true
  fi

  export GRAPPLE_V3_WRITER_COMMITTED_THIS_ROUND="$WRITER_COMMITTED_THIS_ROUND"
  export GRAPPLE_V3_PRE_HEAD="$PRE_HEAD"

  if [[ -f "$EVENT_FILE" ]]; then
    HOOK_RECEIVED=true
  fi

  # Fallback path: if hook didn't process review, do it here once.
  trigger_review_once

  if [[ "$VERDICT" == "pass" ]]; then
    ACTION="accept"
    break
  fi

  if [[ "$VERDICT" == "escalate" ]]; then
    ACTION="needs redesign"
    break
  fi

  ATTEMPT=$((ATTEMPT+1))
  rm -f "$REVIEWED_MARKER"
done

if [[ "$WRITER_FAILED" != "true" && "$VERDICT" != "pass" && "$VERDICT" != "escalate" ]]; then
  VERDICT="escalate"
  WHY_FAILED="max retries exceeded"
  RISK="high"
  ACTION="fix X"
fi

CHANGED_FILES="$(git diff --name-only HEAD | paste -sd ', ' -)"

python3 - <<'PY' "$LOG_PATH" "$RUN_ID" "$IDEMPOTENCY_KEY" "$TASK" "$PROJECT" "$HOOK_RECEIVED" "$VERDICT" "$WHY_FAILED" "$RISK" "$ATTEMPT" "$MAX_RETRIES" "$ROUNDS_JSON" "$CHANGED_FILES"
import json,sys,datetime
(out,run_id,key,task,project,hook,verdict,reason,risk,attempt,maxr,rounds,changed)=sys.argv[1:14]
obj={
  "timestamp_utc": datetime.datetime.utcnow().isoformat()+"Z",
  "run_id": run_id,
  "idempotency_key": key,
  "task_summary": task[:1000],
  "project": project,
  "hook_event_received": True if hook.lower()=="true" else False,
  "final": {
    "verdict": verdict,
    "reason": reason,
    "risk": risk,
    "attempts_used": int(attempt)+1,
    "max_retries": int(maxr),
  },
  "changed_files": [x.strip() for x in changed.split(',') if x.strip()],
  "rounds": json.loads(rounds),
}
with open(out,'w') as f:
  json.dump(obj,f,ensure_ascii=False,indent=2)
print(out)
PY

if [[ "$VERDICT" == "escalate" ]]; then
  /home/brk/tools/grapple-v3/notify.sh \
    --task "$TASK" \
    --project "$PROJECT" \
    --log-path "$LOG_PATH" \
    --changed-files "$CHANGED_FILES" \
    --why-failed "$WHY_FAILED" \
    --rounds-json "$ROUNDS_JSON" \
    --risk "$RISK" \
    --action "$ACTION" >/dev/null
fi

echo "grapple-v3 complete: verdict=$VERDICT log=$LOG_PATH"

if [[ "$WRITER_FAILED" == "true" ]]; then
  exit 1
fi
