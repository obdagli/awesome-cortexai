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

task_original="$task"
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

run_id="$(date -u +"%Y%m%dT%H%M%SZ")-$$"
retry_file="/tmp/grapple-v3/retry_${run_id}"
mkdir -p /tmp/grapple-v3
retries=0
echo "$retries" > "$retry_file"

commit_hash=""
diff_output=""
changed_files=""
diff_size=0
strict_json=""
auto_strict=false
strict_reasons=""
strict_mode=false
verdict="✅ PASS"
mode_line="default"
opencode_output=""
opencode_exit=0
rejection_reason=""

while true; do
  output_file=$(mktemp "/tmp/grapple-v3/opencode_${run_id}_XXXX.log")
  set +e
  opencode run "$task" 2>&1 | tee "$output_file"
  opencode_exit=${PIPESTATUS[0]}
  set -e
  opencode_output=$(cat "$output_file")

  # Check git diff (working tree)
  diff_output=$(git diff)
  if [[ -z "$diff_output" ]]; then
    report="🔍 Grapple Report — ${task_original}

Result: no changes
Run ID: ${run_id}"
    openclaw message send --channel telegram -t 1260478841 -m "$report"
    popd >/dev/null
    exit 0
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

  changed_files=$(git diff --name-only | tr '\n' ' ')
  diff_size=$(printf "%s" "$diff_output" | wc -l | tr -d ' ')

  # Detect rejection
  rejected=false
  rejection_reason=""
  if [[ $opencode_exit -ne 0 ]] || echo "$opencode_output" | grep -qi "REJECT"; then
    rejected=true
    reject_line=$(echo "$opencode_output" | grep -m1 -i "REJECT" || true)
    if [[ -n "$reject_line" ]]; then
      rejection_reason=$(echo "$reject_line" | sed -E 's/.*REJECT[: -]*//I')
    else
      rejection_reason="opencode exit code ${opencode_exit}"
    fi
  fi

  if [[ "$rejected" == true ]]; then
    if (( retries < 2 )); then
      retries=$((retries + 1))
      echo "$retries" > "$retry_file"
      task="${task_original} — Previous attempt was rejected: ${rejection_reason}. Please fix the issues and try again."
      continue
    else
      report="🚨 Grapple Escalation — ${task_original}

Reason: ${rejection_reason}
Retries: ${retries}
Run ID: ${run_id}"
      openclaw message send --channel telegram -t 1260478841 -m "$report"
      popd >/dev/null
      exit 1
    fi
  fi

  # PASS: commit + report
  git add -A
  summary=$(echo "$task_original" | tr '\n' ' ' | cut -c1-72)
  git commit -m "feat: ${summary}"
  commit_hash=$(git rev-parse HEAD)

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
  "run_id": "${run_id}",
  "task": "${task_original}",
  "project": "${project}",
  "commit": "${commit_hash}",
  "manual_strict": ${manual_strict},
  "auto_strict": ${auto_strict},
  "strict_reasons": [${strict_reasons}],
  "strict_mode": ${strict_mode},
  "verdict": "${verdict}",
  "changed_files": "${changed_files}",
  "diff_size": ${diff_size},
  "retries": ${retries},
  "note": "If strict, external judge must be triggered by orchestrator (Claw).",
  "timestamp": "${timestamp}"
}
EOF

  # Report
  report="🔍 Grapple Report — ${task_original}

Verdict: ${verdict}
Commit: ${commit_hash}
Mode: ${mode_line}
Retries: ${retries}

Changed files: ${changed_files}
Diff size: ${diff_size}

Log: tools/grapple-v3/logs/${timestamp}.json"

  openclaw message send --channel telegram -t 1260478841 -m "$report"

  break
done

popd >/dev/null
