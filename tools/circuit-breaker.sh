#!/usr/bin/env bash
# Circuit breaker for worker health tracking.
# MUST be sourced by bash: source /path/to/circuit-breaker.sh
# Requires: jq, flock

# Guard: fail loudly if jq is missing
if ! command -v jq &>/dev/null; then
  echo "FATAL: circuit-breaker.sh requires jq but it's not installed" >&2
  return 1 2>/dev/null || exit 1
fi

SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
CB_FILE="${SCRIPT_DIR}/circuit_breaker.json"
CB_COOLDOWN=300
CB_THRESHOLD=3
CB_HALF_OPEN_TTL=120
CB_LOCKFILE="${CB_FILE}.lock"
_CB_VALID_CATEGORIES="coding media search general"

_cb_atomic_write() {
  local input
  input="$(cat)" || return 1
  # Reject empty or invalid JSON
  if [ -z "$input" ] || ! echo "$input" | jq empty 2>/dev/null; then
    echo "ERROR: _cb_atomic_write received empty/invalid JSON" >&2
    return 1
  fi
  local tmp
  tmp="$(mktemp "${CB_FILE}.tmp.XXXXXX")" || return 1
  # Trap to clean temp file on failure
  trap "rm -f '$tmp'" RETURN
  echo "$input" | jq '.' > "$tmp" || { echo "ERROR: failed to write temp file" >&2; return 1; }
  mv "$tmp" "$CB_FILE" || { echo "ERROR: failed to mv $tmp -> $CB_FILE" >&2; return 1; }
  trap - RETURN
}

_cb_validate_category() {
  local category="$1"
  if [ -z "$category" ]; then
    echo "ERROR: category is empty. Allowed: ${_CB_VALID_CATEGORIES}" >&2
    return 1
  fi
  if ! echo "$_CB_VALID_CATEGORIES" | grep -qw "$category"; then
    echo "ERROR: unknown category '$category'. Allowed: ${_CB_VALID_CATEGORIES}" >&2
    return 1
  fi
}

_cb_locked() {
  # Execute a function body under flock
  (
    flock -w 5 200 || { echo "ERROR: failed to acquire lock on $CB_LOCKFILE" >&2; return 1; }
    "$@"
  ) 200>"$CB_LOCKFILE"
}

cb_check() {
  local category="$1"
  _cb_validate_category "$category" || return 2
  _cb_locked _cb_check_inner "$category"
}

_cb_check_inner() {
  local category="$1"
  local now state last_fail elapsed remaining

  now="$(date +%s)"
  state="$(jq -r --arg c "$category" '.[$c].state' "$CB_FILE")" || { echo "ERROR: jq read failed" >&2; return 1; }

  if [ "$state" = "open" ]; then
    last_fail="$(jq -r --arg c "$category" '.[$c].lastFail // 0' "$CB_FILE")" || return 1
    elapsed=$((now - last_fail))

    if [ "$elapsed" -ge "$CB_COOLDOWN" ]; then
      jq --arg c "$category" --argjson now "$now" '.[$c].state = "half-open" | .[$c].halfOpenSince = $now' "$CB_FILE" | _cb_atomic_write
      return $?
    else
      remaining=$((CB_COOLDOWN - elapsed))
      echo "BLOCKED: $category circuit open, cooldown remaining ${remaining}s"
      return 1
    fi
  fi

  if [ "$state" = "half-open" ]; then
    local half_open_since
    half_open_since="$(jq -r --arg c "$category" '.[$c].halfOpenSince // 0' "$CB_FILE")" || return 1
    elapsed=$((now - half_open_since))

    if [ "$elapsed" -ge "$CB_HALF_OPEN_TTL" ]; then
      echo "WARN: $category half-open expired after ${elapsed}s (TTL=${CB_HALF_OPEN_TTL}s), re-arming open cooldown" >&2
      jq --arg c "$category" --argjson now "$now" '.[$c].state = "open" | .[$c].lastFail = $now | .[$c].halfOpenSince = null' "$CB_FILE" | _cb_atomic_write
      echo "BLOCKED: $category circuit re-opened after half-open TTL expiry"
      return 1
    fi
  fi

  return 0
}

cb_success() {
  local category="$1"
  _cb_validate_category "$category" || return 2
  _cb_locked _cb_success_inner "$category"
}

_cb_success_inner() {
  local category="$1"
  jq --arg c "$category" '
    .[$c].failures = 0 |
    .[$c].successes += 1 |
    .[$c].state = "closed" |
    .[$c].halfOpenSince = null
  ' "$CB_FILE" | _cb_atomic_write || { echo "ERROR: cb_success write failed" >&2; return 1; }
}

cb_fail() {
  local category="$1"
  _cb_validate_category "$category" || return 2
  _cb_locked _cb_fail_inner "$category"
}

_cb_fail_inner() {
  local category="$1"
  local now
  now="$(date +%s)"

  jq --arg c "$category" --argjson now "$now" --argjson threshold "$CB_THRESHOLD" '
    .[$c].failures += 1 |
    .[$c].lastFail = $now |
    .[$c].halfOpenSince = null |
    if .[$c].failures >= $threshold then .[$c].state = "open" else . end
  ' "$CB_FILE" | _cb_atomic_write || { echo "ERROR: cb_fail write failed" >&2; return 1; }
}

cb_status() {
  jq -r 'to_entries[] | "\(.key): \(.value.state) (failures: \(.value.failures), last: \((.value.lastFail // "never")))"' "$CB_FILE"
}
