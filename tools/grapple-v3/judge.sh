#!/usr/bin/env bash
set -euo pipefail

REVIEW_JSON=""
HISTORY_JSON="[]"
PROJECT="/home/brk"
ROUND="0"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --review-json) REVIEW_JSON="$2"; shift 2 ;;
    --history-json) HISTORY_JSON="$2"; shift 2 ;;
    --project) PROJECT="$2"; shift 2 ;;
    --round) ROUND="$2"; shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$REVIEW_JSON" ]]; then
  echo '{"verdict":"escalate","reason":"missing reviewer json","risk":"high","retry_prompt":""}'
  exit 0
fi

PAYLOAD_FILE="$(mktemp)"
RESP_FILE="$(mktemp)"

python3 - <<'PY' "$PAYLOAD_FILE" "$REVIEW_JSON" "$HISTORY_JSON" "$ROUND"
import json,sys
out,review_json,history_json,round_no = sys.argv[1:5]
try:
    review = json.loads(review_json)
except Exception:
    review = {"pass":False,"summary":"invalid review json","findings":[]}
try:
    history = json.loads(history_json)
except Exception:
    history = []

prompt = f"""You are the final judge for a code-review pipeline.
Round: {round_no}

Inputs:
reviewer_json={json.dumps(review, ensure_ascii=False)}
retry_history={json.dumps(history, ensure_ascii=False)}

Return ONLY valid JSON with schema:
{{
  "verdict": "pass"|"retry"|"escalate",
  "reason": "short rationale",
  "risk": "low"|"medium"|"high",
  "retry_prompt": "specific prompt for next writer run; empty on pass/escalate"
}}

Rules:
- If reviewer pass=true and no high-severity findings -> verdict=pass.
- If fixable issues -> verdict=retry with precise retry_prompt.
- If severe architectural/security concerns or repeated unresolved reason class -> escalate.
- Compare with retry_history: if same reject reason class appears twice, verdict must be escalate.
"""

payload = {
  "agentId": "worker",
  "label": f"grapple-v3-judge-r{round_no}",
  "model": "app-claude/claude-opus-4-6",
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
    echo '{"verdict":"escalate","reason":"sessions_spawn unavailable","risk":"high","retry_prompt":""}'
    exit 0
  fi
fi

python3 - <<'PY' "$RESP_FILE" "$HISTORY_JSON"
import json,re,sys
text=open(sys.argv[1]).read()
history_raw=sys.argv[2]

try:
    history=json.loads(history_raw)
except Exception:
    history=[]

def classify(reason:str)->str:
    r=(reason or '').lower()
    if any(k in r for k in ['security','injection','auth','secret','credential']): return 'security'
    if any(k in r for k in ['architecture','design','refactor']): return 'architecture'
    if any(k in r for k in ['test','coverage','flaky']): return 'test'
    return 'general'

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

def looks_like(o):
    return isinstance(o,dict) and 'verdict' in o and 'reason' in o and 'risk' in o and 'retry_prompt' in o

candidates=[]

# direct parse
try:
    o=json.loads(text)
    if isinstance(o, dict):
      candidates.append(o)
except Exception:
    pass

# fenced json first
fenced = extract_fenced_json(text)
if isinstance(fenced, dict):
    candidates.append(fenced)

# brace fallback
candidates.extend(extract_brace_json_objects(text))

chosen=None
for c in reversed(candidates):
    if looks_like(c):
        chosen=c
        break

if chosen is None:
    chosen={"verdict":"escalate","reason":"unparseable judge output","risk":"high","retry_prompt":""}

# Enforce same-reason escalation using history shape: round.judge.reason
if chosen.get('verdict') in ('retry','escalate'):
    cls=classify(chosen.get('reason',''))
    prev=[]
    for h in history:
        if not isinstance(h, dict):
            continue
        judge = h.get('judge', {})
        if isinstance(judge, dict):
            prev.append(classify(judge.get('reason','')))
    if prev.count(cls) >= 1:
        chosen={
          "verdict":"escalate",
          "reason":f"repeat reason class: {cls}",
          "risk":"high" if cls in ('security','architecture') else "medium",
          "retry_prompt":""
        }

print(json.dumps(chosen, ensure_ascii=False))
PY

rm -f "$PAYLOAD_FILE" "$RESP_FILE"
