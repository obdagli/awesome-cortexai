#!/usr/bin/env bash
set -euo pipefail

# Read diff from stdin
DIFF_CONTENT=$(cat)

reasons=()
strict=false

# Diff size check (line count)
line_count=$(printf "%s" "$DIFF_CONTENT" | wc -l | tr -d ' ')
if [[ "$line_count" -gt 200 ]]; then
  strict=true
  reasons+=("diff_size_gt_200")
fi

# Changed files check
# Extract file paths from diff headers
file_paths=$(printf "%s" "$DIFF_CONTENT" | awk '/^diff --git / {print $3" " $4}' | sed -E 's|^a/||; s|^b/||')

pattern_match=false
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  # line has "pathA pathB"; use pathB if present
  path=$(printf "%s" "$line" | awk '{print $2}')
  [[ -z "$path" ]] && path=$(printf "%s" "$line" | awk '{print $1}')

  if [[ "$path" == auth/* || "$path" == billing/* || "$path" == permissions/* || "$path" == infra/* ]]; then
    reasons+=("sensitive_path:${path}")
    strict=true
    pattern_match=true
  fi
  if [[ "$path" == *.env || "$path" == config/prod* || "$path" == MEMORY.md || "$path" == AGENTS.md || "$path" == *.service || "$path" == *crontab* ]]; then
    reasons+=("sensitive_file:${path}")
    strict=true
    pattern_match=true
  fi

  # Also consider directory matches anywhere in path (e.g., src/auth/)
  if [[ "$path" == *"/auth/"* || "$path" == *"/billing/"* || "$path" == *"/permissions/"* || "$path" == *"/infra/"* ]]; then
    reasons+=("sensitive_path:${path}")
    strict=true
    pattern_match=true
  fi

done <<< "$file_paths"

# Keyword check
if printf "%s" "$DIFF_CONTENT" | grep -Eiq '(password|token|secret|api_key|DROP TABLE|rm -rf|sudo)'; then
  strict=true
  reasons+=("sensitive_keywords")
fi

# Deduplicate reasons
if [[ ${#reasons[@]} -gt 0 ]]; then
  # shellcheck disable=SC2207
  reasons=($(printf "%s\n" "${reasons[@]}" | awk '!seen[$0]++'))
fi

# Build JSON
if [[ "$strict" == true ]]; then
  json_reasons=$(printf '"%s"' "${reasons[0]:-}" )
  if [[ ${#reasons[@]} -gt 1 ]]; then
    json_reasons=$(printf '"%s"' "${reasons[@]}")
    json_reasons=$(printf "%s" "$json_reasons" | sed 's/" "/", "/g')
  fi
  echo "{\"strict\": true, \"reasons\": [${json_reasons}] }"
else
  echo "{\"strict\": false, \"reasons\": []}"
fi
