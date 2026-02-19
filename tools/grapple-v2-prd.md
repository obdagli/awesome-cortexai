# Grapple v2 — 5-Gate Review Pipeline PRD

## Problem Statement

Current Grapple has 2 gates (writer + reviewer). This creates a governance failure: code can score 95+ while being completely unwired from the system. 5/9 tasks failed because "unused but well-written code" passed review. We need structural enforcement, not just prompt improvements.

The v1 pipeline (`grapple-pipeline.sh`) runs: Preflight → Writer → Capture → Skip → Lint Gate → Review → Fix Loop → Judge → Verdict. The reviewer is a single LLM call that checks quality, integration, and intent all at once — and routinely skips the integration/intent checks (the pipeline even has a hack that injects a synthetic finding when the reviewer forgets). The judge only sees reviewer findings, so it can't catch what the reviewer missed.

Root causes of the 5/9 failure rate:
1. No dedicated invocation proof — reviewer is asked to check integration but doesn't enforce it structurally
2. No spec alignment verification — reviewer checks intent as a soft suggestion, not a hard gate
3. Single-reviewer bottleneck — one model doing quality + integration + intent = none done well
4. Judge has no independent signal — just re-reads the same reviewer output

## Architecture: 5 Gates

### Gate 1: Writer (Implementation)

- Role: Implement the code changes
- Model: Opus 4.6 (`anthropic/claude-opus-4-6`, `--variant high`)
- Output: Code changes + git diff
- Timeout: 300s
- Existing behavior, no changes needed
- On timeout or crash: pipeline exits with code 4 (TIMEOUT/ERROR)

### Gate 2: Reviewer (Code Quality)

- Role: Review code quality, correctness, security, style
- Model: GPT-5.3 Codex (`codex.claude.gg/gpt-5.3-codex`)
- Input: Git diff of changed files + task description
- Output: Findings JSON with structure:
  ```json
  {
    "satisfaction_score": 0-100,
    "findings": [
      {
        "severity": "critical|major|minor",
        "category": "security|correctness|performance|style|architecture",
        "file": "path/to/file",
        "line": 42,
        "description": "what's wrong",
        "suggestion": "how to fix"
      }
    ],
    "summary": "one paragraph"
  }
  ```
- Pass condition: `satisfaction_score >= 70`, zero critical findings
- Hard fail: `satisfaction_score < 70` OR any critical finding → pipeline cannot APPROVE
- Existing behavior, enhanced prompts already in place
- Timeout: 180s
- Scope: quality ONLY — no integration or intent checks (those are now Gate 3 and Gate 4)

### Gate 3: Integrator (Invocation Proof)

- Role: Prove the code is actually wired into the system
- Model: GPT-5.3 Codex (`codex.claude.gg/gpt-5.3-codex`)
- Input: Git diff + full file contents of changed files + project file tree + invocation contract from task
- Timeout: 180s

#### Invocation Type Enum

Every symbol in the invocation map must declare one of these `invocation_type` values:

| Type | Description | Example |
|------|-------------|---------|
| `direct_import` | Standard ES/CJS import or require | `import { foo } from './bar'` |
| `dynamic_import` | Runtime `import()` or `require()` with variable path | `const mod = await import(pluginPath)` |
| `event_handler` | Registered via event emitter or DOM listener | `emitter.on('data', handler)` |
| `di_registration` | Dependency injection container registration | `container.register(AuthService)` |
| `decorator_wiring` | Framework decorator auto-wires the symbol | `@Controller('/api') class AuthCtrl {}` |
| `config_driven` | Loaded by a config file or manifest | `plugins: ['./src/plugins/auth']` in config |
| `re_export` | Re-exported from an index/barrel file | `export { authMiddleware } from './auth'` |
| `callback_argument` | Passed as callback/argument to another function | `app.use(authMiddleware)` |
| `test_only` | Invoked only from test files (valid wiring for test code) | `import { helper } from '../src/helper'` in test |

#### Required Checks

- "Where is this called from?" — trace every new function/class/module to its caller
- Import chain verification — follow imports from entrypoint to new code
- If new file: prove it's imported/required somewhere
- If new function: prove it's called somewhere
- If new config: prove it's read somewhere
- If new route/endpoint: prove it's registered in the router
- If new CLI command: prove it's wired into the command parser

#### Trust Patterns (`--trust-patterns <file>`)

Projects can declare their indirect wiring patterns in a trust-patterns file. Example:

```yaml
# .grapple-trust-patterns.yml
patterns:
  - path: "src/plugins/**"
    mechanism: "dynamic_import"
    loader: "src/plugin-loader.ts"
    description: "All files in src/plugins/ are loaded dynamically by plugin-loader.ts"
  - path: "src/commands/**"
    mechanism: "config_driven"
    loader: "src/command-registry.ts"
    description: "Command files auto-registered by command-registry.ts"
  - path: "src/decorators/**"
    mechanism: "decorator_wiring"
    loader: "framework"
    description: "Decorator-based wiring handled by NestJS/Angular framework"
```

When a new symbol's file matches a trust pattern, Gate 3 accepts the declared mechanism as valid invocation proof (still logged in the invocation map with the pattern reference).

#### Gate 3 Prompt Requirements

The Gate 3 prompt template MUST include explicit examples of each indirect invocation pattern so the model knows what to look for:

- Dynamic import: `const mod = await import('./plugins/' + name)`
- Event handler: `bus.on('user:created', sendWelcomeEmail)`
- DI registration: `container.bind(IAuthService).to(JwtAuthService)`
- Decorator wiring: `@Injectable() export class AuthGuard`
- Config-driven: `{ "middleware": ["./src/middleware/cors.js"] }`
- Re-export: `export { validateToken } from './jwt-utils'`
- Callback argument: `router.get('/health', healthCheck)`

#### Contract Schema Validation (Pre-Gate 3)

Before running Gate 3's LLM call, validate the invocation contract programmatically:
- `entry_point` field must be non-empty and not "TBD"
- `trigger` field must be non-empty and not "TBD"
- `proof_method` field must be non-empty and not "TBD"
- If any field is empty or "TBD" → FAIL immediately before wasting tokens
- Error message: `"Contract schema validation failed: <field> is empty or TBD. Fix the invocation contract before review."`

#### Output

```json
{
  "invocation_map": [
    {
      "symbol": "function authMiddleware",
      "defined_in": "src/middleware/auth.ts:15",
      "invoked_by": "src/app.ts:42",
      "invocation_type": "direct_import",
      "trust_pattern": null,
      "proof": "import { authMiddleware } from './middleware/auth'; app.use(authMiddleware);"
    }
  ],
  "unwired_symbols": [],
  "verdict": "PASS|FAIL",
  "summary": "one paragraph"
}
```

#### Hard Fail Conditions

- ANY new symbol without invocation proof OR documented indirect mechanism = FAIL
- "standalone utility" without wiring = FAIL
- New file not imported/required anywhere and not covered by a trust pattern = FAIL

#### Soft Pass (with warning)

- Indirect invocation via dynamic import, plugin system, or reflection — must document the mechanism and declare the `invocation_type`
- Test-only code (test files invoking new code counts as valid wiring, type = `test_only`)
- Symbol covered by a trust pattern — logged with pattern reference

### Gate 4: Intent Auditor (Spec Alignment Proof)

- Role: Prove changes match the original task/PRD intent
- Model: GPT-5.3 Codex (`codex.claude.gg/gpt-5.3-codex`)
- Input: Task description + invocation contract + git diff + list of all modified files
- Timeout: 180s

#### Task Type Classification

Every invocation contract includes a `task_type` field:

| Type | Criteria | Gate 4 Behavior |
|------|----------|-----------------|
| `structured` | Task has explicit acceptance criteria (ACs) | Full traceability matrix: each AC → code mapping required |
| `ad_hoc` | Task has no formal ACs (bug fix, quick change, exploration) | Scope-check only: flag out-of-scope changes, verify changes plausibly address the stated problem, skip requirement mapping |

Rules:
- If `task_type` is omitted, default to `structured` if the task contains numbered ACs or a "Requirements" section; otherwise default to `ad_hoc`
- Gate 4 MUST NEVER hallucinate acceptance criteria that weren't explicitly stated in the task
- For `ad_hoc` tasks, the traceability array may be empty — verdict is based on scope compliance and plausibility only

#### Required Checks (structured tasks)

- Each acceptance criterion from the task → mapped to specific code/test that implements it
- Scope check: flag files modified outside stated scope
- Default-path compliance: if spec says "automatic", opt-in/manual = FAIL
- No unrelated refactors or feature additions
- If task says "modify X", verify X was actually modified (not just adjacent files)

#### Required Checks (ad_hoc tasks)

- Scope check: flag files modified outside reasonable scope for the stated problem
- Plausibility check: do the changes plausibly address the stated problem?
- No unrelated refactors or feature additions
- Skip requirement-to-code mapping entirely

#### Output

```json
{
  "task_type": "structured|ad_hoc",
  "traceability": [
    {
      "requirement": "Add JWT validation to /api/auth",
      "implemented_in": ["src/middleware/auth.ts:15-42"],
      "tested_in": ["tests/auth.test.ts:10-30"],
      "status": "SATISFIED|UNSATISFIED|PARTIAL"
    }
  ],
  "scope_violations": [
    {
      "file": "src/unrelated/config.ts",
      "justification": "none provided",
      "severity": "major"
    }
  ],
  "verdict": "PASS|FAIL",
  "summary": "one paragraph"
}
```

#### Hard Fail Conditions

- Structured tasks: ANY acceptance criterion without code mapping = FAIL
- Scope violation (files outside task scope modified without justification) = FAIL
- Default-path violation (spec says automatic, implementation requires manual opt-in) = FAIL

#### Soft Pass (with warning)

- Minor scope additions that are justified (e.g., updating a shared type used by the new code)
- Partial satisfaction where the core intent is met but edge cases remain
- Ad-hoc tasks with minor tangential changes that don't affect the fix

### Gate 5: Judge (Composite Verdict)

- Role: Final verdict with hard fail conditions
- Model: Opus 4.6 (`anthropic/claude-opus-4-6`, `--variant high`)
- Inputs: Gate 2 findings + Gate 3 invocation map + Gate 4 traceability matrix + override log (if any)
- Timeout: 180s

#### Hard Fail Conditions (non-negotiable, auto-REJECT)

- Gate 2 `satisfaction_score < 70` or any critical finding
- Gate 3 has ANY symbol in `unwired_symbols` (verdict = FAIL)
- Gate 4 has ANY requirement with status `UNSATISFIED` (verdict = FAIL) — structured tasks only
- Gate 4 has scope violation without justification

#### Override Awareness

- Gate 5 receives the full override log (see Per-Symbol Override below)
- Judge MUST flag any override that looks suspicious (e.g., overriding Gate 3 for a symbol that clearly should be wired)
- Overrides do not bypass hard fails silently — they are documented exceptions the judge evaluates

#### Soft Conditions (can pass with warnings)

- Gate 2 score 70-85 with only minor/major findings
- Gate 3 has indirect invocation (dynamic import, plugin system) — documented
- Gate 4 has minor scope additions that are justified
- Gate 4 has requirements with status `PARTIAL` where core intent is met

#### Output

```json
{
  "verdict": "APPROVE|REVISE|REJECT",
  "composite_score": 0-100,
  "hard_fail_triggered": true|false,
  "hard_fail_reasons": ["Gate 3: unwired symbol authHelper"],
  "override_flags": ["Override gate3:authHelper looks suspicious — symbol has no indirect mechanism"],
  "warnings": ["Gate 2: score 78, minor style issues"],
  "required_actions": ["Wire authHelper into middleware chain"],
  "summary": "one paragraph"
}
```

- Escalation: If REJECT 2x in a row on the same task, escalate to human (write escalation file, exit with code 2)

## Invocation Contract (mandatory in every task)

Every task dispatched through the pipeline MUST include:

```
## Invocation Contract
- Entry point: <where this code is called from>
- Trigger: <what causes this code to run>
- Proof method: <how to verify it runs — test, log, trace>
- Task type: structured | ad_hoc
```

Rules:
- "Standalone utility" without wiring does NOT satisfy this contract
- If the task creates a new file, the contract MUST specify where it's imported
- If the task creates a new function, the contract MUST specify its caller
- Gate 3 uses this contract as its primary reference for verification
- Missing contract = Gate 3 auto-FAIL (cannot verify invocation without knowing expected entry point)
- Contract fields validated programmatically before Gate 3 (see Contract Schema Validation above)
- `task_type` defaults to `structured` if ACs present, `ad_hoc` otherwise

## Per-Symbol Override Escape Hatch

### Flag: `--override <gate>:<symbol>:<reason>`

Allows documented exceptions to hard-fail rules. Preserves "hard fail by default" while providing an auditable escape.

Usage:
```bash
grapple-v2.sh --task "..." --contract "..." \
  --override "gate3:loadPlugins:dynamically loaded by plugin-loader at startup" \
  --override "gate4:config-migration:out-of-scope but required for backward compat"
```

Rules:
- Multiple `--override` flags allowed
- Each override is logged in the trace file with full context (gate, symbol, reason, who provided it)
- Gate 5 receives all overrides and evaluates whether they're legitimate
- Overrides do NOT silently suppress failures — they convert hard fails to documented exceptions that the judge reviews
- Trace file `overrides` array:
  ```json
  {
    "overrides": [
      {
        "gate": "gate3",
        "symbol": "loadPlugins",
        "reason": "dynamically loaded by plugin-loader at startup",
        "flagged_by_judge": false
      }
    ]
  }
  ```

## Pipeline Flow (Parallel Gates)

```
Task + Invocation Contract
  │
  ├─ Preflight (git check, opencode check, circuit breaker)
  │
  ├─ Gate 1: Writer (implement)
  │    └─ Capture changed files + skip filter + lint gate
  │
  ├─ Contract Schema Validation (entry_point, trigger, proof_method non-empty, not "TBD")
  │    └─ Fail? → exit immediately, no tokens wasted
  │
  ├─ Gates 2, 3, 4: RUN IN PARALLEL ─────────────────────────┐
  │    │                                                       │
  │    ├─ Gate 2: Reviewer (quality check)          ─┐         │
  │    ├─ Gate 3: Integrator (invocation proof)      ├─ & wait │
  │    └─ Gate 4: Intent Auditor (spec alignment)   ─┘         │
  │                                                            │
  │    All three read the same diff — no data dependency.      │
  │    Run concurrently with `&` + `wait`.                     │
  │    Cuts wall-clock from ~2min to ~1min per pass.           │
  │                                                            │
  ├─ Short-circuit check (default behavior):                   │
  │    └─ If ANY gate hard-failed AND --exhaustive not set:    │
  │         skip remaining analysis, go straight to Gate 5     │
  │         with pre-filled REJECT signals                     │
  │                                                            │
  ├─ Gate 5: Judge (composite verdict) ← waits for all three  │
  │    ├─ APPROVE → exit 0                                     │
  │    ├─ REVISE → loop back to Gate 1 (max 3 rounds)         │
  │    └─ REJECT → exit 2 (escalate if 2x consecutive)        │
  │                                                            │
  └─ Trace output + cleanup ──────────────────────────────────┘
```

### Parallelization Details

Gates 2, 3, and 4 have zero data dependencies — they all consume the same git diff and task context. The orchestrator launches all three as background processes:

```bash
run_gate2 "$diff" "$task" &
pid_g2=$!
run_gate3 "$diff" "$task" "$contract" "$tree" &
pid_g3=$!
run_gate4 "$diff" "$task" "$contract" &
pid_g4=$!
wait $pid_g2 $pid_g3 $pid_g4
```

Gate 5 waits for all three to complete before rendering its verdict.

### Short-Circuit on Hard Fail

- Default behavior: if any of Gates 2/3/4 hard-fails, skip deeper analysis and send available results to Gate 5 immediately with pre-filled REJECT
- Flag `--exhaustive`: run all gates to completion even after a hard fail (useful for getting a complete picture of all issues in one pass)
- REVISE loop re-runs all gates regardless (the writer needs complete feedback)

### Incremental Review (Round 2+)

On REVISE rounds after the first:
- Compute delta diff: what changed between this round and the previous round
- Gates 2, 3, 4 review the delta diff only (not the full diff from baseline)
- This reduces token usage and focuses review on what the writer actually changed
- Gate 5 still sees cumulative context (all rounds' findings)

## Modular Architecture

### File Structure

```
tools/
  grapple-v2.sh                    # Orchestrator (pipeline flow, arg parsing, trace writing)
  grapple-v2/
    gate-reviewer.sh                # Gate 2 logic
    gate-integrator.sh              # Gate 3 logic
    gate-intent.sh                  # Gate 4 logic
    gate-judge.sh                   # Gate 5 logic
    prompts/
      reviewer.md.tmpl              # Gate 2 prompt template
      integrator.md.tmpl            # Gate 3 prompt template
      intent.md.tmpl                # Gate 4 prompt template
      judge.md.tmpl                 # Gate 5 prompt template
    lib.sh                          # Shared functions (JSON parsing, circuit breaker, file capture, etc.)
```

### Design Principles

- Each gate script: takes inputs via env vars/args, outputs JSON to stdout, exits 0 (pass) or 1 (fail)
- Prompt templates: separate `.md.tmpl` files processed with `envsubst` — no inline heredocs
- Shared functions in `lib.sh`: JSON parsing, circuit breaker checks, file capture, temp file management, timeout handling
- Orchestrator (`grapple-v2.sh`): handles arg parsing, pipeline flow, parallel dispatch, trace writing, exit codes
- Gate scripts are independently testable — can run a single gate in isolation for debugging

### Gate Script Interface

```bash
# Environment variables (set by orchestrator):
#   GRAPPLE_DIFF       - path to diff file
#   GRAPPLE_TASK       - task description
#   GRAPPLE_CONTRACT   - invocation contract text
#   GRAPPLE_TREE       - path to file tree listing
#   GRAPPLE_FILES      - path to file contents bundle
#   GRAPPLE_OVERRIDES  - JSON array of overrides for this gate
#   GRAPPLE_ROUND      - current round number (1-based)
#   GRAPPLE_PREV_DIFF  - path to previous round's diff (for incremental review)

# Exit codes:
#   0 = gate passed
#   1 = gate failed (hard fail)

# Output: JSON to stdout (captured by orchestrator)
```

## Implementation Constraints

- Must use `opencode run --file` for all LLM calls (temp file written with `printf`, not shell args — avoids ARG_MAX)
- Must check circuit breaker (`source tools/grapple-v2/lib.sh && cb_check coding`) before each gate's LLM call
- Must use trap-based temp file cleanup (`trap cleanup EXIT`)
- Must use `jq` for all JSON composition (no shell string interpolation for JSON — prevents injection)
- Must log each gate's result to a trace file (`${GRAPPLE_DIR}/last-run.json`)
- Must support these flags:
  - `--files <glob>` — scope review to specific files
  - `--task <desc>` — task description (required)
  - `--contract <text>` — invocation contract (required unless `--skip-gates 3`)
  - `--no-fix` — skip writer, review-only mode (equivalent to `--skip-gates 1`)
  - `--skip-gates <list>` — skip specific gates (comma-separated, e.g., `--skip-gates 1` for review-only, `--skip-gates 3,4` to run v1-style)
  - `--repo <path>` — repository path (default: cwd)
  - `--dry-run` — show what would happen without executing
  - `--max-rounds <n>` — override max fix rounds (default: 3)
  - `--override <gate>:<symbol>:<reason>` — per-symbol override escape hatch (repeatable)
  - `--trust-patterns <file>` — path to trust-patterns YAML for Gate 3 indirect wiring
  - `--exhaustive` — run all gates even after hard fail (default: short-circuit to Judge)
- Timeout per gate: 300s (writer), 180s (reviewer), 180s (integrator), 180s (intent), 180s (judge)
- Total pipeline timeout: 900s (enforced via outer `timeout` or elapsed-time check)
- Each gate prompt written to temp file via envsubst from `.md.tmpl`, passed via `opencode run --file <tmpfile>`
- Gate outputs parsed with `jq` — if parse fails, default to FAIL for that gate (safe default)

## Diff-Hash Caching

Between REVISE rounds, compute SHA-256 of the current diff:
- If diff hash matches the previous round's hash → the writer made no changes
- Skip re-review entirely and escalate to human: "Writer produced identical diff after revision feedback. Human intervention required."
- Write escalation to trace file and exit with code 2

## Partial Results on Timeout

If a gate times out mid-execution:
- Capture whatever partial output was written to stdout before the timeout
- Write partial output to the trace file under `gates.<gate>.partial_output`
- Mark the gate as `TIMEOUT` (not `FAIL`) in the trace
- Gate 5 can still use partial results from other gates that completed
- Don't lose work — partial signal is better than no signal

## Token Budget

Each gate has a hard token budget for input context:
- Max 100K tokens input per gate call
- Tree depth limit: max 4 levels deep for file tree listing
- File content truncation: if a single file exceeds 10K tokens, truncate with `[... truncated, showing first/last 5K tokens ...]`
- Aggregate file content: capped at 500KB (see File Capture Safety below)
- If total context would exceed 100K tokens, prioritize: diff > contract > changed file contents > file tree > surrounding context

## Model Fallback

If the primary model for a gate is unavailable (API error, rate limit, circuit breaker):
- Gates 2, 3, 4: fall back from GPT-5.3 Codex → Opus 4.6 (`anthropic/claude-opus-4-6`)
- Gates 1, 5 (Opus): fall back to GPT-5.3 Codex (`codex.claude.gg/gpt-5.3-codex`)
- Log the fallback in the trace file: `"model_fallback": { "requested": "...", "actual": "...", "reason": "..." }`
- Max 1 fallback attempt per gate — if fallback also fails, gate = ERROR

## Self-Exclusion Policy

- Files matching `tools/grapple-v2*` (the pipeline itself) are excluded from automated review
- Changes to pipeline files require human review or review by the OLD version of the pipeline
- Skip policy includes: `self_review: false`
- Rationale: a pipeline reviewing its own code creates a conflict of interest — it could approve changes that weaken its own checks

## File Capture Safety

- Cap file list at 5000 files max
- Aggregate byte budget: 500KB total for all file contents included in review context
- Break out of capture loop once either limit is exceeded
- Log warning in trace if limits were hit: `"file_capture_truncated": true, "files_captured": N, "bytes_captured": N`
- Prioritize changed files over surrounding context files when budget is tight

## Exit Codes

| Code | Meaning | When |
|------|---------|------|
| 0 | APPROVE | All gates passed, judge approved |
| 1 | REVISE | Fixable issues remain after max rounds |
| 2 | REJECT | Hard fail from any gate, judge rejected, or escalation (identical diff / 2x consecutive REJECT) |
| 3 | ERROR | Pipeline failure (missing tools, parse error, circuit breaker blocked) |
| 4 | TIMEOUT | Any gate or total pipeline exceeded timeout |

## Trace File Schema

Written to `${GRAPPLE_DIR}/last-run.json` after every run:

```json
{
  "version": "2.0",
  "timestamp": "ISO-8601",
  "task": "task description",
  "task_type": "structured|ad_hoc",
  "contract": "invocation contract text",
  "repo": "/path/to/repo",
  "verdict": "APPROVED|REVISE|REJECTED|ERROR|TIMEOUT",
  "exit_code": 0,
  "duration_seconds": 120,
  "models": {
    "writer": "anthropic/claude-opus-4-6",
    "reviewer": "codex.claude.gg/gpt-5.3-codex",
    "integrator": "codex.claude.gg/gpt-5.3-codex",
    "intent_auditor": "codex.claude.gg/gpt-5.3-codex",
    "judge": "anthropic/claude-opus-4-6"
  },
  "model_fallbacks": [],
  "baseline_sha": "abc1234",
  "final_sha": "def5678",
  "diff_hash": "sha256:...",
  "gates": {
    "gate2_reviewer": { "score": 85, "findings_count": 3, "critical_count": 0, "verdict": "PASS" },
    "gate3_integrator": { "symbols_checked": 4, "unwired_count": 0, "verdict": "PASS", "trust_patterns_used": 0 },
    "gate4_intent": { "task_type": "structured", "requirements_checked": 3, "unsatisfied_count": 0, "scope_violations": 0, "verdict": "PASS" },
    "gate5_judge": { "composite_score": 88, "hard_fail": false, "overrides_flagged": 0, "verdict": "APPROVE" }
  },
  "overrides": [],
  "rounds": [],
  "skipped_gates": [],
  "file_capture_truncated": false,
  "files_captured": 12,
  "bytes_captured": 45000,
  "summary": "one line"
}
```

## Migration from v1

- `grapple-pipeline.sh` remains untouched — v1 stays operational until v2 is validated
- `grapple-v2.sh` + `grapple-v2/` directory is the new implementation
- Extract shared functions (JSON parsing, file capture, skip policy, lint gate) into `tools/grapple-v2/lib.sh`
- v1's `parse_review_json` helper is reused for all gate output parsing
- A/B testing: run both v1 and v2 on the same tasks, compare results before switching
- Orchestrator (`omo-orchestrator.sh` or similar) switches to `grapple-v2.sh` only after A/B validation confirms v2 catches failures v1 missed without introducing false positives
- v1 is deprecated only after v2 passes validation on at least 10 real tasks

## Success Criteria

1. Pipeline runs end-to-end on a real task without errors
2. Gate 3 catches unwired code — test: submit a new file that's not imported anywhere → pipeline REJECT
3. Gate 4 catches scope creep — test: submit changes to files not mentioned in task → pipeline REJECT
4. Gate 5 hard-fails when Gate 3 or Gate 4 fail — no override possible (unless documented via `--override`)
5. No ARG_MAX issues (all prompts via `--file`, not shell args)
6. No JSON injection (all JSON via `jq`, not string interpolation)
7. No temp file leaks (trap-based cleanup verified)
8. Circuit breaker checked before every LLM call
9. Total runtime under 900s for a typical 5-file change (~1min per pass with parallel gates)
10. Trace file written on every run (success, failure, timeout, error)
11. Parallel gates (2, 3, 4) execute concurrently — verified by timestamp comparison in trace
12. Trust patterns correctly suppress false positives for declared indirect wiring
13. Ad-hoc tasks pass Gate 4 without hallucinated acceptance criteria
14. Diff-hash caching detects identical diffs and escalates instead of looping
15. Self-exclusion policy prevents pipeline from reviewing its own code
