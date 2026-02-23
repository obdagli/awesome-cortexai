#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: grapple.sh \"task\" [--project /path] [--strict]"
}

if [[ $# -lt 1 ]]; then
  usage
  exit 1
fi

task="$1"
shift

project="$(pwd)"
manual_strict=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project)
      project="$2"
      shift 2
      ;;
    --strict)
      manual_strict=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1"
      usage
      exit 1
      ;;
  esac
done

# Run opencode in project dir
pushd "$project" >/dev/null
timeout 900 opencode run "$task"

# Check git status
status=$(git status --porcelain)
commit_hash=""
if [[ -n "$status" ]]; then
  git add -A
  # summarize task for commit message
  summary=$(echo "$task" | tr '\n' ' ' | cut -c1-72)
  git commit -m "feat: ${summary}"
  commit_hash=$(git rev-parse HEAD)
else
  commit_hash=$(git rev-parse HEAD)
fi

# Build diff from last commit
if git rev-parse HEAD~1 >/dev/null 2>&1; then
  diff_output=$(git diff HEAD~1 HEAD)
else
  diff_output=""
fi

# Auto-strict check
strict_json=$(printf "%s" "$diff_output" | /home/brk/tools/grapple-v3/strict-check.sh)

auto_strict=false
strict_reasons=""
if echo "$strict_json" | grep -q '"strict": true'; then
  auto_strict=true
  strict_reasons=$(echo "$strict_json" | sed -n 's/.*"reasons": \[\(.*\)\].*/\1/p')
fi

strict_mode=false
if [[ "$manual_strict" == true || "$auto_strict" == true ]]; then
  strict_mode=true
fi

# Changed files + diff size
if git rev-parse HEAD~1 >/dev/null 2>&1; then
  changed_files=$(git diff --name-only HEAD~1 HEAD | tr '\n' ' ')
  diff_size=$(printf "%s" "$diff_output" | wc -l | tr -d ' ')
else
  changed_files=""
  diff_size=0
fi

# Verdict
verdict="✅ PASS"
if [[ "$strict_mode" == true ]]; then
  verdict="🚨 NEEDS REVIEW"
fi

# Mode line
mode_line="default"
if [[ "$auto_strict" == true ]]; then
  mode_line="⚠️ AUTO-STRICT triggered: ${strict_reasons:-unknown}"
elif [[ "$manual_strict" == true ]]; then
  mode_line="⚠️ STRICT (manual)"
fi

# Log
timestamp=$(date -u +"%Y%m%dT%H%M%SZ")
log_path="/home/brk/tools/grapple-v3/logs/${timestamp}.json"

cat > "$log_path" <<EOF
{
  "task": "${task}",
  "project": "${project}",
  "commit": "${commit_hash}",
  "manual_strict": ${manual_strict},
  "auto_strict": ${auto_strict},
  "strict_reasons": [${strict_reasons}],
  "strict_mode": ${strict_mode},
  "verdict": "${verdict}",
  "changed_files": "${changed_files}",
  "diff_size": ${diff_size},
  "note": "If strict, external judge must be triggered by orchestrator (Claw).",
  "timestamp": "${timestamp}"
}
EOF

# Report
report="🔍 Grapple Report — ${task}

Verdict: ${verdict}
Commit: ${commit_hash}
Mode: ${mode_line}

Changed files: ${changed_files}
Diff size: ${diff_size}

Log: tools/grapple-v3/logs/${timestamp}.json"

openclaw message send --channel telegram -t 1260478841 -m "$report"

popd >/dev/null
