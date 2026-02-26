#!/usr/bin/env bash
# Session Cleanup — reports stale openclaw sessions (>24h with no recent activity)
# Usage: bash tools/session-cleanup.sh [--dry-run|--prune]
set -euo pipefail

MODE="${1:---dry-run}"
STALE_MINUTES=1440  # 24 hours

echo "🧹 Session Cleanup (mode: $MODE)"
echo "   Stale threshold: ${STALE_MINUTES}m (24h)"
echo ""

# Get all sessions as JSON
ALL_JSON=$(openclaw sessions --json 2>/dev/null) || {
    echo "❌ Failed to list sessions. Is the gateway running?"
    exit 1
}

TOTAL=$(echo "$ALL_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d) if isinstance(d,list) else 0)" 2>/dev/null || echo 0)
echo "Total sessions: $TOTAL"

# Get recently active sessions
ACTIVE_JSON=$(openclaw sessions --json --active "$STALE_MINUTES" 2>/dev/null) || ACTIVE_JSON="[]"
ACTIVE=$(echo "$ACTIVE_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d) if isinstance(d,list) else 0)" 2>/dev/null || echo 0)

echo "Active (last 24h): $ACTIVE"

# Find stale sessions by diffing
STALE_SESSIONS=$(python3 -c "
import json, sys

all_s = json.loads('''$ALL_JSON''')
active_s = json.loads('''$ACTIVE_JSON''')

if not isinstance(all_s, list):
    all_s = []
if not isinstance(active_s, list):
    active_s = []

active_ids = set()
for s in active_s:
    sid = s.get('id') or s.get('sessionId') or s.get('name', '')
    if sid:
        active_ids.add(sid)

stale = []
for s in all_s:
    sid = s.get('id') or s.get('sessionId') or s.get('name', '')
    if sid and sid not in active_ids:
        updated = s.get('updatedAt') or s.get('lastActivity') or s.get('updated') or 'unknown'
        stale.append({'id': sid, 'updated': updated})

for s in stale:
    print(f\"  {s['id']}  (last: {s['updated']})\")

if not stale:
    print('  (none)')
" 2>/dev/null) || STALE_SESSIONS="  (error parsing sessions)"

STALE_COUNT=$(echo "$STALE_SESSIONS" | grep -cv '(none)\|(error' 2>/dev/null || echo 0)

echo ""
echo "Stale sessions (>24h inactive): $STALE_COUNT"
echo "$STALE_SESSIONS"

if [[ "$MODE" == "--prune" ]]; then
    echo ""
    echo "⚠️  Prune mode requested but auto-deletion is disabled for safety."
    echo "   Review the stale sessions above and remove manually if needed."
    echo "   (openclaw sessions does not currently support delete — manage via gateway UI or config)"
fi

echo ""
echo "Done."
