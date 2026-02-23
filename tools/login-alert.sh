#!/bin/bash
# Login alert monitor — checks auth.log for new login attempts since last run
STATEFILE="/tmp/login-alert-lastpos"
LOGFILE="/var/log/auth.log"
[ ! -f "$LOGFILE" ] && LOGFILE="/var/log/secure"
[ ! -f "$LOGFILE" ] && exit 0
[ ! -r "$LOGFILE" ] && exit 0

# Get last position
LASTPOS=0
[ -f "$STATEFILE" ] && LASTPOS=$(cat "$STATEFILE")

# Get current size
CURSIZE=$(wc -c < "$LOGFILE")
echo "$CURSIZE" > "$STATEFILE"

[ "$CURSIZE" -le "$LASTPOS" ] && exit 0

# Read new lines
NEWLINES=$(tail -c +"$((LASTPOS+1))" "$LOGFILE" 2>/dev/null)

# Filter for login events
EVENTS=$(echo "$NEWLINES" | grep -E "sshd.*(Accepted|Failed|Invalid|Connection closed|Disconnected|session opened)" | tail -20)

[ -z "$EVENTS" ] && exit 0

# Format message
MSG="🚨 Server Login Alert

$(echo "$EVENTS" | while IFS= read -r line; do
  if echo "$line" | grep -q "Accepted"; then
    echo "✅ LOGIN SUCCESS: $line"
  elif echo "$line" | grep -q "Failed\|Invalid"; then
    echo "❌ FAILED ATTEMPT: $line"
  else
    echo "ℹ️ $line"
  fi
done)"

openclaw message send --channel telegram -t 1260478841 -m "$MSG"
