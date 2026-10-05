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

# shellcheck disable=SC2034
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

# GitHub App credentials (mounted by Prow; optional locally)
GITHUB_APP_ID_FILE="${GITHUB_APP_ID_FILE:-/var/run/github-app/app-id}"
GITHUB_APP_KEY_FILE="${GITHUB_APP_KEY_FILE:-/var/run/github-app/private-key.pem}"
TOKEN_GENERATED_AT=0

# Release repo context (populated by fetch_release_context)
USE_RELEASE_CONTEXT="false"
RELEASE_VERSION=""

# Parsed from PR_URL
OWNER=""
REPO=""
PR_NUMBER=""

# Tracks the last non-zero total check count to detect transient API failures
LAST_KNOWN_TOTAL=0

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
# GitHub App token refresh (handles 1-hour TTL during long polls)
# ---------------------------------------------------------------------------
refresh_github_token() {
  if [[ ! -f "$GITHUB_APP_ID_FILE" || ! -f "$GITHUB_APP_KEY_FILE" ]]; then
    echo "[auth-refresh] GitHub App credentials not available — cannot refresh" >&2
    return 1
  fi

  local app_id pem_path header now exp payload signature jwt
  app_id=$(cat "$GITHUB_APP_ID_FILE")
  pem_path="$GITHUB_APP_KEY_FILE"

  header=$(printf '{"alg":"RS256","typ":"JWT"}' | openssl base64 -e -A | tr '+/' '-_' | tr -d '=')
  now=$(date +%s); exp=$((now + 300))
  payload=$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' "$now" "$exp" "$app_id" | openssl base64 -e -A | tr '+/' '-_' | tr -d '=')
  signature=$(printf '%s' "${header}.${payload}" | openssl dgst -sha256 -sign "$pem_path" -binary | openssl base64 -e -A | tr '+/' '-_' | tr -d '=')
  jwt="${header}.${payload}.${signature}"

  local install_response http_code install_body inst_id
  install_response=$(curl -s -w "\n%{http_code}" \
    -H "Authorization: Bearer ${jwt}" -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/${OWNER}/${REPO}/installation")
  http_code=$(echo "$install_response" | tail -1)
  install_body=$(echo "$install_response" | sed '$d')

  if [[ "$http_code" -ne 200 ]]; then
    echo "[auth-refresh] App not installed on ${OWNER}/${REPO} (HTTP ${http_code})" >&2
    return 1
  fi

  inst_id=$(echo "$install_body" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")

  local token_response t_code t_body
  token_response=$(curl -s -w "\n%{http_code}" -X POST \
    -H "Authorization: Bearer ${jwt}" -H "Accept: application/vnd.github+json" \
    "https://api.github.com/app/installations/${inst_id}/access_tokens")
  t_code=$(echo "$token_response" | tail -1)
  t_body=$(echo "$token_response" | sed '$d')

  if [[ "$t_code" -ne 201 ]]; then
    echo "[auth-refresh] Token creation failed (HTTP ${t_code})" >&2
    return 1
  fi

  export GH_TOKEN
  GH_TOKEN=$(echo "$t_body" | python3 -c "import sys,json; print(json.load(sys.stdin)['token'])")
  TOKEN_GENERATED_AT=$(date +%s)
  echo "[auth-refresh] Token refreshed successfully"
}

# Proactively refresh if the token is older than 50 minutes (3000s)
maybe_refresh_token() {
  if [[ "$TOKEN_GENERATED_AT" -eq 0 ]]; then
    return 0
  fi
  local age=$(( $(date +%s) - TOKEN_GENERATED_AT ))
  if [[ "$age" -ge 3000 ]]; then
    echo "[auth-refresh] Token age ${age}s (>3000s) — refreshing proactively"
    refresh_github_token || echo "[auth-refresh] WARN: proactive refresh failed, will retry on next API error"
  fi
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
# Phase 0: Fetch release repo context (ci-operator config from openshift/release)
# ===========================================================================
fetch_release_context() {
  echo "[release-ctx] Fetching ci-operator config for ${OWNER}/${REPO}..."

  local base_branch
  base_branch=$(gh pr view "$PR_NUMBER" --repo "${OWNER}/${REPO}" \
    --json baseRefName --jq '.baseRefName' 2>/dev/null || echo "")

  if [[ -z "$base_branch" ]]; then
    echo "[release-ctx] Could not determine base branch, skipping release context"
    return 0
  fi

  local config_base="https://raw.githubusercontent.com/openshift/release/master/ci-operator/config/${OWNER}/${REPO}"
  local config_file="${OWNER}-${REPO}-${base_branch}.yaml"
  local local_config="${WORK_DIR}/ci-operator-config.yaml"

  if ! curl -sf --max-time 15 "${config_base}/${config_file}" -o "$local_config" 2>/dev/null; then
    config_file="${OWNER}-${REPO}-master.yaml"
    if ! curl -sf --max-time 15 "${config_base}/${config_file}" -o "$local_config" 2>/dev/null; then
      echo "[release-ctx] No ci-operator config found for ${OWNER}/${REPO}. Using name-based classification."
      return 0
    fi
  fi

  if [[ ! -s "$local_config" ]]; then
    echo "[release-ctx] Config file empty, skipping"
    return 0
  fi

  USE_RELEASE_CONTEXT="true"
  echo "[release-ctx] Config fetched: ${config_file}"

  # Extract OCP release version for Sippy queries
  # Try releases.latest.release.version, then releases.latest.integration.name
  if command -v python3 &>/dev/null; then
    RELEASE_VERSION=$(python3 -c "
import yaml, sys
try:
    cfg = yaml.safe_load(open('$local_config'))
    rels = cfg.get('releases', {}).get('latest', {})
    ver = rels.get('release', {}).get('version', '')
    if not ver:
        ver = rels.get('integration', {}).get('name', '')
    print(ver)
except:
    print('')
" 2>/dev/null || echo "")
  fi

  if [[ -n "$RELEASE_VERSION" ]]; then
    echo "[release-ctx] OCP release version: ${RELEASE_VERSION}"
  fi

  # Build job manifest: tests[].as -> {optional, cluster_profile}
  if command -v python3 &>/dev/null; then
    python3 -c "
import yaml, json, sys
try:
    cfg = yaml.safe_load(open('$local_config'))
    manifest = {}
    for test in cfg.get('tests', []):
        name = test.get('as', '')
        if not name:
            continue
        entry = {
            'optional': test.get('optional', False),
            'always_run': test.get('always_run', True),
            'cluster_profile': '',
        }
        steps = test.get('steps', {})
        if isinstance(steps, dict):
            entry['cluster_profile'] = steps.get('cluster_profile', '')
        manifest[name] = entry
    json.dump(manifest, open('${WORK_DIR}/job-manifest.json', 'w'), indent=2)
    print(f'[release-ctx] Job manifest: {len(manifest)} jobs parsed')
except Exception as e:
    print(f'[release-ctx] Warning: could not parse job manifest: {e}', file=sys.stderr)
    json.dump({}, open('${WORK_DIR}/job-manifest.json', 'w'))
" 2>/dev/null || echo '{}' > "${WORK_DIR}/job-manifest.json"
  else
    echo '{}' > "${WORK_DIR}/job-manifest.json"
    echo "[release-ctx] python3 not available, skipping YAML parsing"
  fi
}

# ===========================================================================
# Phase 1: Poll CI checks until all complete (or timeout)
# ===========================================================================
fetch_ci_checks() {
  local output_file="${WORK_DIR}/ci-checks.json"

  maybe_refresh_token

  if ! gh_retry gh pr checks "$PR_NUMBER" --repo "${OWNER}/${REPO}" \
    --json name,state,link,bucket \
    > "$output_file" 2>/dev/null; then
    echo "[fetch] gh pr checks failed — attempting token refresh" >&2
    if refresh_github_token 2>/dev/null; then
      if ! gh_retry gh pr checks "$PR_NUMBER" --repo "${OWNER}/${REPO}" \
        --json name,state,link,bucket \
        > "$output_file" 2>/dev/null; then
        echo "[]" > "$output_file"
      fi
    else
      echo "[]" > "$output_file"
    fi
  fi

  # Filter out self and non-CI contexts (merge gates, review bots, etc.)
  local filtered
  filtered=$(jq --arg self "$SELF_JOB_NAME" \
    '[.[] | select(
      .name != $self
      and (.name | contains($self) | not)
      and (.name | test("^(tide|Mergeable|DCO|CodeRabbit|stale|sonarcloud|codecov)"; "i") | not)
    )]' \
    "$output_file")
  echo "$filtered" > "$output_file"

  # Guard: if the result is empty but we previously had checks, this is
  # likely a transient API failure (e.g. token expiry). Keep the last known
  # good state to avoid false "all passed" conclusions.
  local current_total
  current_total=$(jq 'length' "$output_file")
  if [[ "$current_total" -eq 0 && "$LAST_KNOWN_TOTAL" -gt 0 ]]; then
    echo "[fetch] WARN: Got 0 checks but previously had ${LAST_KNOWN_TOTAL} — treating as transient failure" >&2
    # Restore the previous checks file so the poll loop doesn't treat this as "complete"
    if [[ -f "${WORK_DIR}/ci-checks-last-good.json" ]]; then
      cp "${WORK_DIR}/ci-checks-last-good.json" "$output_file"
    fi
  elif [[ "$current_total" -gt 0 ]]; then
    LAST_KNOWN_TOTAL="$current_total"
    cp "$output_file" "${WORK_DIR}/ci-checks-last-good.json"
  fi

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
  local log_file
  log_file="${WORK_DIR}/log-$(echo "$job_name" | tr '/ ' '__').txt"

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
  if echo "$content" | grep -qiE 'failed to install|cluster installation failed|install.*timed out|waiting for bootstrap|failed to create cluster|level=fatal.*installer|cluster creation failed|bootstrap.*timed out|waiting for bootstrapComplete'; then
    echo "install-failure"
  # Build / compile failures
  elif echo "$content" | grep -qiE 'cannot compile|undefined:|syntax error|cannot use.*as.*in|build.*failed|compilation error|cannot find package|imported and not used'; then
    echo "build-failure"
  # Generated files out of date (check before lint — generated-files errors
  # often co-occur with lint markers but need a different fix command)
  elif echo "$content" | grep -qiE 'generated code is out of date|make generate|make manifests|deepcopy-gen|zz_generated'; then
    echo "generated-files-failure"
  # Lint / formatting / boilerplate failures
  elif echo "$content" | grep -qiE 'gofmt|goimports|formatting differs|golangci-lint|golint|staticcheck|revive|lint.*failed|boilerplate'; then
    echo "lint-failure"
  # Test failures
  elif echo "$content" | grep -qiE '--- FAIL|FAIL\s|panic:.*test|assertion failed|test.*failed'; then
    echo "test-failure"
  # Infrastructure / transient flakes
  elif echo "$content" | grep -qiE 'context deadline exceeded|connection refused|i/o timeout|ErrImagePull|ImagePullBackOff|pod sandbox|TLS handshake timeout|quota.*exceeded|unable to provision|registry\.ci\.openshift\.org.*(timeout|error)|etcdserver: request timed out|lease lost|error creating.*instance|InsufficientInstanceCapacity|unable to get lease|failed to acquire lease|dial tcp.*timeout'; then
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
resolve_release_version() {
  local job_name="${1:-}"

  # 1. From ci-operator config (set by fetch_release_context)
  if [[ -n "$RELEASE_VERSION" ]]; then
    echo "$RELEASE_VERSION"
    return
  fi

  # 2. From Prow job name pattern (e.g., "4.18" from "pull-ci-...-4.18-e2e-aws")
  if [[ -n "$job_name" ]]; then
    local version
    version=$(echo "$job_name" | grep -oP '\d+\.\d+' | head -1 || true)
    if [[ -n "$version" ]]; then
      echo "$version"
      return
    fi
  fi

  echo ""
}

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

  local resolved_release
  resolved_release=$(resolve_release_version "")
  if [[ -n "$resolved_release" ]]; then
    echo "[sippy] Using OCP release version: ${resolved_release}"
  else
    echo "[sippy] No release version resolved, queries may return incomplete data"
  fi

  echo "[sippy] Querying Sippy for flake history..."

  while IFS= read -r job_name; do
    [[ -z "$job_name" ]] && continue

    local release_for_job
    release_for_job="${resolved_release:-$(resolve_release_version "$job_name")}"
    local sippy_url
    if [[ -n "$release_for_job" ]]; then
      sippy_url="${SIPPY_API_URL}/api/tests?release=${release_for_job}&filter.test_name=${job_name}"
    else
      sippy_url="${SIPPY_API_URL}/api/jobs/flakes?job=${job_name}"
    fi
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
      if jq -e --argjson pct "$flake_pct" -n '$pct > 30' &>/dev/null; then
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
# Phase 4b: Fetch PR change context (lazy — only when failures exist)
# ===========================================================================
fetch_pr_change_context() {
  local context_file="${WORK_DIR}/pr-change-context.json"

  echo "[change-ctx] Fetching changed files for ${OWNER}/${REPO}#${PR_NUMBER}..."

  local changed_files
  changed_files=$(gh pr view "$PR_NUMBER" --repo "${OWNER}/${REPO}" \
    --json files --jq '.files[].path' 2>/dev/null || true)

  if [[ -z "$changed_files" ]]; then
    echo "[change-ctx] Could not fetch changed files"
    echo '{"api":0,"controller":0,"test":0,"crd":0,"rbac":0,"other":0,"files":[]}' > "$context_file"
    return 0
  fi

  local api=0 controller=0 test=0 crd=0 rbac=0 other=0
  local files_json="[]"

  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    files_json=$(echo "$files_json" | jq --arg f "$f" '. + [$f]')
    case "$f" in
      *_types.go|*types_*.go|*/api/*)            api=$((api + 1)) ;;
      *controller*|*reconcil*|*sync*.go)          controller=$((controller + 1)) ;;
      *_test.go|*_test.sh)                        test=$((test + 1)) ;;
      *crd*.yaml|*crd*.json)                      crd=$((crd + 1)) ;;
      *rbac*.yaml|*clusterrole*.yaml)             rbac=$((rbac + 1)) ;;
      *)                                          other=$((other + 1)) ;;
    esac
  done <<< "$changed_files"

  jq -n \
    --argjson api "$api" \
    --argjson controller "$controller" \
    --argjson test "$test" \
    --argjson crd "$crd" \
    --argjson rbac "$rbac" \
    --argjson other "$other" \
    --argjson files "$files_json" \
    '{api:$api, controller:$controller, test:$test, crd:$crd, rbac:$rbac, other:$other, files:$files}' \
    > "$context_file"

  local total_files
  total_files=$(echo "$files_json" | jq 'length')
  echo "[change-ctx] PR changes: ${total_files} files (api:${api} controller:${controller} test:${test} crd:${crd} rbac:${rbac} other:${other})"
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
    if [[ "$USE_RELEASE_CONTEXT" == "true" ]]; then
      echo "**Release Context:** available | OCP version: ${RELEASE_VERSION:-unknown}"
    fi

    # PR change summary
    local context_file="${WORK_DIR}/pr-change-context.json"
    if [[ -f "$context_file" ]]; then
      local ctx_total
      ctx_total=$(jq '[.api,.controller,.test,.crd,.rbac,.other] | add' "$context_file" 2>/dev/null || echo 0)
      if [[ "$ctx_total" -gt 0 ]]; then
        local ctx_api ctx_ctrl ctx_test ctx_crd ctx_rbac ctx_other
        ctx_api=$(jq '.api' "$context_file")
        ctx_ctrl=$(jq '.controller' "$context_file")
        ctx_test=$(jq '.test' "$context_file")
        ctx_crd=$(jq '.crd' "$context_file")
        ctx_rbac=$(jq '.rbac' "$context_file")
        ctx_other=$(jq '.other' "$context_file")
        local parts=()
        [[ "$ctx_api" -gt 0 ]] && parts+=("${ctx_api} API")
        [[ "$ctx_ctrl" -gt 0 ]] && parts+=("${ctx_ctrl} controller")
        [[ "$ctx_test" -gt 0 ]] && parts+=("${ctx_test} test")
        [[ "$ctx_crd" -gt 0 ]] && parts+=("${ctx_crd} CRD")
        [[ "$ctx_rbac" -gt 0 ]] && parts+=("${ctx_rbac} RBAC")
        [[ "$ctx_other" -gt 0 ]] && parts+=("${ctx_other} other")
        local parts_str
        parts_str=$(IFS=', '; echo "${parts[*]}")
        echo "**PR changes:** ${ctx_total} files (${parts_str})"
      fi
    fi
    echo ""

    # Overall status — check optional-only failures
    local optional_failures=0
    local required_failures_count=0
    if [[ -f "$analysis_file" && "$failed" -gt 0 ]]; then
      local job_manifest="${WORK_DIR}/job-manifest.json"
      if [[ "$USE_RELEASE_CONTEXT" == "true" && -f "$job_manifest" ]]; then
        while IFS= read -r jn; do
          local short
          # shellcheck disable=SC2001
          short=$(echo "$jn" | sed "s/^pull-ci-${OWNER}-${REPO}-[^-]*-//")
          local is_opt
          is_opt=$(jq -r --arg n "$short" '.[$n].optional // false' "$job_manifest" 2>/dev/null || echo "false")
          if [[ "$is_opt" == "true" ]]; then
            optional_failures=$((optional_failures + 1))
          else
            required_failures_count=$((required_failures_count + 1))
          fi
        done < <(jq -r '.[] | .job_name' "$analysis_file" 2>/dev/null)
      fi
    fi

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
        for cat in "build-failure" "lint-failure" "generated-files-failure" "test-failure" "install-failure" "unknown"; do
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

    # Prow Job Breakdown table (all checks, not just failures)
    echo "### Prow Job Breakdown"
    echo ""
    echo "| Job | State | Category | Required | Flake% | Action |"
    echo "|-----|-------|----------|----------|--------|--------|"

    local job_manifest="${WORK_DIR}/job-manifest.json"

    jq -r '.[] | "\(.name)\t\(.bucket)\t\(.link)"' "$checks_file" 2>/dev/null \
      | while IFS=$'\t' read -r jb_name jb_bucket _jb_link; do
          [[ -z "$jb_name" ]] && continue
          local jb_category="--" jb_required="--" jb_flake="--" jb_action="--"

          # For failed jobs, look up category and flake% from analysis
          if [[ "$jb_bucket" == "fail" && -f "$analysis_file" ]]; then
            jb_category=$(jq -r --arg n "$jb_name" '.[] | select(.job_name == $n) | .category // "--"' "$analysis_file" 2>/dev/null || echo "--")
            local fp
            fp=$(jq -r --arg n "$jb_name" '.[] | select(.job_name == $n) | .flake_probability // 0' "$analysis_file" 2>/dev/null || echo "0")
            if [[ "$fp" != "0" && "$fp" != "null" ]]; then
              jb_flake="${fp}%"
            fi
            # Derive action from category
            case "$jb_category" in
              infra-flake)              jb_action="/retest" ;;
              lint-failure)             jb_action="auto-fix-lint" ;;
              generated-files-failure)  jb_action="auto-fix-generated" ;;
              build-failure|test-failure|install-failure) jb_action="investigate" ;;
              unknown)                  jb_action="investigate" ;;
            esac
          fi

          # Look up required/optional from job manifest
          if [[ "$USE_RELEASE_CONTEXT" == "true" && -f "$job_manifest" ]]; then
            local short_name
            # Pattern includes variable interpolation not supported by ${//}
            # shellcheck disable=SC2001
            short_name=$(echo "$jb_name" | sed "s/^pull-ci-${OWNER}-${REPO}-[^-]*-//")
            local is_optional
            is_optional=$(jq -r --arg n "$short_name" '.[$n].optional // false' "$job_manifest" 2>/dev/null || echo "false")
            if [[ "$is_optional" == "true" ]]; then
              jb_required="no (optional)"
            else
              jb_required="yes"
            fi
          fi

          echo "| ${jb_name} | ${jb_bucket} | \`${jb_category}\` | ${jb_required} | ${jb_flake} | ${jb_action} |"
        done
    echo ""

    echo "---"
    echo "*Generated by oape-ci-monitor on $(date -u +'%Y-%m-%d %H:%M UTC') | classification: deterministic (regex-based) | release context: ${USE_RELEASE_CONTEXT}*"
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
    if gh_retry gh api "repos/${OWNER}/${REPO}/issues/comments/${existing_comment_id}" \
      -X PATCH -f body="$body" > /dev/null 2>&1; then
      echo "[post] Updated existing CI monitor comment on ${OWNER}/${REPO}#${PR_NUMBER}"
    else
      echo "[post] WARN: Failed to update comment — attempting token refresh" >&2
      if refresh_github_token 2>/dev/null; then
        gh_retry gh api "repos/${OWNER}/${REPO}/issues/comments/${existing_comment_id}" \
          -X PATCH -f body="$body" > /dev/null 2>&1 || echo "[post] WARN: Update still failed after refresh" >&2
      fi
    fi
  else
    if gh_retry gh pr comment "$PR_NUMBER" --repo "${OWNER}/${REPO}" --body "$body" > /dev/null 2>&1; then
      echo "[post] Posted new CI monitor comment on ${OWNER}/${REPO}#${PR_NUMBER}"
    else
      echo "[post] WARN: Failed to post comment — attempting token refresh" >&2
      if refresh_github_token 2>/dev/null; then
        gh_retry gh pr comment "$PR_NUMBER" --repo "${OWNER}/${REPO}" --body "$body" > /dev/null 2>&1 || echo "[post] WARN: Post still failed after refresh" >&2
      fi
    fi
  fi
}

# ===========================================================================
# Phase 7: Write machine-readable result JSON ("trigger on failure" hook)
# ===========================================================================
write_result_json() {
  local checks_file="${WORK_DIR}/ci-checks.json"
  local analysis_file="${WORK_DIR}/failure-analysis.json"
  local job_manifest="${WORK_DIR}/job-manifest.json"

  local total passed failed pending
  total=$(jq 'length' "$checks_file")
  passed=$(jq '[.[] | select(.bucket == "pass")] | length' "$checks_file")
  failed=$(jq '[.[] | select(.bucket == "fail")] | length' "$checks_file")
  pending=$(jq '[.[] | select(.bucket == "pending")] | length' "$checks_file")

  local failures="[]"
  if [[ -f "$analysis_file" ]]; then
    failures=$(cat "$analysis_file")
  fi

  # Enrich each failure with optional metadata from the job manifest
  if [[ "$USE_RELEASE_CONTEXT" == "true" && -f "$job_manifest" ]]; then
    failures=$(echo "$failures" | jq --slurpfile manifest "$job_manifest" \
      --arg owner "$OWNER" --arg repo "$REPO" '
      map(
        . as $f |
        ($f.job_name | gsub("^pull-ci-" + $owner + "-" + $repo + "-[^-]+-"; "")) as $short |
        ($manifest[0][$short].optional // false) as $opt |
        . + {optional: $opt}
      )')
  else
    failures=$(echo "$failures" | jq 'map(. + {optional: false})')
  fi

  # Determine overall status — optional-only failures do not flip verdict
  local overall_status="passed"
  local required_failures
  required_failures=$(echo "$failures" | jq '[.[] | select(.optional != true)] | length')
  if [[ "$required_failures" -gt 0 ]]; then
    overall_status="failed"
  elif [[ "$failed" -gt 0 ]]; then
    # All failures are optional
    overall_status="passed-with-optional-failures"
  fi
  if [[ "$pending" -gt 0 && "$overall_status" != "failed" ]]; then
    overall_status="pending"
  fi

  # Compute category counts
  local category_counts="{}"
  if [[ "$failures" != "[]" ]]; then
    category_counts=$(echo "$failures" | jq '
      group_by(.category)
      | map({key: .[0].category, value: length})
      | from_entries')
  fi

  # Include PR change context if available
  local change_context="{}"
  if [[ -f "${WORK_DIR}/pr-change-context.json" ]]; then
    change_context=$(cat "${WORK_DIR}/pr-change-context.json")
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
    --argjson change_context "$change_context" \
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
      pr_change_context: $change_context,
      failures: $failures,
      trigger_actions: (
        if ($status == "failed" or $status == "passed-with-optional-failures") then
          ($failures | map(
            if .category == "infra-flake" then {action: "retest", job: .job_name, optional: .optional}
            elif .category == "lint-failure" then {action: "auto-fix-lint", job: .job_name, optional: .optional}
            elif .category == "generated-files-failure" then {action: "auto-fix-generated", job: .job_name, optional: .optional}
            elif .category == "build-failure" then {action: "investigate", job: .job_name, optional: .optional}
            elif .category == "test-failure" then {action: "investigate", job: .job_name, optional: .optional}
            elif .category == "install-failure" then {action: "retest", job: .job_name, optional: .optional}
            else {action: "investigate", job: .job_name, optional: .optional}
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
    jq -r '.trigger_actions[] | "  - \(.action): \(.job) (optional: \(.optional))"' "$RESULT_FILE"
  fi

  if [[ "$overall_status" == "passed-with-optional-failures" ]]; then
    echo "[result] Note: all failures are optional — PR verdict is PASS"
  fi
}

# ===========================================================================
# Main
# ===========================================================================
main() {
  echo "============================================"
  echo "  OAPE CI Monitor — Phase 2"
  echo "  PR: ${PR_URL}"
  echo "  Dry Run: ${DRY_RUN}"
  echo "  Skip Poll: ${SKIP_POLL}"
  echo "  Poll Interval: ${POLL_INTERVAL}s"
  echo "  Poll Timeout: ${POLL_TIMEOUT}s"
  echo "  Time: $(date -u +'%Y-%m-%d %H:%M UTC')"
  echo "============================================"

  parse_pr_url "$PR_URL"
  echo "[main] Monitoring ${OWNER}/${REPO}#${PR_NUMBER}"

  # Record when the initial token was created (set by the entrypoint)
  if [[ -n "${GH_TOKEN:-}" && "$TOKEN_GENERATED_AT" -eq 0 ]]; then
    TOKEN_GENERATED_AT=$(date +%s)
  fi

  run_prechecks

  # Phase 0: Fetch release repo context
  echo ""
  echo "=== Phase 0: Fetch Release Repo Context ==="
  fetch_release_context

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

  local total_count
  total_count=$(jq 'length' "$checks_file")

  local pending_count
  pending_count=$(jq '[.[] | select(.bucket == "pending")] | length' "$checks_file")

  if [[ "$failed_count" -eq 0 && "$total_count" -gt 0 && "$pending_count" -eq 0 ]]; then
    echo ""
    echo "=== All CI checks passed — generating summary report ==="
    generate_report
    post_report_comment
    write_result_json
    echo ""
    echo "[main] CI monitor complete — all checks passed"
    exit 0
  elif [[ "$failed_count" -eq 0 && "$pending_count" -gt 0 ]]; then
    echo ""
    echo "=== No failures yet — ${pending_count} check(s) still pending ==="
    generate_report
    post_report_comment
    write_result_json
    echo ""
    echo "[main] CI monitor complete — ${pending_count} check(s) still pending"
    exit 0
  elif [[ "$total_count" -eq 0 ]]; then
    echo ""
    echo "[main] ERROR: No CI checks found — possible API failure or token expiry" >&2
    echo "[main] This should not happen. The poll loop guards against empty results."
    exit 1
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

  # Phase 4b: PR change context (lazy — only after classification)
  echo ""
  echo "=== Phase 4b: PR Change Context ==="
  fetch_pr_change_context

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
