# Grapple v4

Grapple v4 is a full rewrite of the review pipeline using an **orchestrator-first** architecture. The orchestrator owns the entire state machine and delegates work to writer/reviewer/judge workers.

## Architecture

**Flow:** Claw spawns the grapple orchestrator → orchestrator owns full state machine

1. **Writer worker** (900s, codex gpt-5.2) — runs `opencode run` for the task and returns git diff + SHAs
2. **Reviewer worker** (300s, codex gpt-5.2) — reviews diff and returns JSON findings
3. **Judge worker** (300s, Claude Opus 4.6) — decides pass/retry/escalate
4. **Verdict handling**
   - **PASS** → commit + Telegram report
   - **RETRY** (max 2) → append judge retry_prompt, rerun writer
   - **ESCALATE** → Telegram alert + log snapshot

## Orchestrator Prompt

The orchestrator prompt template lives at:

```
/tools/grapple-v4/orchestrator.md
```

Variables:
- `{{TASK}}` — the user task
- `{{PROJECT}}` — target repo path

## How to Invoke

Claw should spawn the orchestrator with `{{TASK}}` and `{{PROJECT}}` filled in. The orchestrator itself does **not** modify code; it only uses `sessions_spawn` to delegate.

## Model Stack

- **Writer:** `codex.claude.gg/gpt-5.2-codex`
- **Reviewer:** `codex.claude.gg/gpt-5.2-codex`
- **Judge:** `app-claude/claude-opus-4-6`

## Logs

All escalation logs are written to:

```
/tools/grapple-v4/logs/
```

(Directory is created empty by default.)
