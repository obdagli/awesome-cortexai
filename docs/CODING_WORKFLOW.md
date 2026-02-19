# Coding Workflow — OpenCode + OMO + Grapple-v2 Integration

> Comprehensive reference for the 5-gate adversarial coding pipeline used in this workspace.
> Last updated: 2026-02-19

---

## Table of Contents

1. [OpenCode — The Coding Agent](#opencode--the-coding-agent)
2. [Oh My OpenCode (OMO) — The Orchestration Layer](#oh-my-opencode-omo--the-orchestration-layer)
3. [Grapple-v2 — 5-Gate Adversarial Code Review](#grapple-v2--5-gate-adversarial-code-review)
4. [How They Fit Together](#how-they-fit-together)
5. [Agent Roster & Model Assignments](#agent-roster--model-assignments)
6. [Step-by-Step Workflow](#step-by-step-workflow)
7. [Configuration Reference](#configuration-reference)
8. [Grapple-v2 Architecture Deep Dive](#grapple-v2-architecture-deep-dive)
9. [Recommended Integration: Grapple-v2 Wrapping OMO](#recommended-integration-grapple-v2-wrapping-omo)
10. [Usage Examples](#usage-examples)
11. [Troubleshooting](#troubleshooting)

---

## OpenCode — The Coding Agent

**What it is:** An open-source AI coding agent built for the terminal. Think of it as a local, scriptable alternative to cloud-based coding assistants. It reads your codebase, makes edits, runs commands, and iterates — all from the CLI.

**Version installed:** 1.2.5

**Key capabilities:**
- TUI (terminal UI) for interactive sessions
- Non-interactive `opencode run "prompt"` for scripting and automation
- Multi-provider support (Anthropic, Google, OpenAI-compatible, Perplexity, etc.)
- MCP (Model Context Protocol) server integration for tools (Brave Search, Cortex media, memory, etc.)
- Agent system with custom agents, each with their own model/prompt/tools
- Skills system for lazy-loading domain-specific prompts
- Session management (continue, fork, export/import)
- Background server mode (`opencode serve`, `opencode web`)

**How it runs in this workspace:**
```bash
# Interactive TUI
opencode

# Non-interactive (scripting/automation)
opencode run "Fix the bug in auth.py"

# With specific model
opencode run -m "codex.claude.gg/gpt-5.3-codex" "Review this code"

# Continue last session
opencode run --continue "Keep going"
```

**Config location:** `~/.config/opencode/opencode.json`

**Provider architecture:** OpenCode connects to multiple AI providers through a unified config. This workspace has:
- `anthropic` → local proxy at `127.0.0.1:4040` (kiro-4040, the primary)
- `app.claude.gg` → native Anthropic gateway
- `beta.vertexapis.com` → Google Gemini (2.5 Pro, 2.5 Flash)
- `codex.claude.gg` → OpenAI Codex models (GPT-5.x series)
- `claude.gg`, `beta.claude.gg` → via xml-toolcall-proxy at `localhost:4012`
- `api.claude.gg` → GPT-5, Grok 4, DeepSeek R1, etc. via proxy
- `perplexity.claude.gg` → Perplexity Sonar for web search

**MCP servers configured:**
- `cortex` — image/video generation via cortex-mcp
- `memory` — persistent memory database
- `brave-search` — web search
- `flowbite` — UI component reference
- `context7` — documentation context

---

## Oh My OpenCode (OMO) — The Orchestration Layer

**What it is:** A plugin/harness for OpenCode that adds multi-model orchestration, agent specialization, and workflow automation. Created by code-yeongyu. Think of it as the "team lead" that coordinates multiple AI agents working on a single codebase.

**Version installed:** 3.6.0

**Key concept — Agent Orchestration:**

OMO transforms a single AI coding agent into a coordinated development team through a three-tier hierarchy:

### Core Agents

| Agent | Role | Analogy |
|-------|------|---------|
| **Prometheus** | Strategic planner. Analyzes the task, creates a detailed work plan with TODOs, considers edge cases, consults specialists. | Tech Lead / Architect |
| **Atlas** | Orchestrator. Reads Prometheus's plan, processes TODOs one by one, delegates to specialized sub-agents. | Project Manager |
| **Sisyphus** | Workhorse. Executes individual coding tasks. Persistent — keeps going until the task is done. | Senior Developer |
| **Hephaestus** | Builder/craftsman. Specialized for complex implementation work. | Staff Engineer |

### The Prometheus → Atlas → Sisyphus Flow

```
User: "Build a REST API for user management"
  │
  ▼
Prometheus (planning):
  - Analyzes requirements
  - Creates work plan with numbered TODOs
  - Identifies risks and edge cases
  - Saves plan to .sisyphus/notepads/
  │
  ▼
Atlas (orchestrating):
  - Reads the plan
  - Builds parallelization strategy
  - Delegates each TODO to appropriate agent
  - Tracks completion
  │
  ▼
Sisyphus/Junior (executing):
  - Implements each TODO
  - Writes code, runs tests
  - Reports back to Atlas
```

### OMO `run` Command

The primary automation interface:

```bash
# Basic usage
omo run "Fix the bug in index.ts"

# With specific agent
omo run --agent prometheus "Plan the refactoring of auth module"
omo run --agent sisyphus "Implement the login endpoint"

# With working directory
omo run --directory /home/brk/projects/myapp "Add error handling"

# With timeout (ms)
omo run --timeout 3600000 "Large refactoring task"

# JSON output for scripting
omo run --json "Fix the bug" | jq .sessionId

# Post-completion hook
omo run --on-complete "notify-send Done" "Fix the bug"

# Resume session
omo run --session-id ses_abc123 "Continue the work"
```

**Key difference from `opencode run`:** OMO's `run` command waits until ALL todos are completed or cancelled, and all child sessions (background tasks) are idle. This makes it reliable for automation — it won't return prematurely.

**Agent resolution order:**
1. `--agent` flag
2. `OPENCODE_DEFAULT_AGENT` env var
3. `oh-my-opencode.json` → `default_run_agent`
4. Sisyphus (fallback)

**Config location:** `~/.config/opencode/oh-my-opencode.json`

### OMO Categories

OMO also supports task categories that auto-select models:

| Category | Model | Use Case |
|----------|-------|----------|
| `visual-engineering` | claude-opus-4-6 (max) | UI/frontend work |
| `ultrabrain` | claude-opus-4-6 (max) | Complex architecture |
| `quick` | claude-sonnet-4-5 | Simple tasks |
| `unspecified-low` | claude-sonnet-4-5 | Default low-complexity |
| `unspecified-high` | gpt-5.3-codex | Default high-complexity |
| `writing` | gpt-5.3-codex | Documentation, prose |

---

## Grapple-v2 — 5-Gate Adversarial Code Review

**What it is:** A custom-built 5-gate adversarial code review pipeline that pits a Writer agent against a Reviewer agent from different model families. A Judge arbitrates if they can't converge. The goal: catch bugs that a single model would miss due to its own blind spots.

**Location:** `/home/brk/tools/grapple-v2.sh` (main pipeline script), `/home/brk/tools/grapple-v2/lib.sh` (shared functions)

**Why adversarial?** Research and practice show that AI models have systematic blind spots. A model that writes code tends to be "friendly" toward its own output. By using a *different* model family for review, you get genuinely independent critique:
- Friendly review catches: logic errors, obvious edge cases
- Adversarial review catches: architectural issues, tight coupling, security gaps, subtle race conditions

### Architecture

```
┌─────────────────────────────────────────────────────┐
│                   Grapple Pipeline                   │
│                                                      │
│  ┌──────────┐    ┌──────────┐    ┌──────────┐       │
│  │  Writer   │───▶│ Reviewer  │───▶│  Judge   │       │
│  │(Opus 4.6) │◀───│(GPT-5.3  │    │(Gemini)  │       │
│  │prometheus │    │ Codex)   │    │          │       │
│  │           │    │ momus    │    │ neutral  │       │
│  └──────────┘    └──────────┘    └──────────┘       │
│       │               │               │              │
│       ▼               ▼               ▼              │
│  REVIEW_REQUEST  REVIEW_R{n}.md  JUDGE_DECISION     │
│                                                      │
│  ┌─────────────────────────────────────────┐        │
│  │         Convergence Engine               │        │
│  │  • Satisfaction scoring (0-100)          │        │
│  │  • Diminishing returns detection         │        │
│  │  • Repeat loop detection (hash-based)    │        │
│  │  • Hard cap: 3 rounds                    │        │
│  └─────────────────────────────────────────┘        │
│                                                      │
│  ┌─────────────────────────────────────────┐        │
│  │         Auto-Commit on APPROVE           │        │
│  │  • git add → commit (conventional) → push│        │
│  │  • Telegram notifications throughout     │        │
│  └─────────────────────────────────────────┘        │
└─────────────────────────────────────────────────────┘
```

### Convergence Scoring

Each review round produces a Satisfaction Score:

```
penalty = (critical × 25) + (major × 10) + (minor × 2)
satisfaction = max(0, 100 - penalty)
```

| Severity | Weight | Meaning |
|----------|--------|---------|
| CRITICAL | 25 | Blocks merge — security, data loss, crashes |
| MAJOR | 10 | Must fix — logic errors, missing validation |
| MINOR | 2 | Nice to have — style, naming, docs |

### Smart Termination

```
AFTER EACH ROUND:
  1. score ≥ 90 AND no criticals → AUTO-APPROVE
  2. delta < 5 AND score ≥ 70 AND round ≥ 2 → APPROVE (diminishing returns)
  3. >50% issues repeated from previous round → ESCALATE (stuck loop)
  4. round == 3 → Judge arbitration → APPROVE/REJECT/ESCALATE
```

### Verdicts
- **APPROVE** — ship it, auto-commit
- **REQUEST_CHANGES** — fixable issues, loop continues
- **REJECT** — fundamental problems (Judge only)
- **ESCALATE** — models can't converge, human decides

---

## How They Fit Together

```
┌─────────────────────────────────────────────────────────┐
│                    OpenClaw (Claw)                        │
│              Main session — chat only                     │
│                                                          │
│  Master says: "Add rate limiting to the API"             │
│                        │                                  │
│                        ▼                                  │
│              Claw dispatches to worker                    │
└────────────────────────┬────────────────────────────────┘
                         │
                         ▼
┌─────────────────────────────────────────────────────────┐
│                  Grapple Pipeline                         │
│            (runs in worker session)                       │
│                                                          │
│  Round 1:                                                │
│    Writer:   omo run --agent prometheus "Implement..."   │
│    Reviewer: omo run --agent momus "Review..."           │
│                                                          │
│  Round 2 (if needed):                                    │
│    Writer:   omo run --agent prometheus "Fix feedback..." │
│    Reviewer: omo run --agent momus "Re-review..."        │
│                                                          │
│  Round 3 (if needed):                                    │
│    Judge:    opencode run -m gemini "Judge..."            │
│                                                          │
│  On APPROVE:                                             │
│    git add → git commit → git push                       │
│    Telegram notification to Master                       │
└─────────────────────────────────────────────────────────┘
```

**The stack:**
1. **OpenClaw** — the outer shell, handles Telegram chat, dispatches work
2. **Grapple** — the review orchestrator, manages the Writer↔Reviewer loop
3. **OMO** — the agent harness, routes prompts to the right model/agent
4. **OpenCode** — the actual coding agent, reads files, makes edits, runs commands

---

## Agent Roster & Model Assignments

### OMO Agents (from oh-my-opencode.json)

| Agent | Model | Variant | Role in Grapple |
|-------|-------|---------|-----------------|
| `prometheus` | anthropic/claude-opus-4-6 | max | **Writer** — plans and implements |
| `momus` | codex.claude.gg/gpt-5.3-codex | — | **Reviewer** — adversarial critique |
| `sisyphus` | anthropic/claude-opus-4-6 | max | General workhorse |
| `oracle` | anthropic/claude-opus-4-6 | max | Deep analysis |
| `metis` | anthropic/claude-opus-4-6 | max | Strategic thinking |
| `atlas` | codex.claude.gg/gpt-5.3-codex | — | Orchestration |
| `librarian` | codex.claude.gg/gpt-5.3-codex | — | Code search/reference |
| `explore` | anthropic/claude-sonnet-4-5 | — | Quick exploration |

### Grapple Model Assignments

| Role | omo Agent | Provider/Model | Why |
|------|-----------|----------------|-----|
| Writer | `prometheus` | anthropic/claude-opus-4-6 (max thinking) | Creative, thorough, best at architecture |
| Reviewer | `momus` | codex.claude.gg/gpt-5.3-codex | Different model family = independent perspective |
| Judge | — | vertex-gemini/gemini-3-pro | Neutral third party, neither Anthropic nor OpenAI |

**The key insight:** Writer and Reviewer MUST be from different model families. Same-family review is just an echo chamber.

---

## Step-by-Step Workflow

### For a typical code task:

**1. Master requests work** (via Telegram)
```
"Add rate limiting middleware to the Express API"
```

**2. Claw preflight checks**
```bash
pwd                                    # confirm workspace
git rev-parse --is-inside-work-tree    # confirm git repo
git branch --show-current              # confirm branch
command -v opencode && command -v omo   # confirm tools
```

**3. Claw spawns Grapple-v2** (in worker session)
```bash
/home/brk/tools/grapple-v2.sh \
  --task "Add rate limiting middleware to the Express API" \
  --files "src/middleware/rateLimit.ts,src/app.ts" \
  --dir /home/brk/projects/myapi
```

**4. Grapple Round 1 — Write**
```bash
omo run --agent prometheus \
  "Implement: Add rate limiting middleware. Modify: src/middleware/rateLimit.ts, src/app.ts. 
   Save summary to /tmp/grapple-myapi/REVIEW_REQUEST.md"
```
- Prometheus plans the implementation
- Creates/modifies the target files
- Writes a review request summary

**5. Grapple Round 1 — Review**
```bash
omo run --agent momus \
  "Review /tmp/grapple-myapi/REVIEW_REQUEST.md and the changed files.
   Write review to /tmp/grapple-myapi/REVIEW_R1.md with CRITICAL/MAJOR/MINOR counts,
   satisfaction_score, and VERDICT."
```
- Momus (GPT-5.3 Codex) reviews independently
- Produces structured feedback with severity ratings

**6. Convergence check**
- Grapple parses the review file
- Calculates satisfaction score
- Applies termination rules
- If APPROVE → commit. If REQUEST_CHANGES → Round 2.

**7. Round 2 (if needed) — Fix + Re-review**
- Writer addresses specific feedback
- Reviewer re-reviews with fresh eyes
- Delta tracking catches diminishing returns

**8. Round 3 (if needed) — Judge**
- Gemini reads all artifacts
- Makes final APPROVE/REJECT/ESCALATE decision

**9. On APPROVE — Auto-commit**
```bash
git add <files>
git commit -m "feat(myapi): add rate limiting middleware"
git push
```

**10. Telegram notification**
```
✅ Grapple myapi APPROVED & PUSHED
Commit: a1b2c3d
Rounds: 2 | Score: 92
Reason: score_above_90_no_criticals
Duration: 340s
```

---

## Configuration Reference

### File Locations

| File | Purpose |
|------|---------|
| `~/.config/opencode/opencode.json` | OpenCode providers, models, MCP servers |
| `~/.config/opencode/oh-my-opencode.json` | OMO agent definitions, categories |
| `~/.config/opencode/skills/` | OpenCode skills (domain-specific prompts) |
| `/home/brk/tools/grapple-v2.sh` | Grapple-v2 pipeline script (5-gate) |
| `/home/brk/tools/grapple-v2/lib.sh` | Grapple-v2 shared functions |
| `~/.config/opencode/skills/grapple-review/SKILL.md` | Grapple protocol documentation |

### Environment Variables

| Variable | Purpose |
|----------|---------|
| `VERTEX_API_KEY` | Google Vertex/Gemini API access |
| `GATE_API_KEY` | GateAI + claude.gg proxy access |
| `APP_CLAUDE_KEY` | Native Anthropic via app.claude.gg |
| `IMG_CLAUDE_KEY` | Cortex MCP image generation |
| `BRAVE_API_KEY` | Brave Search MCP |
| `OPENCODE_MODEL` | Override model for a single run |
| `OPENCODE_DEFAULT_AGENT` | Override default OMO agent |

### Grapple-v2 Constants (in grapple-v2.sh and lib.sh)

```python
WRITER_MODEL = "kiro-4040/claude-opus-4-6"
REVIEWER_MODEL = "cortex-openai/gpt-5.3-codex"
JUDGE_MODEL = "vertex-gemini/gemini-3-pro"
MAX_ROUNDS = 3
ROUND_TIMEOUT = 600          # 10 min per round
APPROVE_THRESHOLD = 70       # minimum for diminishing-returns approve
AUTO_APPROVE_THRESHOLD = 90  # auto-approve if no criticals
DIMINISHING_DELTA = 5        # delta below this = diminishing returns
W_CRITICAL = 25
W_MAJOR = 10
W_MINOR = 2
```

---

## Grapple-v2 Architecture Deep Dive

### Current Implementation (grapple-v2.sh + lib.sh)

The script has two execution paths:

1. **Primary: `run_omo()`** — calls `omo run --agent <name> "<prompt>"` 
   - Uses OMO's agent system for model routing
   - Benefits from OMO's todo-completion enforcement (waits until done)
   - Preferred path

2. **Fallback: `run_agent()`** — calls `openclaw agent --agent worker --local -m "<prompt>"`
   - Direct OpenClaw agent invocation
   - Sets `OPENCODE_MODEL` env var for model selection
   - Used when OMO fails (retry mechanism)

### Review Parsing

Grapple parses review files using regex patterns:
- Severity counts: `critical: N`, `major: N`, `minor: N`
- Satisfaction score: `satisfaction_score: N` or calculated from counts
- Verdict: `VERDICT: APPROVE|REQUEST_CHANGES|REJECT|ESCALATE`

### Repeat Detection

After each round, issue descriptions are hashed (MD5, first 12 chars). If >50% of hashes from round N appear in round N+1, the models are stuck in a loop → immediate escalation.

### Commit Message Generation

On APPROVE, Grapple uses a lightweight model (Gemini Flash) to generate a conventional commit message from the git diff stat. Falls back to `feat(<project>): grapple-approved changes`.

### Telegram Integration

Best-effort notifications via `openclaw message send` at:
- Pipeline start
- Each round's score/verdict
- Final result (approve/escalate)
- Commit hash on push

### Artifacts

All intermediate files go to `/tmp/grapple-<project>/`:
```
/tmp/grapple-myapi/
├── REVIEW_REQUEST.md        # Writer's summary of changes
├── REVIEW_R1.md             # Round 1 review
├── REVIEW_R2.md             # Round 2 review (if needed)
├── JUDGE_DECISION.md        # Judge verdict (if needed)
└── GRAPPLE_METRICS.json     # Full metrics for analysis
```

---

## Recommended Integration: Grapple-v2 Wrapping OMO

### Current State

Grapple currently calls OMO via subprocess:
```python
def run_omo(agent, prompt, workdir, label, timeout):
    cmd = ["omo", "run", "--agent", agent, prompt]
    result = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, cwd=workdir)
```

This works but has limitations:
- No structured output parsing (just stdout/stderr)
- No session reuse between rounds
- No access to OMO's JSON output mode
- Timeout handling is coarse (process-level kill)

### Recommended Improvements

#### 1. Use OMO's `--json` flag for structured output

```python
def run_omo(agent, prompt, workdir, label, timeout):
    cmd = ["omo", "run", "--agent", agent, "--json", prompt]
    result = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, cwd=workdir)
    if result.returncode == 0:
        data = json.loads(result.stdout)
        return result.returncode, data.get("sessionId"), result.stdout
    return result.returncode, None, result.stderr
```

#### 2. Session continuity for fix rounds

```python
# Round 1: fresh session
rc, session_id, output = run_omo("prometheus", writer_prompt, workdir, "Writer R1")

# Round 2: continue same session for context
if session_id:
    cmd = ["omo", "run", "--agent", "prometheus", "--session-id", session_id, fix_prompt]
```

This gives the Writer full context of what it did in Round 1, making fixes more accurate.

#### 3. Use `--on-complete` for notification

```python
cmd = [
    "omo", "run", "--agent", agent,
    "--on-complete", f"openclaw system event --text 'Grapple {label} done' --mode now",
    prompt
]
```

#### 4. Parallel review preparation

While the Writer is working, pre-warm the Reviewer's context:
```python
# Start writer
writer_proc = subprocess.Popen(writer_cmd, ...)

# Meanwhile, prepare reviewer prompt template
reviewer_prompt = build_reviewer_prompt(files, task, round_num)

# Wait for writer
writer_proc.wait()

# Immediately start reviewer (no delay)
reviewer_proc = subprocess.Popen(reviewer_cmd, ...)
```

#### 5. Model fallback chain

```python
WRITER_MODELS = [
    ("omo", "prometheus"),                          # Primary: OMO + Opus
    ("opencode", "anthropic/claude-opus-4-6"),      # Fallback 1: direct opencode
    ("opencode", "app.claude.gg/claude-opus-4-6"),  # Fallback 2: different provider
]

REVIEWER_MODELS = [
    ("omo", "momus"),                               # Primary: OMO + Codex
    ("opencode", "codex.claude.gg/gpt-5.3-codex"),  # Fallback 1
    ("opencode", "api.claude.gg/gpt-5"),             # Fallback 2
]
```

#### 6. Grapple as a wrapper script

The ideal invocation from Claw:

```bash
# Simple — Grapple-v2 handles everything
/home/brk/tools/grapple-v2.sh \
  --task "Add rate limiting" \
  --files "src/middleware/rateLimit.ts,src/app.ts" \
  --dir /home/brk/projects/myapi

# With overrides
/home/brk/tools/grapple-v2.sh \
  --task "Security audit" \
  --files "src/auth/*.ts" \
  --dir /home/brk/projects/myapi \
  --max-rounds 2 \
  --no-fix  # review only, don't auto-commit
```

---

## Usage Examples

### Example 1: Simple bug fix

```bash
# Claw dispatches:
/home/brk/tools/grapple-v2.sh \
  --task "Fix the off-by-one error in pagination logic" \
  --files "src/utils/paginate.ts" \
  --dir /home/brk/projects/webapp

# Expected: 1 round, auto-approve (simple fix, score ~95)
# Output: ✅ Grapple webapp APPROVED & PUSHED, Commit: abc1234
```

### Example 2: New feature

```bash
/home/brk/tools/grapple-v2.sh \
  --task "Implement WebSocket real-time notifications with auth, reconnection, and rate limiting" \
  --files "src/ws/server.ts,src/ws/auth.ts,src/ws/client.ts,src/types/ws.ts" \
  --dir /home/brk/projects/webapp

# Expected: 2-3 rounds (complex feature, reviewer will find edge cases)
# Round 1: score ~60 (missing reconnection backoff, no rate limit on WS)
# Round 2: score ~88 (minor style issues remain)
# Round 3: Judge approves (diminishing returns)
```

### Example 3: Review only (no commit)

```bash
/home/brk/tools/grapple-v2.sh \
  --task "Review and improve error handling across all API endpoints" \
  --files "src/routes/*.ts" \
  --dir /home/brk/projects/webapp \
  --no-fix

# Artifacts in /tmp/grapple-webapp/ for manual review
```

### Example 4: Quick task (skip Grapple)

For simple config changes, file moves, or when Master says "just do it":

```bash
# Direct OMO, no review loop
omo run --agent sisyphus "Update the database connection string in config.ts to use connection pooling"
```

### Example 5: Using OMO directly for planning

```bash
# Planning phase only
omo run --agent prometheus "Analyze the auth module and create a refactoring plan. Don't implement yet."

# Then execute with Grapple-v2
/home/brk/tools/grapple-v2.sh \
  --task "Execute the refactoring plan in .sisyphus/notepads/" \
  --files "src/auth/*.ts" \
  --dir /home/brk/projects/webapp
```

---

## Troubleshooting

### "opencode+omo not available"
```bash
command -v opencode  # should be /usr/bin/opencode
command -v omo       # should be /usr/local/bin/omo
```
If missing, reinstall: `npm install -g opencode@latest` and `bunx oh-my-opencode install`

### Writer/Reviewer timeout
- Default: 600s (10 min) per round
- For large tasks, increase: `--max-rounds 2` with longer timeout in grapple-v2.sh
- Check if the model provider is slow: test with `time opencode run "hello"`

### Review file not found
- Check `/tmp/grapple-<project>/` for artifacts
- The agent may have written to a different path — check stdout for clues
- Ensure the prompt explicitly states the output file path

### Stuck in loop (same issues repeating)
- Grapple auto-detects this (>50% hash overlap) and escalates
- If it doesn't catch it, check `GRAPPLE_METRICS.json` for round-over-round scores
- Manual fix: `--max-rounds 1` to force single-pass

### Models disagreeing fundamentally
- This is by design — different model families have different opinions
- If Judge also can't resolve, it escalates to human
- Check `JUDGE_DECISION.md` for reasoning

### Proxy issues (localhost:4012, localhost:4040)
- xml-toolcall-proxy: `curl http://localhost:4012/health`
- kiro proxy: `curl http://127.0.0.1:4040/v1/models`
- Restart if needed: check systemd services or process list

### OMO agent not found
```bash
# List available agents
cat ~/.config/opencode/oh-my-opencode.json | jq '.agents | keys'

# Should show: sisyphus, oracle, librarian, explore, multimodal-looker,
#              prometheus, metis, momus, atlas
```

---

## Appendix: When to Use What

| Scenario | Tool | Why |
|----------|------|-----|
| Any code change to a repo | Grapple (full pipeline) | Adversarial review catches blind spots |
| Simple config edit | `omo run --agent sisyphus` | No review needed |
| Planning/architecture | `omo run --agent prometheus` | Planning only, no code changes |
| Code exploration/search | `omo run --agent librarian` | Fast, uses Codex |
| Quick question about code | `opencode run "question"` | Lightweight, no orchestration |
| Complex multi-file refactor | Grapple with `--max-rounds 3` | Full adversarial loop |
| Security-sensitive changes | Grapple (never skip) | Security bugs are CRITICAL severity |
| Documentation only | `omo run --agent atlas` | Writing category, uses Codex |
