#!/usr/bin/env bash
# monitor.sh — OAPE CI Monitor.
#
# Analyzes CI failures on a PR: collects GCS artifacts for failed jobs,
# classifies failures deterministically, queries Sippy for flake history,
# and produces a structured failure analysis report.
#
# Supports two modes:
#   Event-triggered (SKIP_POLL=true): fetches checks once, no polling.
#   Polling (default): polls CI checks until all complete or timeout.
#
# Runs from any CI system (GitHub Actions, Prow, or locally).
#
# Required environment:
#   PR_URL          — Full GitHub PR URL (e.g. https://github.com/org/repo/pull/123)
#   GH_TOKEN        — GitHub token for API access
#
# Optional environment:
#   SKIP_POLL        — If "true", fetch checks once without polling (for event triggers)
#   POLL_INTERVAL    — Seconds between CI status polls (default: 120)
#   POLL_TIMEOUT     — Max seconds to wait for all checks (default: 7200)
#   GCSWEB_BASE_URL  — Base URL for gcsweb artifact access
#   SIPPY_API_URL    — Base URL for Sippy flake history API
#   DRY_RUN          — If "true", skip PR comment posting
#   RESULT_FILE      — Path for machine-readable JSON output
#   SELF_JOB_NAME    — This job's name in CI (excluded from monitoring)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
PR_URL="${PR_URL:-}"
DRY_RUN="${DRY_RUN:-false}"
SKIP_POLL="${SKIP_POLL:-false}"
POLL_INTERVAL="${POLL_INTERVAL:-120}"
POLL_TIMEOUT="${POLL_TIMEOUT:-7200}"
GCSWEB_BASE_URL="${GCSWEB_BASE_URL:-https://gcsweb-ci.apps.ci.l2s4.p1.openshiftapps.com}"
SIPPY_API_URL="${SIPPY_API_URL:-https://sippy.dptools.openshift.org}"
SELF_JOB_NAME="${SELF_JOB_NAME:-oape-ci-monitor}"
RESULT_FILE="${RESULT_FILE:-/tmp/ci-monitor-result.json}"
WORK_DIR="${WORK_DIR:-/tmp/ci-monitor}"
REPORT_MARKER="<!-- oape-ci-monitor -->"

# Parsed from PR_URL
OWNER=""
REPO=""
PR_NUMBER=""

# ---------------------------------------------------------------------------
# Utility: retry with exponential backoff
# ---------------------------------------------------------------------------
gh_retry() {
  local retries=3 delay=5
  for ((i = 1; i <= retries; i++)); do
    if "$@"; then
      return 0
    fi
    if [[ "$i" -lt "$retries" ]]; then
      echo "[retry] Attempt ${i}/${retries} failed, waiting ${delay}s..." >&2
      sleep "$delay"
      delay=$((delay * 3))
    fi
  done
  echo "[retry] All ${retries} attempts failed for: $*" >&2
  return 1
}

# ---------------------------------------------------------------------------
# Parse PR URL into OWNER, REPO, PR_NUMBER
# ---------------------------------------------------------------------------
parse_pr_url() {
  local url="$1"
  if [[ "$url" =~ https://github.com/([^/]+)/([^/]+)/pull/([0-9]+) ]]; then
    OWNER="${BASH_REMATCH[1]}"
    REPO="${BASH_REMATCH[2]}"
    PR_NUMBER="${BASH_REMATCH[3]}"
  else
    echo "ERROR: Invalid PR URL format: $url" >&2
    echo "Expected: https://github.com/{owner}/{repo}/pull/{number}" >&2
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# Prechecks
# ---------------------------------------------------------------------------
run_prechecks() {
  echo "[precheck] Verifying prerequisites..."

  if [[ -z "$PR_URL" ]]; then
    echo "ERROR: PR_URL environment variable is required" >&2
    exit 1
  fi

  if [[ -z "${GH_TOKEN:-}" ]]; then
    echo "ERROR: GH_TOKEN environment variable is required" >&2
    exit 1
  fi

  if ! command -v gh &>/dev/null; then
    echo "ERROR: gh CLI is not installed" >&2
    exit 1
  fi

  if ! command -v jq &>/dev/null; then
    echo "ERROR: jq is not installed" >&2
    exit 1
  fi

  if ! gh auth status &>/dev/null; then
    echo "ERROR: gh CLI is not authenticated" >&2
    exit 1
  fi

  mkdir -p "$WORK_DIR"
  echo "[precheck] All prechecks passed"
}

# ===========================================================================
# Phase 1: Poll CI checks until all complete (or timeout)
# ===========================================================================
fetch_ci_checks() {
  local output_file="${WORK_DIR}/ci-checks.json"

  if ! gh_retry gh pr checks "$PR_NUMBER" --repo "${OWNER}/${REPO}" \
    --json name,state,link,bucket \
    > "$output_file" 2>/dev/null; then
    echo "[]" > "$output_file"
  fi

  # Filter out self (the ci-monitor job) to avoid circular dependency
  local filtered
  filtered=$(jq --arg self "$SELF_JOB_NAME" \
    '[.[] | select(.name != $self and (.name | contains($self) | not))]' \
    "$output_file")
  echo "$filtered" > "$output_file"

  echo "$output_file"
}

get_check_summary() {
  local checks_file="$1"
  local total passed failed pending

  total=$(jq 'length' "$checks_file")
  passed=$(jq '[.[] | select(.bucket == "pass")] | length' "$checks_file")
  failed=$(jq '[.[] | select(.bucket == "fail")] | length' "$checks_file")
  pending=$(jq '[.[] | select(.bucket == "pending")] | length' "$checks_file")

  echo "${passed}/${total} passed | ${failed} failed | ${pending} pending"
}

all_checks_complete() {
  local checks_file="$1"
  local pending
  pending=$(jq '[.[] | select(.bucket == "pending")] | length' "$checks_file")
  [[ "$pending" -eq 0 ]]
}

poll_until_complete() {
  echo "[poll] Waiting for all CI checks to complete (timeout: ${POLL_TIMEOUT}s, interval: ${POLL_INTERVAL}s)..."

  local elapsed=0
  local checks_file

  while true; do
    checks_file=$(fetch_ci_checks)
    local summary
    summary=$(get_check_summary "$checks_file")
    echo "[poll] [${elapsed}s] CI status: ${summary}"

    if all_checks_complete "$checks_file"; then
      echo "[poll] All CI checks complete after ${elapsed}s"
      return 0
    fi

    if [[ "$elapsed" -ge "$POLL_TIMEOUT" ]]; then
      echo "[poll] Timeout reached (${POLL_TIMEOUT}s) — reporting on current state"
      return 0
    fi

    sleep "$POLL_INTERVAL"
    elapsed=$((elapsed + POLL_INTERVAL))
  done
}

# ===========================================================================
# Phase 2: Collect GCS artifacts for failed jobs
# ===========================================================================
fetch_gcs_artifact() {
  local job_name="$1"
  local job_url="$2"
  local log_file="${WORK_DIR}/log-$(echo "$job_name" | tr '/ ' '__').txt"

  if [[ "$job_url" == *"prow"* ]] || [[ "$job_url" == *"/view/gs/"* ]]; then
    local gcs_path
    gcs_path=$(echo "$job_url" | sed -n 's|.*/view/g[cs]s\?/||p')
    if [[ -n "$gcs_path" ]]; then
      local build_log_url="${GCSWEB_BASE_URL}/gcs/${gcs_path}/build-log.txt"
      echo "[artifacts] Fetching build-log.txt for ${job_name}..."
      if curl -sSL --max-time 30 "$build_log_url" 2>/dev/null | tail -2000 > "$log_file" 2>/dev/null; then
        if [[ -s "$log_file" ]]; then
          echo "[artifacts] Collected build-log.txt ($(wc -l < "$log_file") lines)"

          # Also try to fetch junit XML for test-level detail
          local junit_url="${GCSWEB_BASE_URL}/gcs/${gcs_path}/artifacts/junit/"
          curl -sSL --max-time 15 "$junit_url" 2>/dev/null \
            | grep -oP 'href="[^"]*\.xml"' \
            | head -5 \
            | sed 's/href="//;s/"//' \
            | while read -r xml_path; do
                curl -sSL --max-time 15 "${junit_url}${xml_path}" 2>/dev/null \
                  >> "${WORK_DIR}/junit-$(echo "$job_name" | tr '/ ' '__').xml" || true
              done
          return 0
        fi
      fi
    fi
  fi

  if [[ "$job_url" == *"github.com"*"/actions/"* ]]; then
    local run_id
    run_id=$(echo "$job_url" | grep -oP 'runs/\K[0-9]+' || true)
    if [[ -n "$run_id" ]]; then
      echo "[artifacts] Fetching GHA failed step logs for ${job_name}..."
      gh_retry gh run view "$run_id" --repo "${OWNER}/${REPO}" --log-failed \
        > "$log_file" 2>/dev/null || true
      if [[ -s "$log_file" ]]; then
        echo "[artifacts] Collected GHA logs ($(wc -l < "$log_file") lines)"
        return 0
      fi
    fi
  fi

  echo "[artifacts] No logs collected for ${job_name}"
  return 1
}

collect_failure_artifacts() {
  local checks_file="${WORK_DIR}/ci-checks.json"
  local collected=0

  echo "[artifacts] Collecting artifacts for failed jobs..."

  jq -r '.[] | select(.bucket == "fail") | "\(.name)\t\(.link)"' "$checks_file" \
    | while IFS=$'\t' read -r job_name job_url; do
        [[ -z "$job_name" ]] && continue
        if fetch_gcs_artifact "$job_name" "${job_url:-}"; then
          collected=$((collected + 1))
        fi
      done

  echo "[artifacts] Collection complete"
}

# ===========================================================================
# Phase 3: Deterministic failure classification
# ===========================================================================
classify_single_failure() {
  local log_file="$1"

  if [[ ! -s "$log_file" ]]; then
    echo "unknown"
    return
  fi

  local content
  content=$(cat "$log_file")

  # Install failures (cluster provisioning)
  if echo "$content" | grep -qiE 'failed to install|cluster installation failed|install.*timed out|waiting for bootstrap|failed to create cluster'; then
    echo "install-failure"
  # Build failures
  elif echo "$content" | grep -qiE 'cannot compile|undefined:|syntax error|cannot use.*as.*in|build.*failed|compilation error'; then
    echo "build-failure"
  # Lint / formatting failures
  elif echo "$content" | grep -qiE 'gofmt|goimports|formatting differs|golangci-lint|golint|staticcheck|revive|lint.*failed'; then
    echo "lint-failure"
  # Generated files out of date
  elif echo "$content" | grep -qiE 'generated code is out of date|make generate|make manifests|deepcopy-gen|zz_generated|boilerplate'; then
    echo "lint-failure"
  # Test failures
  elif echo "$content" | grep -qiE '--- FAIL|FAIL\s|panic:.*test|assertion failed|test.*failed'; then
    echo "test-failure"
  # Infrastructure flakes
  elif echo "$content" | grep -qiE 'context deadline exceeded|connection refused|i/o timeout|ErrImagePull|ImagePullBackOff|pod sandbox|TLS handshake timeout|quota.*exceeded|unable to provision'; then
    echo "infra-flake"
  else
    echo "unknown"
  fi
}

classify_all_failures() {
  local checks_file="${WORK_DIR}/ci-checks.json"
  local analysis_file="${WORK_DIR}/failure-analysis.json"
  local results="[]"

  echo "[classify] Classifying failures..."

  jq -r '.[] | select(.bucket == "fail") | .name' "$checks_file" \
    | while IFS= read -r job_name; do
        [[ -z "$job_name" ]] && continue
        local log_id
        log_id=$(echo "$job_name" | tr '/ ' '__')
        local log_file="${WORK_DIR}/log-${log_id}.txt"

        local category
        category=$(classify_single_failure "$log_file")

        echo "${job_name}	${category}"
      done > "${WORK_DIR}/classifications.tsv"

  # Build JSON from TSV
  while IFS=$'\t' read -r job_name category; do
    [[ -z "$job_name" ]] && continue
    local log_id
    log_id=$(echo "$job_name" | tr '/ ' '__')
    local log_file="${WORK_DIR}/log-${log_id}.txt"
    local job_url
    job_url=$(jq -r --arg name "$job_name" '.[] | select(.name == $name) | .link' "$checks_file")

    local snippet=""
    if [[ -s "$log_file" ]]; then
      snippet=$(tail -20 "$log_file" | head -10 | tr '"' "'" | tr '\n' '|' | cut -c1-500)
    fi

    results=$(echo "$results" | jq \
      --arg name "$job_name" \
      --arg cat "$category" \
      --arg url "$job_url" \
      --arg snip "$snippet" \
      '. + [{"job_name": $name, "category": $cat, "url": $url, "log_snippet": $snip, "flake_probability": 0}]')
  done < "${WORK_DIR}/classifications.tsv"

  echo "$results" > "$analysis_file"

  local total_failures
  total_failures=$(echo "$results" | jq 'length')
  local by_category
  by_category=$(echo "$results" | jq -r 'group_by(.category) | map("\(.[0].category): \(length)") | join(", ")')
  echo "[classify] ${total_failures} failures classified: ${by_category}"
}

# ===========================================================================
# Phase 4: Sippy flake history lookup
# ===========================================================================
query_sippy_flakes() {
  local analysis_file="${WORK_DIR}/failure-analysis.json"

  if [[ ! -f "$analysis_file" ]]; then
    return 0
  fi

  local test_failures
  test_failures=$(jq -r '.[] | select(.category == "test-failure") | .job_name' "$analysis_file")

  if [[ -z "$test_failures" ]]; then
    echo "[sippy] No test failures to check"
    return 0
  fi

  echo "[sippy] Querying Sippy for flake history..."

  while IFS= read -r job_name; do
    [[ -z "$job_name" ]] && continue

    local sippy_url="${SIPPY_API_URL}/api/jobs/flakes?job=${job_name}"
    local flake_data
    flake_data=$(curl -sSL --max-time 10 "$sippy_url" 2>/dev/null || echo "{}")

    local flake_pct
    flake_pct=$(echo "$flake_data" | jq -r '.flakePercentage // 0' 2>/dev/null || echo "0")

    if [[ "$flake_pct" != "0" && "$flake_pct" != "null" ]]; then
      echo "[sippy] ${job_name}: ${flake_pct}% flake rate"

      # Update the analysis with flake probability
      local updated
      updated=$(jq --arg name "$job_name" --argjson pct "$flake_pct" \
        'map(if .job_name == $name then .flake_probability = $pct else . end)' \
        "$analysis_file")
      echo "$updated" > "$analysis_file"

      # Reclassify as infra-flake if flake rate is high (>30%)
      if (( $(echo "$flake_pct > 30" | bc -l 2>/dev/null || echo 0) )); then
        updated=$(jq --arg name "$job_name" \
          'map(if .job_name == $name then .category = "infra-flake" else . end)' \
          "$analysis_file")
        echo "$updated" > "$analysis_file"
        echo "[sippy] ${job_name}: reclassified as infra-flake (flake rate ${flake_pct}%)"
      fi
    fi
  done <<< "$test_failures"

  echo "[sippy] Flake history lookup complete"
}

# ===========================================================================
# Phase 5: Generate structured report
# ===========================================================================
generate_report() {
  local checks_file="${WORK_DIR}/ci-checks.json"
  local analysis_file="${WORK_DIR}/failure-analysis.json"
  local report_file="${WORK_DIR}/report.md"

  local total passed failed pending
  total=$(jq 'length' "$checks_file")
  passed=$(jq '[.[] | select(.bucket == "pass")] | length' "$checks_file")
  failed=$(jq '[.[] | select(.bucket == "fail")] | length' "$checks_file")
  pending=$(jq '[.[] | select(.bucket == "pending")] | length' "$checks_file")

  local pr_title
  pr_title=$(gh_retry gh pr view "$PR_NUMBER" --repo "${OWNER}/${REPO}" \
    --json title -q '.title' 2>/dev/null || echo "unknown")

  {
    echo "${REPORT_MARKER}"
    echo "## CI Monitor Report: ${OWNER}/${REPO}#${PR_NUMBER}"
    echo ""
    echo "**PR:** [${pr_title}](${PR_URL})"
    echo "**Monitored at:** $(date -u +'%Y-%m-%d %H:%M UTC')"
    echo ""

    # Overall status
    if [[ "$failed" -eq 0 && "$pending" -eq 0 ]]; then
      echo "**All ${total} CI checks passed.**"
      echo ""
    else
      echo "### CI Check Summary"
      echo ""
      echo "| Status | Count |"
      echo "|--------|-------|"
      echo "| Passed | ${passed} |"
      echo "| Failed | ${failed} |"
      echo "| Pending | ${pending} |"
      echo "| **Total** | **${total}** |"
      echo ""
    fi

    # Failed checks with classification
    if [[ "$failed" -gt 0 && -f "$analysis_file" ]]; then
      echo "### Failure Analysis"
      echo ""
      echo "| Job | Category | Flake% | Link |"
      echo "|-----|----------|--------|------|"

      jq -r '.[] | "| \(.job_name) | `\(.category)` | \(.flake_probability)% | [logs](\(.url)) |"' \
        "$analysis_file" 2>/dev/null || true
      echo ""

      # Infra flakes section
      local flake_count
      flake_count=$(jq '[.[] | select(.category == "infra-flake")] | length' "$analysis_file" 2>/dev/null || echo 0)
      if [[ "$flake_count" -gt 0 ]]; then
        echo "### Infrastructure Flakes (${flake_count})"
        echo ""
        echo "These failures appear to be infrastructure-related (timeouts, networking, quota) rather than code issues."
        echo "Consider retesting with \`/retest\` or \`/test <job-name>\`."
        echo ""
        jq -r '.[] | select(.category == "infra-flake") | "- **\(.job_name)** — flake rate: \(.flake_probability)%"' \
          "$analysis_file" 2>/dev/null || true
        echo ""
      fi

      # Actionable failures
      local actionable_count
      actionable_count=$(jq '[.[] | select(.category != "infra-flake")] | length' "$analysis_file" 2>/dev/null || echo 0)
      if [[ "$actionable_count" -gt 0 ]]; then
        echo "### Actionable Failures (${actionable_count})"
        echo ""

        # Group by category
        for cat in "build-failure" "lint-failure" "test-failure" "install-failure" "unknown"; do
          local cat_items
          cat_items=$(jq -r --arg c "$cat" '.[] | select(.category == $c) | .job_name' "$analysis_file" 2>/dev/null || true)
          if [[ -n "$cat_items" ]]; then
            echo "**${cat}:**"
            while IFS= read -r name; do
              echo "- ${name}"
            done <<< "$cat_items"
            echo ""
          fi
        done
      fi

      # Log snippets for actionable failures
      local has_snippets=false
      while IFS= read -r entry; do
        local snippet
        snippet=$(echo "$entry" | jq -r '.log_snippet')
        if [[ -n "$snippet" && "$snippet" != "null" ]]; then
          has_snippets=true
          break
        fi
      done < <(jq -c '.[] | select(.category != "infra-flake")' "$analysis_file" 2>/dev/null)

      if [[ "$has_snippets" == "true" ]]; then
        echo "<details>"
        echo "<summary>Log snippets for actionable failures</summary>"
        echo ""
        jq -c '.[] | select(.category != "infra-flake" and .log_snippet != "")' "$analysis_file" 2>/dev/null \
          | while IFS= read -r entry; do
              local name snippet
              name=$(echo "$entry" | jq -r '.job_name')
              snippet=$(echo "$entry" | jq -r '.log_snippet' | tr '|' '\n')
              echo "**${name}:**"
              echo '```'
              echo "$snippet"
              echo '```'
              echo ""
            done
        echo "</details>"
        echo ""
      fi
    fi

    # Passed checks (collapsed)
    if [[ "$passed" -gt 0 ]]; then
      echo "<details>"
      echo "<summary>Passed checks (${passed})</summary>"
      echo ""
      jq -r '.[] | select(.bucket == "pass") | "- \(.name)"' "$checks_file" 2>/dev/null || true
      echo ""
      echo "</details>"
      echo ""
    fi

    echo "---"
    echo "*Generated by oape-ci-monitor on $(date -u +'%Y-%m-%d %H:%M UTC') | classification: deterministic (regex-based)*"
  } > "$report_file"

  echo "[report] Report generated: ${report_file}"
}

# ===========================================================================
# Phase 6: Post report as PR comment (idempotent update)
# ===========================================================================
post_report_comment() {
  local report_file="${WORK_DIR}/report.md"

  if [[ ! -f "$report_file" ]]; then
    echo "[post] No report file found" >&2
    return 1
  fi

  local body
  body=$(cat "$report_file")

  if [[ "$DRY_RUN" == "true" ]]; then
    echo "[post] DRY RUN: Would post/update report on ${OWNER}/${REPO}#${PR_NUMBER}"
    echo "--- Report Preview ---"
    cat "$report_file"
    echo "--- End Preview ---"
    return 0
  fi

  local existing_comment_id
  existing_comment_id=$(gh api "repos/${OWNER}/${REPO}/issues/${PR_NUMBER}/comments" \
    --jq ".[] | select(.body | contains(\"${REPORT_MARKER}\")) | .id" 2>/dev/null | head -1 || true)

  if [[ -n "$existing_comment_id" ]]; then
    gh_retry gh api "repos/${OWNER}/${REPO}/issues/comments/${existing_comment_id}" \
      -X PATCH -f body="$body" > /dev/null 2>&1
    echo "[post] Updated existing CI monitor comment on ${OWNER}/${REPO}#${PR_NUMBER}"
  else
    gh_retry gh pr comment "$PR_NUMBER" --repo "${OWNER}/${REPO}" --body "$body" > /dev/null 2>&1
    echo "[post] Posted new CI monitor comment on ${OWNER}/${REPO}#${PR_NUMBER}"
  fi
}

# ===========================================================================
# Phase 7: Write machine-readable result JSON ("trigger on failure" hook)
# ===========================================================================
write_result_json() {
  local checks_file="${WORK_DIR}/ci-checks.json"
  local analysis_file="${WORK_DIR}/failure-analysis.json"

  local total passed failed pending
  total=$(jq 'length' "$checks_file")
  passed=$(jq '[.[] | select(.bucket == "pass")] | length' "$checks_file")
  failed=$(jq '[.[] | select(.bucket == "fail")] | length' "$checks_file")
  pending=$(jq '[.[] | select(.bucket == "pending")] | length' "$checks_file")

  local overall_status="passed"
  if [[ "$failed" -gt 0 ]]; then
    overall_status="failed"
  elif [[ "$pending" -gt 0 ]]; then
    overall_status="pending"
  fi

  local failures="[]"
  if [[ -f "$analysis_file" ]]; then
    failures=$(cat "$analysis_file")
  fi

  # Compute category counts
  local category_counts="{}"
  if [[ "$failures" != "[]" ]]; then
    category_counts=$(echo "$failures" | jq '
      group_by(.category)
      | map({key: .[0].category, value: length})
      | from_entries')
  fi

  jq -n \
    --arg pr_url "$PR_URL" \
    --arg owner "$OWNER" \
    --arg repo "$REPO" \
    --argjson pr_number "$PR_NUMBER" \
    --arg status "$overall_status" \
    --argjson total "$total" \
    --argjson passed "$passed" \
    --argjson failed "$failed" \
    --argjson pending "$pending" \
    --argjson failures "$failures" \
    --argjson categories "$category_counts" \
    --arg ts "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
    '{
      pr_url: $pr_url,
      owner: $owner,
      repo: $repo,
      pr_number: $pr_number,
      overall_status: $status,
      timestamp: $ts,
      checks: {
        total: $total,
        passed: $passed,
        failed: $failed,
        pending: $pending
      },
      failure_categories: $categories,
      failures: $failures,
      trigger_actions: (
        if $status == "failed" then
          ($failures | map(
            if .category == "infra-flake" then {action: "retest", job: .job_name}
            elif .category == "lint-failure" then {action: "auto-fix-lint", job: .job_name}
            elif .category == "build-failure" then {action: "investigate", job: .job_name}
            elif .category == "test-failure" then {action: "investigate", job: .job_name}
            elif .category == "install-failure" then {action: "retest", job: .job_name}
            else {action: "investigate", job: .job_name}
            end
          ))
        else []
        end
      )
    }' > "$RESULT_FILE"

  echo "[result] Machine-readable result written to ${RESULT_FILE}"

  # Log the trigger actions summary
  local trigger_count
  trigger_count=$(jq '.trigger_actions | length' "$RESULT_FILE")
  if [[ "$trigger_count" -gt 0 ]]; then
    echo "[result] Trigger actions suggested:"
    jq -r '.trigger_actions[] | "  - \(.action): \(.job)"' "$RESULT_FILE"
  fi
}

# ===========================================================================
# Main
# ===========================================================================
main() {
  echo "============================================"
  echo "  OAPE CI Monitor — Phase 1"
  echo "  PR: ${PR_URL}"
  echo "  Dry Run: ${DRY_RUN}"
  echo "  Skip Poll: ${SKIP_POLL}"
  echo "  Poll Interval: ${POLL_INTERVAL}s"
  echo "  Poll Timeout: ${POLL_TIMEOUT}s"
  echo "  Time: $(date -u +'%Y-%m-%d %H:%M UTC')"
  echo "============================================"

  parse_pr_url "$PR_URL"
  echo "[main] Monitoring ${OWNER}/${REPO}#${PR_NUMBER}"

  run_prechecks

  # Phase 1: Wait for CI checks to complete
  echo ""
  if [[ "$SKIP_POLL" == "true" ]]; then
    echo "=== Phase 1: Fetch CI Checks (poll skipped — event-triggered) ==="
    local checks_file_snap
    checks_file_snap=$(fetch_ci_checks)
    local snap_summary
    snap_summary=$(get_check_summary "$checks_file_snap")
    echo "[poll] CI status: ${snap_summary}"
  else
    echo "=== Phase 1: Poll CI Checks ==="
    poll_until_complete
  fi

  # Determine overall status
  local checks_file="${WORK_DIR}/ci-checks.json"
  local failed_count
  failed_count=$(jq '[.[] | select(.bucket == "fail")] | length' "$checks_file")

  if [[ "$failed_count" -eq 0 ]]; then
    echo ""
    echo "=== All CI checks passed — generating summary report ==="
    generate_report
    post_report_comment
    write_result_json
    echo ""
    echo "[main] CI monitor complete — all checks passed"
    exit 0
  fi

  # Phase 2: Collect failure artifacts
  echo ""
  echo "=== Phase 2: Collect Failure Artifacts ==="
  collect_failure_artifacts

  # Phase 3: Classify failures
  echo ""
  echo "=== Phase 3: Classify Failures ==="
  classify_all_failures

  # Phase 4: Sippy flake lookup
  echo ""
  echo "=== Phase 4: Sippy Flake History ==="
  query_sippy_flakes

  # Phase 5: Generate report
  echo ""
  echo "=== Phase 5: Generate Report ==="
  generate_report

  # Phase 6: Post to PR
  echo ""
  echo "=== Phase 6: Post Report ==="
  post_report_comment

  # Phase 7: Write machine-readable result
  echo ""
  echo "=== Phase 7: Write Result JSON ==="
  write_result_json

  echo ""
  echo "[main] CI monitor complete — ${failed_count} failure(s) analyzed"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main
fi
