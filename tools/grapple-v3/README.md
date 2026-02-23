# grapple-v3

Thin wrapper around `opencode` / `omo` for code execution, with commit enforcement and Telegram reporting.

## Architecture

**Default mode:**
- `opencode run` executes the task (OMO handles writer + reviewer + judge internally)
- Grapple enforces commit creation and sends a Telegram report

**Strict mode** (`--strict` or auto-triggered):
- Grapple marks the run as **NEEDS REVIEW** and flags that an external judge must be triggered **by the orchestrator (Claw)**

Auto-strict triggers:
- Sensitive paths/files: `auth/`, `billing/`, `permissions/`, `infra/`, `*.env`, `config/prod*`, `MEMORY.md`, `AGENTS.md`, `*.service`, `crontab`
- Diff size > 200 lines
- Keywords in diff: `password`, `token`, `secret`, `api_key`, `DROP TABLE`, `rm -rf`, `sudo`

## Files

- `grapple.sh` — main entry point (run in shell)
- `strict-check.sh` — diff analyzer that outputs JSON
- `logs/` — per-run JSON logs
- `archive/` — superseded files and scripts

## Usage

```bash
grip="/path/to/project"
/home/brk/tools/grapple-v3/grapple.sh "task summary" --project "$grip"

# strict mode
/home/brk/tools/grapple-v3/grapple.sh "task summary" --project "$grip" --strict
```

## Report

Telegram report format:

```
🔍 Grapple Report — <task summary>

Verdict: ✅ PASS / 🚨 NEEDS REVIEW
Commit: <hash>
Mode: default / ⚠️ AUTO-STRICT triggered: <reason>

Changed files: <list>
Diff size: <N lines>

Log: tools/grapple-v3/logs/<timestamp>.json
```
