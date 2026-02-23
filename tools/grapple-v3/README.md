# grapple-v3

Code review pipeline wrapper around opencode+omo with reviewer/judge gates.

## Flow

```text
writer (opencode/omo)
  -> reviewer (Codex via sessions_spawn)
  -> judge (Opus via sessions_spawn)
    -> pass      => done
    -> retry     => run writer again with judge retry_prompt (max 2 retries)
    -> escalate  => Telegram alert + forensic log
```

### Trigger model (hybrid)

- Primary: omo `session-complete` hook emits event file
- Fallback: `grapple.sh` runs review on process exit if hook event missing
- Idempotency: marker in `/tmp/grapple-v3/reviewed/` prevents double-review

## Files

- `grapple.sh` — main entry point
- `reviewer.sh` — Codex reviewer (`cliproxyapi/gpt-5.3-codex`)
- `judge.sh` — Opus judge (`app-claude/claude-opus-4-6`)
- `notify.sh` — escalation message to Telegram + forensic logging
- `omo-hook.md` — hook wiring instructions
- `logs/` — per-run forensic JSON logs

## Usage

```bash
/home/brk/tools/grapple-v3/grapple.sh "implement auth middleware" --project /home/brk/projects/myrepo
```

Optional:

```bash
--dry-run
```

## Output log

Every run writes:

`/home/brk/tools/grapple-v3/logs/<timestamp-randid>.json`

Contains:
- run metadata
- hook/fallback info
- all round reviewer/judge outputs
- final verdict and reason
- changed files snapshot

## Escalation behavior

On `escalate` (or repeated reject reason class), `notify.sh` sends Telegram alert to chat `1260478841` with:
- task summary
- changed files
- failure reason
- per-round attempt summary
- risk + action
- path to full forensic log

## Notes

- reviewer/judge are implemented with `sessions_spawn` gateway calls in scripts.
- scripts include fallback to `sessions.spawn` method name for compatibility.
