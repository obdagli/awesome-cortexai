# grapple-v3

Subagent-based code review pipeline wrapper around opencode + reviewer/judge gates.

## Architecture (new)

```text
Claw spawns grapple worker (subagent)
  -> writer: opencode run
  -> reviewer: sessions_spawn (Codex)
  -> judge: sessions_spawn (Opus)
    -> pass      => commit + report success
    -> retry     => re-run writer with retry prompt (max 2)
    -> escalate  => Telegram alert + forensic log
```

All orchestration now happens inside the grapple worker subagent (where sessions_spawn is available). Shell scripts no longer attempt to call sessions_spawn.

## Files

- `grapple.sh` — thin wrapper: prints how to spawn the worker
- `WORKER_PROMPT.md` — canonical worker prompt template (variables: {{TASK}}, {{PROJECT}})
- `omo-hook.md` — legacy hook wiring (kept for reference)
- `logs/` — per-run forensic JSON logs (written by worker on escalation)

## Usage

From an agent (not shell), spawn a worker using the template:

1. Load `tools/grapple-v3/WORKER_PROMPT.md`
2. Replace {{TASK}} and {{PROJECT}}
3. sessions_spawn the worker with the resulting task text

Example (conceptual):

```
sessions_spawn:
  task: <WORKER_PROMPT with variables substituted>
```

## Notes

- reviewer/judge are spawned inline by the worker
- old shell-based reviewer/judge/notify scripts removed
