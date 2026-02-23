#!/usr/bin/env bash
set -euo pipefail

PROJECT="/home/brk"
ROUND="0"
TASK_SUMMARY=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project) PROJECT="$2"; shift 2 ;;
    --round) ROUND="$2"; shift 2 ;;
    --task) TASK_SUMMARY="$2"; shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

cd "$PROJECT"

get_diff() {
  local d=""
  if git rev-parse --verify HEAD~1 >/dev/null 2>&1; then
    d=$(git diff --unified=0 HEAD~1..HEAD || true)
  fi
  if [[ -z "$d" ]]; then
    d=$(git diff --cached --unified=0 || true)
  fi
  if [[ -z "$d" ]]; then
    d=$(git diff --unified=0 || true)
  fi
  printf "%s" "$d"
}

DIFF_CONTENT="$(get_diff)"

if [[ -z "$DIFF_CONTENT" ]]; then
  cat <<'JSON'
{"findings":[],"summary":"No diff found; nothing to review.","pass":true}
JSON
  exit 0
fi

PAYLOAD_FILE="$(mktemp)"
RESP_FILE="$(mktemp)"

python3 - <<'PY' "$PAYLOAD_FILE" "$DIFF_CONTENT" "$ROUND" "$TASK_SUMMARY"
import json,sys
out,diff_content,round_no,task= sys.argv[1:5]
prompt = f"""You are a strict code reviewer.
Task summary: {task}
Round: {round_no}

Review this git diff and return ONLY valid JSON in this schema:
{{
  "findings": [{{"file":"path","line":123,"severity":"low|medium|high","message":"..."}}],
  "summary": "1-3 sentence summary",
  "pass": true|false
}}

Rules:
- Keep findings concise and actionable.
- If something is uncertain, mark severity as medium.
- If no meaningful issues, set pass=true and findings=[].

Diff:
{diff_content}
"""
payload = {
  "agentId": "worker",
  "label": f"grapple-v3-reviewer-r{round_no}",
  "model": "cliproxyapi/gpt-5.3-codex",
  "runTimeoutSeconds": 300,
  "task": prompt,
}
with open(out,"w") as f:
  json.dump(payload,f)
PY

call_spawn() {
  local method="$1"
  openclaw gateway call "$method" --json --expect-final --timeout 360000 --params "$(cat "$PAYLOAD_FILE")"
}

if ! call_spawn "sessions_spawn" >"$RESP_FILE" 2>/dev/null; then
  if ! call_spawn "sessions.spawn" >"$RESP_FILE" 2>/dev/null; then
    cat <<'JSON'
{"findings":[{"file":"<unknown>","line":0,"severity":"medium","message":"sessions_spawn unavailable; reviewer fallback used"}],"summary":"Could not execute sessions_spawn reviewer.","pass":false}
JSON
    exit 0
  fi
fi

python3 - <<'PY' "$RESP_FILE"
import json,re,sys
text=open(sys.argv[1]).read()

# Try direct JSON object first
try:
    obj=json.loads(text)
except Exception:
    obj=None

candidates=[]
if obj is not None:
    candidates.append(obj)

# Extract JSON snippets from raw output (best effort)
for m in re.finditer(r'\{[\s\S]*\}', text):
    s=m.group(0)
    try:
        candidates.append(json.loads(s))
    except Exception:
        pass

def looks_like_review(o):
    return isinstance(o,dict) and 'pass' in o and 'summary' in o and 'findings' in o

chosen=None
for c in reversed(candidates):
    if looks_like_review(c):
        chosen=c
        break

if chosen is None:
    chosen={
      "findings":[{"file":"<unknown>","line":0,"severity":"medium","message":"Reviewer output was not parseable JSON"}],
      "summary":"Unparseable reviewer output",
      "pass":False,
    }

print(json.dumps(chosen, ensure_ascii=False))
PY

rm -f "$PAYLOAD_FILE" "$RESP_FILE"
