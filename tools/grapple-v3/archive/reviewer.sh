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

  # Primary: include staged + unstaged changes against HEAD.
  d="$(git diff --unified=0 HEAD || true)"
  if [[ -n "$d" ]]; then
    printf "%s" "$d"
    return 0
  fi

  # Fallback: only when writer committed this round.
  if [[ "${GRAPPLE_V3_WRITER_COMMITTED_THIS_ROUND:-false}" == "true" ]]; then
    local pre_head="${GRAPPLE_V3_PRE_HEAD:-}"
    if [[ -n "$pre_head" ]] && git rev-parse --verify "$pre_head" >/dev/null 2>&1; then
      d="$(git diff --unified=0 "${pre_head}"..HEAD || true)"
      if [[ -n "$d" ]]; then
        printf "%s" "$d"
        return 0
      fi
    elif git rev-parse --verify HEAD~1 >/dev/null 2>&1; then
      d="$(git diff --unified=0 HEAD~1..HEAD || true)"
      if [[ -n "$d" ]]; then
        printf "%s" "$d"
        return 0
      fi
    fi
  fi

  printf ""
}

DIFF_CONTENT="$(get_diff)"

if [[ -z "$DIFF_CONTENT" ]]; then
  cat <<'JSON'
{"findings":[{"file":"<repo>","line":0,"severity":"medium","message":"no changes detected"}],"summary":"No changes detected; reviewer cannot evaluate this round.","pass":false}
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


def extract_fenced_json(s: str):
    m = re.search(r"```json\s*([\s\S]*?)\s*```", s, re.IGNORECASE)
    if not m:
        return None
    payload = m.group(1).strip()
    try:
        return json.loads(payload)
    except Exception:
        return None


def extract_brace_json_objects(s: str):
    objs = []
    decoder = json.JSONDecoder()
    i = 0
    while i < len(s):
      if s[i] != '{':
        i += 1
        continue
      try:
        obj, end = decoder.raw_decode(s[i:])
        if isinstance(obj, dict):
          objs.append(obj)
        i += end
      except Exception:
        i += 1
    return objs


def looks_like_review(o):
    return isinstance(o,dict) and 'pass' in o and 'summary' in o and 'findings' in o

candidates=[]

# direct full parse
try:
    obj=json.loads(text)
    if isinstance(obj, dict):
      candidates.append(obj)
except Exception:
    pass

# fenced json first (preferred)
fenced = extract_fenced_json(text)
if isinstance(fenced, dict):
    candidates.append(fenced)

# fallback brace matching
candidates.extend(extract_brace_json_objects(text))

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
