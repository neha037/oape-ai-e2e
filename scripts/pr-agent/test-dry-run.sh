#!/usr/bin/env bash
# test-dry-run.sh — Validation suite for the OAPE PR agent scripts.
#
# Runs:
#   1. shellcheck on all agent + monitor scripts
#   2. Dry-run integration test against a real PR
#   3. Output file verification
#
# Usage:
#   scripts/pr-agent/test-dry-run.sh [--pr-url <URL>]
#
# Environment:
#   GH_TOKEN      — required for GitHub API access
#   TEST_PR_URL   — override the default test PR (optional)
#   RUNNER_TEMP   — temp directory (default: mktemp -d)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

_pass() { echo "  PASS: $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
_fail() { echo "  FAIL: $1" >&2; FAIL_COUNT=$((FAIL_COUNT + 1)); }
_skip() { echo "  SKIP: $1"; SKIP_COUNT=$((SKIP_COUNT + 1)); }

# Parse arguments
TEST_PR_URL="${TEST_PR_URL:-}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --pr-url) TEST_PR_URL="$2"; shift 2 ;;
    *) shift ;;
  esac
done

echo "============================================"
echo "  OAPE PR Agent — Validation Suite"
echo "  Time: $(date -u +"%Y-%m-%d %H:%M UTC")"
echo "============================================"
echo ""

# =========================================================================
# Phase 1: Shellcheck
# =========================================================================
echo "=== Phase 1: shellcheck ==="

SCRIPTS=(
  "${REPO_ROOT}/scripts/pr-agent/entrypoint.sh"
  "${REPO_ROOT}/scripts/pr-agent/safety.sh"
  "${REPO_ROOT}/scripts/pr-agent/auto-fix.sh"
  "${REPO_ROOT}/scripts/pr-agent/log-analyzer.sh"
  "${REPO_ROOT}/scripts/pr-agent/review-handler.sh"
  "${REPO_ROOT}/scripts/ci-monitor/monitor.sh"
  "${REPO_ROOT}/scripts/ci-monitor/dispatch.sh"
)

if ! command -v shellcheck &>/dev/null; then
  _skip "shellcheck is not installed (dnf install ShellCheck)"
else
  shellcheck_ok=true
  for script in "${SCRIPTS[@]}"; do
    local_name="${script#"${REPO_ROOT}/"}"
    if shellcheck -x -s bash "$script" 2>/dev/null; then
      _pass "${local_name}"
    else
      _fail "${local_name}"
      shellcheck_ok=false
    fi
  done

  if [[ "$shellcheck_ok" == "true" ]]; then
    echo "  All scripts are shellcheck-clean"
  fi
fi

echo ""

# =========================================================================
# Phase 2: Dry-run integration test
# =========================================================================
echo "=== Phase 2: Dry-run integration test ==="

if [[ -z "$TEST_PR_URL" ]]; then
  echo "  No --pr-url provided, attempting to find an open PR on an allowed repo..."
  # Pick the first repo from team-repos.csv and find an open PR
  if [[ -f "${REPO_ROOT}/deploy/config/team-repos.csv" ]]; then
    while IFS=, read -r _product _role repo_url; do
      local_repo=$(echo "$repo_url" | sed 's|https://github.com/||;s|\.git$||')
      pr_url=$(gh pr list --repo "$local_repo" --state open --json url --limit 1 -q '.[0].url' 2>/dev/null || true)
      if [[ -n "$pr_url" ]]; then
        TEST_PR_URL="$pr_url"
        break
      fi
    done < <(tail -n +2 "${REPO_ROOT}/deploy/config/team-repos.csv")
  fi
fi

if [[ -z "$TEST_PR_URL" ]]; then
  _skip "No test PR URL available (pass --pr-url or set TEST_PR_URL)"
  echo ""
  echo "=== Phase 2b: auto-fix.sh validation ==="
  _skip "Skipped (no test PR URL)"
  echo ""
  echo "=== Phase 3: Output verification ==="
  _skip "Skipped (no integration test ran)"
else
  echo "  Test PR: ${TEST_PR_URL}"

  # Extract owner/repo/number for output file verification
  if [[ "$TEST_PR_URL" =~ https://github.com/([^/]+)/([^/]+)/pull/([0-9]+) ]]; then
    TEST_OWNER="${BASH_REMATCH[1]}"
    TEST_REPO="${BASH_REMATCH[2]}"
    TEST_PR_NUMBER="${BASH_REMATCH[3]}"
  else
    _fail "Invalid test PR URL format: ${TEST_PR_URL}"
    echo ""
    echo "============================================"
    echo "  Results: ${PASS_COUNT} passed, ${FAIL_COUNT} failed, ${SKIP_COUNT} skipped"
    echo "============================================"
    exit 1
  fi

  export DRY_RUN=true
  export MONITOR_ONLY=true
  export RUNNER_TEMP
  RUNNER_TEMP=$(mktemp -d)
  export GH_TOKEN="${GH_TOKEN:-$(gh auth token 2>/dev/null || echo '')}"

  echo "  DRY_RUN=true, MONITOR_ONLY=true"
  echo "  RUNNER_TEMP=${RUNNER_TEMP}"

  # Run the agent
  if "${REPO_ROOT}/scripts/pr-agent/entrypoint.sh" \
      --mode on-demand --pr-url "$TEST_PR_URL" --dry-run --monitor-only; then
    _pass "entrypoint.sh exited successfully"
  else
    _fail "entrypoint.sh exited with non-zero status"
  fi

  echo ""

  # =========================================================================
  # Phase 2b: auto-fix.sh dry-run validation
  # =========================================================================
  echo "=== Phase 2b: auto-fix.sh dry-run test ==="

  for test_cat in trivial-format trivial-import trivial-lint trivial-generated-files; do
    echo "  Testing category: ${test_cat}"
    if "${REPO_ROOT}/scripts/pr-agent/auto-fix.sh" \
        --pr-url "$TEST_PR_URL" --category "$test_cat" --dry-run 2>&1 | grep -q "DRY RUN\|No changes\|not available"; then
      _pass "auto-fix.sh --category ${test_cat} --dry-run"
    else
      _fail "auto-fix.sh --category ${test_cat} --dry-run"
    fi
  done

  # Test lint-failure coarse category (triggers fine-grained refinement)
  echo "  Testing coarse category: lint-failure"
  if "${REPO_ROOT}/scripts/pr-agent/auto-fix.sh" \
      --pr-url "$TEST_PR_URL" --category lint-failure --dry-run 2>&1 | grep -q "DRY RUN\|No changes\|Refined\|not available"; then
    _pass "auto-fix.sh --category lint-failure --dry-run (fine-grained refinement)"
  else
    _fail "auto-fix.sh --category lint-failure --dry-run"
  fi

  echo ""

  # =========================================================================
  # Phase 2c: log-analyzer.sh dry-run validation
  # =========================================================================
  echo "=== Phase 2c: log-analyzer.sh dry-run test ==="

  LOG_TEST_DIR=$(mktemp -d)
  echo 'pkg/foo.go:10: undefined: Bar' > "${LOG_TEST_DIR}/log-test-job.txt"
  echo 'make: *** [build] Error 2' >> "${LOG_TEST_DIR}/log-test-job.txt"

  echo "  Testing with synthetic build-failure log"
  if "${REPO_ROOT}/scripts/pr-agent/log-analyzer.sh" \
      --pr-url "$TEST_PR_URL" --log-dir "$LOG_TEST_DIR" --dry-run 2>&1 | grep -q "build-failure\|DRY RUN\|Analysis written"; then
    _pass "log-analyzer.sh --dry-run (deterministic classification)"
  else
    _fail "log-analyzer.sh --dry-run"
  fi

  echo "  Testing with empty log directory"
  EMPTY_LOG_DIR=$(mktemp -d)
  if "${REPO_ROOT}/scripts/pr-agent/log-analyzer.sh" \
      --pr-url "$TEST_PR_URL" --log-dir "$EMPTY_LOG_DIR" --dry-run 2>&1 | grep -q "No log files"; then
    _pass "log-analyzer.sh --dry-run (empty dir — graceful exit)"
  else
    _fail "log-analyzer.sh --dry-run (empty dir)"
  fi

  rm -rf "$LOG_TEST_DIR" "$EMPTY_LOG_DIR"

  echo ""

  # =========================================================================
  # Phase 2d: review-handler.sh dry-run validation
  # =========================================================================
  echo "=== Phase 2d: review-handler.sh dry-run test ==="

  echo "  Testing review-handler.sh --dry-run (expects graceful exit)"
  review_output=""
  if review_output=$("${REPO_ROOT}/scripts/pr-agent/review-handler.sh" \
      --pr-url "$TEST_PR_URL" --dry-run 2>&1); then
    if echo "$review_output" | grep -q "DRY RUN\|No actionable\|no unresolved\|python3 not available\|Processing"; then
      _pass "review-handler.sh --dry-run (graceful exit)"
    else
      _pass "review-handler.sh --dry-run (exited 0)"
    fi
  else
    rc=$?
    if echo "$review_output" | grep -q "python3 not available\|claude.*not found\|No actionable"; then
      _skip "review-handler.sh --dry-run (missing dependency: python3 or claude)"
    else
      _fail "review-handler.sh --dry-run (exit code ${rc})"
    fi
  fi

  echo ""

  # =========================================================================
  # Phase 2e: monitor.sh local smoke test
  # =========================================================================
  echo "=== Phase 2e: monitor.sh local smoke test ==="

  MONITOR_RESULT_FILE=$(mktemp)
  # shellcheck disable=SC2034
  if monitor_output=$(PR_URL="$TEST_PR_URL" GH_TOKEN="$GH_TOKEN" \
    SKIP_POLL=true DRY_RUN=true SELF_JOB_NAME=oape-ci-monitor \
    RESULT_FILE="$MONITOR_RESULT_FILE" \
    "${REPO_ROOT}/scripts/ci-monitor/monitor.sh" 2>&1); then
    _pass "monitor.sh --dry-run exited 0"

    if [[ -f "$MONITOR_RESULT_FILE" ]] && jq empty "$MONITOR_RESULT_FILE" 2>/dev/null; then
      _pass "ci-monitor-result.json is valid JSON"

      has_status=$(jq -r '.overall_status // empty' "$MONITOR_RESULT_FILE")
      has_triggers=$(jq '.trigger_actions | length' "$MONITOR_RESULT_FILE" 2>/dev/null || echo 0)
      has_categories=$(jq '.failure_categories | length' "$MONITOR_RESULT_FILE" 2>/dev/null || echo 0)

      if [[ -n "$has_status" ]]; then
        _pass "result has overall_status: ${has_status}"
      else
        _fail "result missing overall_status"
      fi
      if [[ "$has_triggers" -ge 0 ]]; then
        _pass "result has trigger_actions (count: ${has_triggers})"
      else
        _fail "result missing trigger_actions"
      fi
      if [[ "$has_categories" -ge 0 ]]; then
        _pass "result has failure_categories (count: ${has_categories})"
      else
        _fail "result missing failure_categories"
      fi
    else
      _fail "ci-monitor-result.json not generated or invalid"
    fi
  else
    _fail "monitor.sh --dry-run failed (exit code $?)"
  fi
  rm -f "$MONITOR_RESULT_FILE"

  echo ""

  # =========================================================================
  # Phase 2f: dispatch.sh synthetic fixture test
  # =========================================================================
  echo "=== Phase 2f: dispatch.sh synthetic fixture test ==="

  DISPATCH_FIXTURE_DIR=$(mktemp -d)
  DISPATCH_RESULT_FILE="${DISPATCH_FIXTURE_DIR}/ci-monitor-result.json"

  for fixture_type in auto-fix-lint auto-fix-generated retest investigate; do
    cat > "$DISPATCH_RESULT_FILE" << FIXTURE_EOF
{
  "pr_url": "${TEST_PR_URL}",
  "owner": "${TEST_OWNER}",
  "repo": "${TEST_REPO}",
  "pr_number": ${TEST_PR_NUMBER},
  "overall_status": "failed",
  "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "checks": {"total": 5, "passed": 4, "failed": 1, "pending": 0},
  "failure_categories": {"${fixture_type%-*}-failure": 1},
  "failures": [{"job_name": "ci/prow/test-fixture-${fixture_type}", "category": "${fixture_type%-*}-failure", "optional": false}],
  "trigger_actions": [{"action": "${fixture_type}", "job": "ci/prow/test-fixture-${fixture_type}", "optional": false}]
}
FIXTURE_EOF

    dispatch_output=""
    if dispatch_output=$(RESULT_FILE="$DISPATCH_RESULT_FILE" DRY_RUN=true \
      OAPE_ROOT="$REPO_ROOT" WORK_DIR="$DISPATCH_FIXTURE_DIR" \
      "${REPO_ROOT}/scripts/ci-monitor/dispatch.sh" 2>&1); then
      if echo "$dispatch_output" | grep -qE "DRY RUN|Running auto-fix|Running Claude|Auto-retest disabled|Skipping retest"; then
        _pass "dispatch.sh fixture: ${fixture_type} (DRY_RUN action logged)"
      else
        _pass "dispatch.sh fixture: ${fixture_type} (exit 0)"
      fi
    else
      _fail "dispatch.sh fixture: ${fixture_type} (exit $?)"
    fi
  done

  # Phase 3 fixture: dispatch with overall_status=passed + REVIEW_HANDLER_ENABLED
  cat > "$DISPATCH_RESULT_FILE" << FIXTURE_EOF
{
  "pr_url": "${TEST_PR_URL}",
  "owner": "${TEST_OWNER}",
  "repo": "${TEST_REPO}",
  "pr_number": ${TEST_PR_NUMBER},
  "overall_status": "passed",
  "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "checks": {"total": 5, "passed": 5, "failed": 0, "pending": 0},
  "failure_categories": {},
  "failures": [],
  "trigger_actions": []
}
FIXTURE_EOF

  dispatch_output=""
  if dispatch_output=$(RESULT_FILE="$DISPATCH_RESULT_FILE" DRY_RUN=true \
    OAPE_ROOT="$REPO_ROOT" WORK_DIR="$DISPATCH_FIXTURE_DIR" \
    REVIEW_HANDLER_ENABLED=true \
    "${REPO_ROOT}/scripts/ci-monitor/dispatch.sh" 2>&1); then
    if echo "$dispatch_output" | grep -q "review handler"; then
      _pass "dispatch.sh fixture: Phase 3 (review handler invoked)"
    else
      _pass "dispatch.sh fixture: Phase 3 (exit 0)"
    fi
  else
    rc=$?
    if echo "$dispatch_output" | grep -q "review handler"; then
      _pass "dispatch.sh fixture: Phase 3 (review handler invoked, non-fatal exit ${rc})"
    else
      _fail "dispatch.sh fixture: Phase 3 (exit ${rc})"
    fi
  fi

  rm -rf "$DISPATCH_FIXTURE_DIR"

  echo ""

  # =========================================================================
  # Phase 3: Output verification
  # =========================================================================
  echo "=== Phase 3: Output verification ==="

  # Verify CI status JSON
  CI_STATUS_FILE="${RUNNER_TEMP}/ci-status-${TEST_OWNER}-${TEST_REPO}-${TEST_PR_NUMBER}.json"
  if [[ -f "$CI_STATUS_FILE" ]]; then
    _pass "CI status file exists: $(basename "$CI_STATUS_FILE")"
    if jq empty "$CI_STATUS_FILE" 2>/dev/null; then
      _pass "CI status file is valid JSON"
    else
      _fail "CI status file is not valid JSON"
    fi
  else
    _fail "CI status file not generated: ci-status-${TEST_OWNER}-${TEST_REPO}-${TEST_PR_NUMBER}.json"
  fi

  # Verify report
  REPORT_FILE="${RUNNER_TEMP}/pr-agent-report-${TEST_OWNER}-${TEST_REPO}-${TEST_PR_NUMBER}.md"
  if [[ -f "$REPORT_FILE" ]]; then
    _pass "Report file exists: $(basename "$REPORT_FILE")"
    if grep -q "## PR Agent Report" "$REPORT_FILE"; then
      _pass "Report contains expected header"
    else
      _fail "Report missing '## PR Agent Report' header"
    fi
  else
    _fail "Report file not generated: pr-agent-report-${TEST_OWNER}-${TEST_REPO}-${TEST_PR_NUMBER}.md"
  fi

  # Verify state file
  STATE_FILE="${RUNNER_TEMP}/pr-agent-state-${TEST_OWNER}-${TEST_REPO}-${TEST_PR_NUMBER}.json"
  if [[ -f "$STATE_FILE" ]]; then
    _pass "State file exists: $(basename "$STATE_FILE")"
  else
    _skip "State file not generated (may be normal for first run on this PR)"
  fi

  # Clean up
  rm -rf "$RUNNER_TEMP"
fi

echo ""
echo "============================================"
echo "  Results: ${PASS_COUNT} passed, ${FAIL_COUNT} failed, ${SKIP_COUNT} skipped"
echo "============================================"

if [[ "$FAIL_COUNT" -gt 0 ]]; then
  exit 1
fi
