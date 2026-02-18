#!/usr/bin/env bash
# opencode-dispatch.sh — Dual-profile wrapper for opencode run
# Profiles: quick (lightweight tasks) | full (coding/review tasks)
#
# Usage:
#   opencode-dispatch.sh quick "search for X using brave"
#   opencode-dispatch.sh full "implement auth middleware in src/api/"
#   opencode-dispatch.sh quick --template quick-search "find latest express docs"
#   opencode-dispatch.sh full --template full-code "add JWT validation" --dir /home/brk/myproject
#   opencode-dispatch.sh full --no-grapple "implement auth without review"
#   opencode-dispatch.sh full --task "implement auth" --dir /home/brk/myproject

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_DIR="${SCRIPT_DIR}/prompt-templates"

# ── Profile Definitions ──────────────────────────────────────────────────────

declare -A QUICK_OPTS=(
  [model]="anthropic/claude-sonnet-4-5"
  [variant]="default"
  [timeout]=120
)

declare -A FULL_OPTS=(
  [model]="anthropic/claude-opus-4-6"
  [variant]="high"
  [timeout]=600
)

# ── Functions ────────────────────────────────────────────────────────────────

usage() {
  cat <<'EOF'
Usage: opencode-dispatch.sh <profile> [options] <message..>

Profiles:
  quick   Low thinking budget, short timeout (search, git, file reads)
  full    High thinking budget, long timeout (coding, review, architecture)

Options:
  --template <name>   Load prompt template from tools/prompt-templates/<name>.md
  --dir <path>        Working directory for opencode
  --model <model>     Override model (provider/model format)
  --session <id>      Continue existing session
  --timeout <secs>    Override timeout (default: quick=120, full=600)
  --grapple           Explicitly enable grapple (default for full profile)
  --no-grapple        Skip grapple review (full profile only, overrides default)
  --dry-run           Print command without executing

Notes:
  Full profile auto-triggers Grapple review pipeline. Use --no-grapple to skip.
  Quick profile never triggers Grapple.

Template names: quick-search, quick-read, quick-git, full-code, full-review
EOF
  exit 1
}

log() { echo "[dispatch] $*" >&2; }

slugify() {
  echo "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | sed 's/^-//;s/-$//' | cut -c1-40
}

# ── Parse Args ───────────────────────────────────────────────────────────────

[[ $# -lt 2 ]] && usage

PROFILE="$1"; shift

case "$PROFILE" in
  quick) declare -n OPTS=QUICK_OPTS ;;
  full)  declare -n OPTS=FULL_OPTS ;;
  *)     log "Unknown profile: $PROFILE"; usage ;;
esac

MODEL="${OPTS[model]}"
VARIANT="${OPTS[variant]}"
TIMEOUT="${OPTS[timeout]}"
TEMPLATE=""
DIR=""
SESSION=""
DRY_RUN=false
# Full profile: Grapple on by default. Quick profile: always off (overridden below).
GRAPPLE=true
MESSAGE_PARTS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --template)  TEMPLATE="$2"; shift 2 ;;
    --dir)       DIR="$2"; shift 2 ;;
    --model)     MODEL="$2"; shift 2 ;;
    --session)   SESSION="$2"; shift 2 ;;
    --timeout)   TIMEOUT="$2"; shift 2 ;;
    --grapple)   GRAPPLE=true; shift ;;
    --no-grapple) GRAPPLE=false; shift ;;
    --dry-run)   DRY_RUN=true; shift ;;
    --)          shift; MESSAGE_PARTS+=("$@"); break ;;
    *)           MESSAGE_PARTS+=("$1"); shift ;;
  esac
done

# ── Circuit Breaker Pre-Dispatch ─────────────────────────────────────────────
source "${SCRIPT_DIR}/circuit-breaker.sh"

# Infer category from template or task content
_infer_category() {
  local tpl="${TEMPLATE:-}" msg="${MESSAGE_PARTS[*]:-}"
  case "$tpl" in
    full-code|full-review) echo "coding" ;;
    quick-search) echo "search" ;;
    *) 
      if echo "$msg" | grep -qiE 'search|find|lookup|brave'; then echo "search"
      elif echo "$msg" | grep -qiE 'image|video|audio|render|generate.*media'; then echo "media"
      elif echo "$msg" | grep -qiE 'code|implement|fix|refactor|build|test|review'; then echo "coding"
      else echo "general"
      fi
      ;;
  esac
}

DISPATCH_CATEGORY="$(_infer_category)"
if ! cb_check "$DISPATCH_CATEGORY"; then
  log "BLOCKED: circuit breaker open for category '$DISPATCH_CATEGORY'. Aborting dispatch."
  exit 10
fi

# ── Compliance Gate ──────────────────────────────────────────────────────────
if ! python3 "${SCRIPT_DIR}/check-opencode-compliance.py" --gate 2>/dev/null; then
  log "WARNING: compliance violations detected in recent worker logs"
  log "Run: python3 tools/check-opencode-compliance.py for details"
  # Non-blocking warning — log but don't abort (violations are in PAST workers, not this one)
fi

# ── Grapple Pipeline Routing ─────────────────────────────────────────────────

# Quick profile: never grapple, regardless of flags
if [[ "$PROFILE" == "quick" ]]; then
  GRAPPLE=false
fi

if $GRAPPLE; then
    GRAPPLE_SCRIPT="${SCRIPT_DIR}/grapple-pipeline.sh"
    if [[ ! -x "$GRAPPLE_SCRIPT" ]]; then
      log "Error: grapple-pipeline.sh not found or not executable at $GRAPPLE_SCRIPT"
      exit 4
    fi

    GRAPPLE_ARGS=(--task "${MESSAGE_PARTS[*]}")
    [[ -n "$DIR" ]] && GRAPPLE_ARGS+=(--repo "$DIR")
    [[ -n "$MODEL" && "$MODEL" != "${FULL_OPTS[model]}" ]] && GRAPPLE_ARGS+=(--writer-model "$MODEL")
    $DRY_RUN && GRAPPLE_ARGS+=(--dry-run)

    log "Routing to grapple pipeline..."

    # Auto-log spawn
    LABEL="grapple-$(slugify "${MESSAGE_PARTS[*]}")"
    python3 "${SCRIPT_DIR}/worker-log.py" log-spawn \
      --label "$LABEL" \
      --task "grapple: ${MESSAGE_PARTS[*]}" \
      --model "$MODEL" \
      --profile "full" \
      --timeout 1800 >/dev/null 2>&1 || true

    START_TIME=$(date +%s)
    set +e
    "$GRAPPLE_SCRIPT" "${GRAPPLE_ARGS[@]}"
    EXIT_CODE=$?
    set -e
    END_TIME=$(date +%s)
    DURATION=$((END_TIME - START_TIME))

    if [[ $EXIT_CODE -eq 0 ]]; then
      python3 "${SCRIPT_DIR}/worker-log.py" log-complete \
        --label "$LABEL" \
        --status success \
        --duration "$DURATION" >/dev/null 2>&1 || true
    else
      python3 "${SCRIPT_DIR}/worker-log.py" log-fail \
        --label "$LABEL" \
        --error "exit_code_${EXIT_CODE}" \
        --duration "$DURATION" >/dev/null 2>&1 || true
    fi

    exit $EXIT_CODE
fi

# ── Build Message ────────────────────────────────────────────────────────────

MESSAGE=""

if [[ -n "$TEMPLATE" ]]; then
  TMPL_FILE="${TEMPLATE_DIR}/${TEMPLATE}.md"
  if [[ -f "$TMPL_FILE" ]]; then
    TMPL_CONTENT="$(cat "$TMPL_FILE")"
    MESSAGE="${TMPL_CONTENT}"$'\n\n'"${MESSAGE_PARTS[*]}"
  else
    log "Warning: template '${TEMPLATE}' not found at ${TMPL_FILE}, using message only"
    MESSAGE="${MESSAGE_PARTS[*]}"
  fi
else
  MESSAGE="${MESSAGE_PARTS[*]}"
fi

# ── Build Command ────────────────────────────────────────────────────────────

CMD=(opencode run)
CMD+=(--model "$MODEL")
CMD+=(--variant "$VARIANT")
[[ -n "$DIR" ]] && CMD+=(--dir "$DIR")
[[ -n "$SESSION" ]] && CMD+=(--session "$SESSION")
CMD+=("$MESSAGE")

if $DRY_RUN; then
  log "DRY RUN: timeout ${TIMEOUT}s"
  printf '%q ' "${CMD[@]}"
  echo
  exit 0
fi

# ── Execute ──────────────────────────────────────────────────────────────────

log "profile=$PROFILE model=$MODEL variant=$VARIANT timeout=${TIMEOUT}s"

LABEL="$(slugify "${MESSAGE_PARTS[*]}")"
TASK_SUMMARY="${MESSAGE_PARTS[*]}"

# Auto-log spawn
python3 "${SCRIPT_DIR}/worker-log.py" log-spawn \
  --label "$LABEL" \
  --task "$TASK_SUMMARY" \
  --model "$MODEL" \
  --profile "$PROFILE" \
  --timeout "$TIMEOUT" >/dev/null 2>&1 || true

START_TIME=$(date +%s)
set +e
timeout "$TIMEOUT" "${CMD[@]}"
EXIT_CODE=$?
set -e
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

# Auto-log completion or failure
if [[ $EXIT_CODE -eq 0 ]]; then
  python3 "${SCRIPT_DIR}/worker-log.py" log-complete \
    --label "$LABEL" \
    --status success \
    --duration "$DURATION" >/dev/null 2>&1 || true
else
  python3 "${SCRIPT_DIR}/worker-log.py" log-fail \
    --label "$LABEL" \
    --error "exit_code_${EXIT_CODE}" \
    --duration "$DURATION" >/dev/null 2>&1 || true

  # Escalation hint: if quick profile failed, suggest retry with full
  if [[ "$PROFILE" == "quick" ]]; then
    log "⚠ Quick profile (Sonnet) failed with exit code $EXIT_CODE. Consider retrying with full profile (Opus): opencode-dispatch.sh full ${MESSAGE_PARTS[*]}"
  fi
fi

exit $EXIT_CODE
