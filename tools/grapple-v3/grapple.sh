#!/usr/bin/env bash
set -euo pipefail

cat <<'EOF'

grapple-v3 now runs entirely inside a subagent worker.

Use: sessions_spawn with task from tools/grapple-v3/WORKER_PROMPT.md
Template variables: {{TASK}}, {{PROJECT}}

Example (from an agent):
  - Load WORKER_PROMPT.md
  - Substitute {{TASK}} and {{PROJECT}}
  - Spawn a worker subagent with that task

EOF
