#!/usr/bin/env bash
# grapple-pipeline-test.sh — Tests for the grapple pipeline
# Tests skip conditions, lint gate, JSON parsing, round cap, no-progress detection
#
# Usage: ./tools/grapple-pipeline-test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIPELINE="${SCRIPT_DIR}/grapple-pipeline.sh"
TEST_DIR=$(mktemp -d /tmp/grapple-test-XXXXXX)
PASS=0
FAIL=0

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

cleanup() { rm -rf "$TEST_DIR"; }
trap cleanup EXIT

# ── Test Helpers ─────────────────────────────────────────────────────────────

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo -e "${GREEN}✓ PASS${NC}: $desc"
    PASS=$((PASS + 1))
  else
    echo -e "${RED}✗ FAIL${NC}: $desc (expected=$expected, actual=$actual)"
    FAIL=$((FAIL + 1))
  fi
}

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if echo "$haystack" | grep -qF -- "$needle"; then
    echo -e "${GREEN}✓ PASS${NC}: $desc"
    PASS=$((PASS + 1))
  else
    echo -e "${RED}✗ FAIL${NC}: $desc (expected to contain: $needle)"
    FAIL=$((FAIL + 1))
  fi
}

init_test_repo() {
  local dir="$1"
  mkdir -p "$dir"
  cd "$dir"
  git init -q
  git config user.email "test@test.com"
  git config user.name "Test"
  echo "init" > README.md
  git add -A && git commit -q -m "init"
}

# ═══════════════════════════════════════════════════════════════════════════════
# TEST 1: Skip — Binary files only
# ═══════════════════════════════════════════════════════════════════════════════
echo -e "\n${YELLOW}═══ TEST 1: Skip binary files ═══${NC}"

REPO1="${TEST_DIR}/test-binary"
init_test_repo "$REPO1"

# Source the pipeline to test should_skip_file directly
source <(sed -n '/^should_skip_file/,/^}/p' "$PIPELINE")
source <(sed -n '/^SKIP_EXTENSIONS=/p; /^SKIP_DIRS=/p; /^SKIP_FILES=/p; /^DOCS_EXTENSIONS=/p' "$PIPELINE")

assert_eq "Skip .png file" "0" "$(should_skip_file "image.png" && echo 0 || echo 1)"
assert_eq "Skip .exe file" "0" "$(should_skip_file "app.exe" && echo 0 || echo 1)"
assert_eq "Skip package-lock.json" "0" "$(should_skip_file "package-lock.json" && echo 0 || echo 1)"
assert_eq "Skip vendor dir" "0" "$(should_skip_file "vendor/lib/foo.go" && echo 0 || echo 1)"
assert_eq "Skip node_modules" "0" "$(should_skip_file "node_modules/express/index.js" && echo 0 || echo 1)"
assert_eq "Skip generated .pb.go" "0" "$(should_skip_file "proto/service.pb.go" && echo 0 || echo 1)"
assert_eq "Don't skip .ts file" "1" "$(should_skip_file "src/app.ts" && echo 0 || echo 1)"
assert_eq "Don't skip .py file" "1" "$(should_skip_file "main.py" && echo 0 || echo 1)"
assert_eq "Don't skip .go file" "1" "$(should_skip_file "cmd/server.go" && echo 0 || echo 1)"

# ═══════════════════════════════════════════════════════════════════════════════
# TEST 2: Skip — Docs-only changes
# ═══════════════════════════════════════════════════════════════════════════════
echo -e "\n${YELLOW}═══ TEST 2: Docs-only detection ═══${NC}"

source <(sed -n '/^is_docs_file/,/^}/p' "$PIPELINE")

assert_eq "README.md is docs" "0" "$(is_docs_file "README.md" && echo 0 || echo 1)"
assert_eq "docs/guide.txt is docs" "0" "$(is_docs_file "docs/guide.txt" && echo 0 || echo 1)"
assert_eq "config.yml is docs" "0" "$(is_docs_file "config.yml" && echo 0 || echo 1)"
assert_eq "src/app.ts is NOT docs" "1" "$(is_docs_file "src/app.ts" && echo 0 || echo 1)"
assert_eq "main.py is NOT docs" "1" "$(is_docs_file "main.py" && echo 0 || echo 1)"

# ═══════════════════════════════════════════════════════════════════════════════
# TEST 3: Review JSON parsing
# ═══════════════════════════════════════════════════════════════════════════════
echo -e "\n${YELLOW}═══ TEST 3: Review JSON parsing ═══${NC}"

# Extract parse_review_json function
source <(sed -n '/^parse_review_json/,/^}/p' "$PIPELINE")

# Test fenced JSON
FENCED_INPUT='Some review text here.

```json
{"verdict":"APPROVE","confidence":95,"findings":[],"required_actions":[],"summary":"Looks good"}
```

More text after.'

PARSED=$(parse_review_json "$FENCED_INPUT" 2>/dev/null || echo "PARSE_FAIL")
if [[ "$PARSED" != "PARSE_FAIL" ]]; then
  VERDICT=$(echo "$PARSED" | python3 -c "import sys,json; print(json.load(sys.stdin)['verdict'])")
  assert_eq "Parse fenced JSON verdict" "APPROVE" "$VERDICT"
else
  assert_eq "Parse fenced JSON" "parsed" "PARSE_FAIL"
fi

# Test raw JSON in text
RAW_INPUT='After reviewing the code, here is my assessment:
{"verdict":"REVISE","confidence":60,"findings":[{"severity":"major","category":"security","file":"src/auth.ts","line":42,"description":"SQL injection","suggestion":"Use parameterized queries"}],"required_actions":["Fix SQL injection"],"summary":"Security issue found"}'

PARSED=$(parse_review_json "$RAW_INPUT" 2>/dev/null || echo "PARSE_FAIL")
if [[ "$PARSED" != "PARSE_FAIL" ]]; then
  VERDICT=$(echo "$PARSED" | python3 -c "import sys,json; print(json.load(sys.stdin)['verdict'])")
  assert_eq "Parse raw JSON verdict" "REVISE" "$VERDICT"
  FINDING_COUNT=$(echo "$PARSED" | python3 -c "import sys,json; print(len(json.load(sys.stdin).get('findings',[])))")
  assert_eq "Parse findings count" "1" "$FINDING_COUNT"
else
  assert_eq "Parse raw JSON" "parsed" "PARSE_FAIL"
fi

# Test unparseable input
BAD_INPUT="This is just plain text with no JSON at all."
PARSED=$(parse_review_json "$BAD_INPUT" 2>/dev/null || echo "PARSE_FAIL")
assert_eq "Reject non-JSON input" "PARSE_FAIL" "$PARSED"

# ═══════════════════════════════════════════════════════════════════════════════
# TEST 4: Preflight — not a git repo
# ═══════════════════════════════════════════════════════════════════════════════
echo -e "\n${YELLOW}═══ TEST 4: Preflight — not a git repo ═══${NC}"

NOT_GIT="${TEST_DIR}/not-a-repo"
mkdir -p "$NOT_GIT"
OUTPUT=$("$PIPELINE" --task "test" --repo "$NOT_GIT" 2>&1 || true)
EXIT_CODE=$?
# Pipeline should fail with exit 4
assert_contains "Preflight rejects non-git dir" "Not a git repository" "$OUTPUT"

# ═══════════════════════════════════════════════════════════════════════════════
# TEST 5: Dry run
# ═══════════════════════════════════════════════════════════════════════════════
echo -e "\n${YELLOW}═══ TEST 5: Dry run mode ═══${NC}"

REPO5="${TEST_DIR}/test-dryrun"
init_test_repo "$REPO5"
OUTPUT=$("$PIPELINE" --task "test task" --repo "$REPO5" --dry-run 2>&1)
assert_contains "Dry run shows task" "DRY RUN" "$OUTPUT"
assert_contains "Dry run shows models" "Writer" "$OUTPUT"

# ═══════════════════════════════════════════════════════════════════════════════
# TEST 6: Exit code mapping
# ═══════════════════════════════════════════════════════════════════════════════
echo -e "\n${YELLOW}═══ TEST 6: Exit code documentation ═══${NC}"

# Verify exit codes are documented in the script
SCRIPT_CONTENT=$(cat "$PIPELINE")
assert_contains "Exit 0 documented" "0=approved" "$SCRIPT_CONTENT"
assert_contains "Exit 1 documented" "1=rejected" "$SCRIPT_CONTENT"
assert_contains "Exit 2 documented" "2=blocked_precheck" "$SCRIPT_CONTENT"
assert_contains "Exit 3 documented" "3=aborted" "$SCRIPT_CONTENT"
assert_contains "Exit 4 documented" "4=error" "$SCRIPT_CONTENT"

# ═══════════════════════════════════════════════════════════════════════════════
# TEST 7: Max rounds cap
# ═══════════════════════════════════════════════════════════════════════════════
echo -e "\n${YELLOW}═══ TEST 7: Max rounds cap ═══${NC}"

assert_contains "MAX_ROUNDS defined" "MAX_ROUNDS=3" "$SCRIPT_CONTENT"
assert_contains "Round cap check exists" "ROUND -ge \$MAX_ROUNDS" "$SCRIPT_CONTENT"
assert_contains "Max rounds escalation" "Hit max rounds" "$SCRIPT_CONTENT"

# ═══════════════════════════════════════════════════════════════════════════════
# TEST 8: No-progress detection
# ═══════════════════════════════════════════════════════════════════════════════
echo -e "\n${YELLOW}═══ TEST 8: No-progress detection ═══${NC}"

assert_contains "No-progress check exists" "PREV_FINDINGS" "$SCRIPT_CONTENT"
assert_contains "No-progress verdict" "ABORTED_NO_PROGRESS" "$SCRIPT_CONTENT"
assert_contains "No-progress exit code" "exit 3" "$SCRIPT_CONTENT"

# ═══════════════════════════════════════════════════════════════════════════════
# TEST 9: Grapple flag in dispatch
# ═══════════════════════════════════════════════════════════════════════════════
echo -e "\n${YELLOW}═══ TEST 9: Dispatch --grapple flag ═══${NC}"

DISPATCH_CONTENT=$(cat "${SCRIPT_DIR}/opencode-dispatch.sh")
assert_contains "Grapple flag in dispatch" "--grapple" "$DISPATCH_CONTENT"
assert_contains "Grapple routing logic" "grapple-pipeline.sh" "$DISPATCH_CONTENT"
assert_contains "Quick profile grapple skip" "quick tasks never trigger grapple" "$DISPATCH_CONTENT"

# ═══════════════════════════════════════════════════════════════════════════════
# TEST 10: Policy file exists
# ═══════════════════════════════════════════════════════════════════════════════
echo -e "\n${YELLOW}═══ TEST 10: Policy file ═══${NC}"

POLICY="/home/brk/.grapple/policy.yml"
if [[ -f "$POLICY" ]]; then
  POLICY_CONTENT=$(cat "$POLICY")
  assert_contains "Policy has skip section" "skip:" "$POLICY_CONTENT"
  assert_contains "Policy has extensions" "extensions:" "$POLICY_CONTENT"
  assert_contains "Policy has directories" "directories:" "$POLICY_CONTENT"
  assert_contains "Policy has review settings" "review:" "$POLICY_CONTENT"
else
  assert_eq "Policy file exists" "exists" "missing"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# RESULTS
# ═══════════════════════════════════════════════════════════════════════════════
echo -e "\n${YELLOW}═══════════════════════════════════════${NC}"
TOTAL=$((PASS + FAIL))
echo -e "Results: ${GREEN}${PASS} passed${NC}, ${RED}${FAIL} failed${NC} / ${TOTAL} total"

if [[ $FAIL -gt 0 ]]; then
  echo -e "${RED}Some tests failed!${NC}"
  exit 1
else
  echo -e "${GREEN}All tests passed!${NC}"
  exit 0
fi
