# omo completion hook wiring for grapple-v3

Grapple-v3 supports a **hybrid completion trigger**:

1. Primary: omo completion hook writes a `session-complete` event file
2. Fallback: `grapple.sh` detects writer exit and triggers review itself

This prevents missed reviews and double-reviews (idempotency marker in `/tmp/grapple-v3/reviewed/`).

## Required env vars

`grapple.sh` exports these before launching `opencode run`:

- `GRAPPLE_V3_RUN_ID`
- `GRAPPLE_V3_EVENT_FILE`
- `GRAPPLE_V3_IDEMPOTENCY_KEY`

## Hook script

Create executable script:

`/home/brk/tools/grapple-v3/omo-session-complete-hook.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail

# Hook should run only for grapple-managed runs
[[ -n "${GRAPPLE_V3_RUN_ID:-}" ]] || exit 0
[[ -n "${GRAPPLE_V3_EVENT_FILE:-}" ]] || exit 0

mkdir -p "$(dirname "$GRAPPLE_V3_EVENT_FILE")"
cat > "$GRAPPLE_V3_EVENT_FILE" <<JSON
{
  "event": "session-complete",
  "run_id": "${GRAPPLE_V3_RUN_ID}",
  "idempotency_key": "${GRAPPLE_V3_IDEMPOTENCY_KEY:-}",
  "timestamp_utc": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
JSON
```

Then:

```bash
chmod +x /home/brk/tools/grapple-v3/omo-session-complete-hook.sh
```

## .opencode/config.yml snippet

Add/update hook configuration in `.opencode/config.yml`:

```yaml
hooks:
  session-complete:
    - /home/brk/tools/grapple-v3/omo-session-complete-hook.sh
```

> If your current config uses a different hook key format, keep your existing structure and add the same script command under the session completion hook event.

## Verification

Run grapple once and confirm event file appears during run:

```bash
ls -la /tmp/grapple-v3/events/
cat /tmp/grapple-v3/events/*.session-complete.json
```

Even if hook fails, fallback logic in `grapple.sh` still runs reviewer/judge after writer exits.

## Current limitation

Hook support is currently **partial**: we only detect writer completion via the session-complete event file and then use fallback/script-side review triggering. Full hook-driven integration (including richer event semantics and end-to-end lifecycle wiring) is a future TODO.
