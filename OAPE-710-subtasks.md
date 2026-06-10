# PR Lifecycle Agent — Subtasks

**Parent Ticket:** [OAPE-710](https://redhat.atlassian.net/browse/OAPE-710)
**Type:** Story
**Status:** To Do
**Assignee:** Neha Kumari

> **Phase 1 Scope Change (2026-06-10):** Phase 1 is a **GitHub Actions CI monitor** added directly to each target repo. The workflow triggers on GitHub `status` events (fired by Prow on every job completion). Each trigger checks whether all CI checks are done — if not, it exits in seconds with no idle polling. Once all checks are terminal, it clones oape-ai-e2e and runs the analysis scripts to classify failures, query Sippy for flake history, and post a structured report as a PR comment. Phase 1 is **report-only**: no auto-fix, no review comment handling, no Claude dependency. The report includes a machine-readable JSON output with suggested trigger actions for future phases. No container images or Prow configuration required — just a `.yml` workflow file in the target repo.

## Motivation & Goals

### The Problem

OAPE automates the code-generation half of the feature development lifecycle — from Enhancement Proposal to API types, tests, and controller implementation. But once a PR is opened, the journey from **"PR created" to "PR merged" is entirely manual**. Developers are left to monitor CI checks, dig through Prow and GitHub Actions logs, fix trivial lint and formatting failures, parse noisy bot comments, track reviewer feedback, and push fixes — all by hand.

This manual loop is both time-consuming and mechanical. Each CI round-trip (fail → read logs → fix → push → wait for CI) takes 15–30 minutes. Trivial failures — formatting, import ordering, missing generated files — account for a large share of CI failures on OAPE-generated code, yet each one requires the same checkout-fix-verify-push cycle. Across multiple PRs and repos, this adds up to hours of wasted developer time per week.

The PR agent closes this gap by automating the post-PR lifecycle as a **GitHub Actions CI job**: CI monitoring, failure triage, trivial auto-fixing, review comment addressing, and status reporting — all running autonomously on a schedule or on-demand.

### Why GitHub Actions (Not K8s Jobs)

The existing OAPE execution model uses K8s Jobs via the go-server for code generation workloads. The PR agent uses GitHub Actions instead because:

- **Native GitHub event triggers**: GHA natively supports `check_run`, `status`, `workflow_dispatch`, and `repository_dispatch` events — no webhook infrastructure or always-on server required
- **Ephemeral runners**: No cluster maintenance or pod scheduling overhead; GitHub-hosted runners are provisioned on demand
- **Proven pattern**: HyperShift's AI-assisted CI jobs (the reference architecture) use GHA successfully at scale
- **Built-in audit trail**: GHA artifacts provide configurable-retention storage for audit logs and reports
- **Concurrency control**: GHA `concurrency` groups natively prevent duplicate processing of the same PR
- The go-server/K8s Job model is optimized for long-running code generation workloads that need specific tools and cluster access — the PR agent's short-lived, event-driven CI monitoring pattern is a better fit for GHA

Human Review Required

> **AI-generated code must not be relied upon without human review.** All fixes pushed by these jobs must go through the standard GitHub PR review process. Repository OWNERS are responsible for reviewing and approving all changes.

### Before & After Workflow

```
BEFORE (manual):
  Developer opens PR
    → Polls `gh pr checks` repeatedly
    → Reads CI logs (Prow/GCS, GitHub Actions)
    → Identifies failure: "oh, it's just goimports"
    → Checks out branch, runs goimports, verifies build
    → Commits, pushes, waits 20 min for CI
    → Repeats for next failure
    → Reads 15 review comments, 10 are bots
    → Identifies 2 actionable items
    → Fixes, pushes again
  Total: 2–4 hours of mechanical work

AFTER (with webhook-driven + periodic-pr-agent):
  Developer opens PR
    → CI runs and fails
    → target repo trigger workflow detects failure via check_run/status event
    → dispatches to on-demand-pr-agent via repository_dispatch
    → Agent auto-fixes trivial CI failures (fmt, imports, generated files)
    → Agent verifies fix compiles, commits, pushes
    → Agent addresses actionable review comments via Claude Code
    → Agent posts status report as PR comment
    → periodic-pr-agent sweeps hourly as a fallback
    → Developer focuses on substantive feedback only
  Total: Developer spends ~30 min on items that actually need human judgment
```

### Pain Points & Solutions


| Pain Point                                 | Impact                         | PR Agent Solution                                                                              |
| ------------------------------------------ | ------------------------------ | ---------------------------------------------------------------------------------------------- |
| Repeated manual CI polling                 | Context switching, wasted time | Webhook-driven triggers react instantly to CI failures; periodic job sweeps hourly as fallback |
| Fixing lint/format/generated-file failures | 15–30 min per round-trip       | Auto-fix engine applies `go fmt`, `goimports`, `make generate`                                 |
| Parsing noisy bot comments                 | Signal buried in noise         | Categorizes comments, filters bots, surfaces actionable items only                             |
| Waiting between CI re-runs                 | Hours of idle-but-blocked time | Agent pushes fixes immediately, compresses feedback loop                                       |
| Uncertainty about PR readiness             | "What still needs to happen?"  | Structured status report posted as PR comment                                                  |


### Capabilities at a Glance


| Capability              | Description                                                                                                                                                                                            |
| ----------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| CI Monitoring           | Fetches all CI checks (GitHub Actions + Prow), categorizes status as passed/failed/pending                                                                                                             |
| Failure Analysis        | Classifies failures as trivial (auto-fixable) vs. non-trivial (requires human attention) via Claude Code                                                                                               |
| Auto-Fix Engine         | Runs the correct fix command, verifies compilation, commits and pushes                                                                                                                                 |
| Review Comment Handling | Analyzes unresolved review threads, addresses actionable feedback via Claude Code                                                                                                                      |
| Three Trigger Modes     | Target repo trigger workflows (instant CI failure reaction via `check_run`/`status` → `repository_dispatch`) + periodic scanner (cron fallback, all OAPE PRs) + on-demand per-PR (`workflow_dispatch`) |
| Safety Guardrails       | File blocklists, commit limits, audit logging, dry-run mode                                                                                                                                            |
| Status Reporting        | Markdown report posted as PR comment + uploaded as GHA artifact                                                                                                                                        |


### Prior Art: HyperShift AI-Assisted CI Jobs

This feature follows the pattern established by [HyperShift's AI-assisted CI jobs](https://hypershift.pages.dev/how-to/ci/ai-assisted-ci-jobs/), which use GitHub Actions workflows powered by Claude Code to automate Jira issue resolution, PR review comment handling, and dependabot triage. The PR Lifecycle Agent adapts this pattern for code-generation workflows, where failure patterns are more predictable (missing schemes, RBAC consistency, generated file sync).

Key design parallels with HyperShift:


| Aspect            | HyperShift                              | OAPE PR Agent                                                                                      |
| ----------------- | --------------------------------------- | -------------------------------------------------------------------------------------------------- |
| CI platform       | GitHub Actions                          | GitHub Actions                                                                                     |
| AI engine         | Claude Code CLI via Vertex AI           | Claude Code CLI via Vertex AI                                                                      |
| Periodic scanner  | `periodic-review-agent` (every 3h)      | `periodic-pr-agent` (every 1h, weekdays)                                                           |
| On-demand trigger | `/test address-review-comments`         | Target repo trigger (`check_run`/`status` failure → `repository_dispatch`), or `workflow_dispatch` |
| PR scope          | `app/hypershift-jira-solve-ci` PRs only | All open PRs in allowed repos (`team-repos.csv`)                                                   |
| Max items per run | 10 PRs (review agent)                   | 4 PRs (configurable via `PR_AGENT_MAX_PRS`)                                                        |
| Max budget per PR | $5.00 per PR                            | $5.00 per PR (configurable via `MAX_BUDGET_PER_PR`, passed to `--max-budget-usd`)                  |
| Safety            | Draft PRs only, human review required   | File blocklists, commit limits, audit log                                                          |


### Expected Outcome

Once the PR Lifecycle Agent is complete, all open PRs in allowed repos (`team-repos.csv`) will be automatically monitored via lightweight trigger workflows installed in target repos (instant reaction to CI failures via `check_run`/`status` events dispatched to `oape-ai-e2e`) backed by a periodic GitHub Actions sweeper. The agent will fix trivial CI failures, address review comments, and post status reports — all without developer intervention. Developers can also trigger the agent on-demand for any specific PR. The measurable goal is to **eliminate manual trivial-fix round-trips** and reduce time from PR-opened to CI-green from hours to minutes for the common case.

---

## Subtask Overview

This document breaks the PR Lifecycle Agent into 10 implementable subtasks. Each subtask is self-contained with a clear definition, acceptance criteria, dependencies, and implementation hints. The architecture follows a **hybrid model**: deterministic bash for mechanical orchestration (PR discovery, CI polling, tool setup, safety guardrails) and Claude Code CLI for intelligent analysis (failure classification, review comment handling, complex code fixes).

### Dependency Graph

```
Subtask 0 (GHA Infrastructure + Target Repo Triggers)
├── Subtask 1 (Entrypoint + PR Discovery + State Tracking)
│   ├── Subtask 2 (CI Monitoring)
│   │   └── Subtask 3 (Log Analysis + Deterministic Classification)
│   ├── Subtask 7 (Safety Guardrails) ← no dependencies (standalone utility)
│   │   └── Subtask 4 (Auto-Fix) ← depends on 3 + 7
│   ├── Subtask 5 (Review Comments)
│   ├── Subtask 6 (Wire Processing Pipeline) ← depends on 2–5, 7–8
│   │   Subtask 8 (Status Reporting) ← depends on 2–7
│   │   Subtask 9 (Testing) ← depends on all above
│   └── Subtask 10 (/oape:pr-agent Command) ← depends on 1–8
```

> **Note:** Subtask 7 (Safety Guardrails) is a standalone utility module with no dependencies
> on other subtasks. It provides blocklist, commit limit, audit log, and retry helper functions
> consumed by Subtasks 1, 2, 4, 5, and 6. Pipeline scripts (ci-monitor, auto-fix, review-handler,
> report) are standalone executables communicating via JSON files in `$RUNNER_TEMP`.
> `safety.sh` is a **sourced utility library** (`source scripts/pr-agent/safety.sh`) providing
> shared functions to all scripts that need them.

### Responsibility Split


| Layer                   | Responsibility                                                                                                                                                                                                                                                                                                                                    | Implementation                                                                            |
| ----------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------- |
| **GitHub Actions YAML** | Workflow triggers (including target repo triggers), runner setup, tool installation, job orchestration                                                                                                                                                                                                                                            | `.github/workflows/*.yml`                                                                 |
| **Bash scripts**        | PR discovery, CI status polling, deterministic failure classification, safety guardrails, audit logging, reporting. Pipeline scripts are **standalone executables** communicating via JSON files in `$RUNNER_TEMP`. `safety.sh` is a **sourced utility library** providing shared functions (blocklist, audit log, retry helper, commit counter). | `scripts/pr-agent/*.sh`                                                                   |
| **Claude Code CLI**     | Fallback failure classification (for `unknown` categories), review comment analysis/response, complex code fixes. Skills included via `cat` in the prompt.                                                                                                                                                                                        | `plugins/oape/skills/*.md` content injected via `claude --print -p "$(cat SKILL.md) ..."` |


---

## Subtask 0: GitHub Actions CI infrastructure

### Description

Establish the GitHub Actions workflow infrastructure that all subsequent subtasks build upon. This includes the workflow YAML skeletons for both execution modes (periodic and on-demand), authentication setup for GitHub App tokens and Claude API via Vertex AI, tool installation steps (Go, goimports, golangci-lint, Claude Code CLI), and runner configuration.

> **Phase 1 implementation:** A single `periodic-pr-agent.yml` workflow supports three triggers: `pull_request: [opened, synchronize]` for auto-triggering on new PRs in this repo, `workflow_dispatch` with a `pr_url` input for on-demand single-PR monitoring, and cron for the periodic sweep (active but unused in Phase 1). The workflow selects on-demand + `--monitor-only` mode when triggered by a PR event or when `pr_url` is provided, and periodic mode otherwise.

### Acceptance Criteria

1. Four workflow YAML files exist and are syntactically valid:
  - `.github/workflows/pr-agent-shared.yml` — reusable workflow (`workflow_call`) containing shared setup, tool installation, auth, agent execution, and artifact upload.
  - `.github/workflows/periodic-pr-agent.yml` — triggered by cron schedule; calls `pr-agent-shared`.
  - `.github/workflows/on-demand-pr-agent.yml` — triggered by `workflow_dispatch` and `repository_dispatch`; calls `pr-agent-shared`.
  - `.github/workflows/oape-pr-agent-trigger.yml` — **lightweight trigger workflow installed in each target repo**. Listens for CI failure events (`check_run` for GitHub Actions, `status` for Prow/OpenShift CI) and dispatches to `oape-ai-e2e` via `repository_dispatch` or `gh workflow run`.
2. The shared reusable workflow installs: Go toolchain, `gh` CLI, `goimports`, `golangci-lint`, and Claude Code CLI.
3. Authentication is configured:
  - GitHub App token generated via `actions/create-github-app-token` for push operations (avoids `GITHUB_TOKEN` anti-recursion limitation).
  - Claude API access via Vertex AI using GCP Workload Identity Federation (`google-github-actions/auth@v2`). No service account keys are stored as secrets.
4. Runner configuration uses `ubuntu-latest` with `timeout-minutes: 55` to stay within the 1-hour GitHub App token TTL.
5. All workflows can be triggered manually via `workflow_dispatch` for testing.
6. Target repo trigger workflow correctly handles both Prow (`status` event) and GitHub Actions (`check_run` event) CI failures for any open PR in the repo.

### Dependencies

None — this is the foundation subtask.

### Implementation Hints

- **Periodic workflow skeleton** (calls the shared reusable workflow):
  ```yaml
  name: periodic-pr-agent
  on:
    schedule:
      - cron: '0 8-23 * * 1-5'  # Every hour, weekdays, 8:00–23:00 UTC (switch to /3 after target repo triggers in Phase 3)
    workflow_dispatch:
      inputs:
        dry_run:
          type: boolean
          default: false
          description: 'Run in dry-run mode (no file modifications)'

  concurrency:
    group: pr-agent-periodic
    cancel-in-progress: false

  jobs:
    pr-agent:
      uses: ./.github/workflows/pr-agent-shared.yml
      with:
        mode: periodic
        dry_run: ${{ inputs.dry_run || false }}
      secrets: inherit
  ```
- **On-demand workflow skeleton** (accepts PR URL via `workflow_dispatch` or `repository_dispatch` from target repos):
  ```yaml
  name: on-demand-pr-agent
  concurrency:
    group: pr-agent-on-demand-${{ github.event.client_payload.pr_url || inputs.pr_url || github.run_id }}
    cancel-in-progress: false
  on:
    workflow_dispatch:
      inputs:
        pr_url:
          required: true
          description: 'Full PR URL (https://github.com/org/repo/pull/123)'
        dry_run:
          type: boolean
          default: false
    repository_dispatch:
      types: [pr-agent-trigger]
      # Payload: { "pr_url": "https://github.com/org/repo/pull/123" }

  jobs:
    pr-agent:
      uses: ./.github/workflows/pr-agent-shared.yml
      with:
        mode: on-demand
        pr_url: ${{ github.event.client_payload.pr_url || inputs.pr_url }}
        dry_run: ${{ inputs.dry_run || false }}
      secrets: inherit
  ```
- **Target repo trigger workflow** (`oape-pr-agent-trigger.yml` — installed in each target repo):
  ```yaml
  # Lightweight workflow installed in target repos (cert-manager-operator, etc.)
  # Detects CI failures on any open PR and dispatches to oape-ai-e2e for processing.
  name: oape-pr-agent-trigger
  on:
    # GitHub Actions CI failures
    check_run:
      types: [completed]
    # Prow / OpenShift CI failures (uses Status API, not Checks API)
    status: {}

  jobs:
    dispatch:
      # Fire on CI failures for any open PR in this repo
      if: >
        (github.event_name == 'check_run' &&
         github.event.check_run.conclusion == 'failure') ||
        (github.event_name == 'status' &&
         github.event.state == 'failure')
      runs-on: ubuntu-latest
      steps:
        - name: Find PR for commit
          id: find-pr
          env:
            GH_TOKEN: ${{ github.token }}
          run: |
            # Extract commit SHA from event
            if [[ "${{ github.event_name }}" == "check_run" ]]; then
              SHA="${{ github.event.check_run.head_sha }}"
            else
              SHA="${{ github.event.sha }}"
            fi

            # Find open PR for this commit
            PR_URL=$(gh pr list --repo "${{ github.repository }}" \
              --state open \
              --json url,headRefOid \
              --jq ".[] | select(.headRefOid == \"${SHA}\") | .url" \
              | head -1)

            if [[ -n "$PR_URL" ]]; then
              echo "pr_url=${PR_URL}" >> "$GITHUB_OUTPUT"
              echo "Found OAPE PR: $PR_URL"
            else
              echo "No OAPE PR found for commit $SHA"
            fi

        - name: Dispatch to oape-ai-e2e
          if: steps.find-pr.outputs.pr_url != ''
          env:
            GH_TOKEN: ${{ secrets.OAPE_DISPATCH_TOKEN }}
          run: |
            gh api repos/openshift-eng/oape-ai-e2e/dispatches \
              -f event_type=pr-agent-trigger \
              -f client_payload[pr_url]="${{ steps.find-pr.outputs.pr_url }}"
  ```
  > **Note:** The target repo trigger workflow requires a `OAPE_DISPATCH_TOKEN` secret
  > with `repo` scope on `openshift-eng/oape-ai-e2e` to send `repository_dispatch` events.
  > Alternatively, the OAPE GitHub App token can be used if the App has dispatch permissions.
- **Tool setup script** (`scripts/pr-agent/setup-tools.sh`):
  ```bash
  #!/usr/bin/env bash
  set -euo pipefail
  # Go is pre-installed on ubuntu-latest
  go install golang.org/x/tools/cmd/goimports@latest
  curl -sSfL https://raw.githubusercontent.com/golangci/golangci-lint/master/install.sh | sh -s -- -b "$(go env GOPATH)/bin"
  # Claude Code CLI (installed via npm)
  npm install -g @anthropic-ai/claude-code
  ```
- **GitHub App token** is required instead of `GITHUB_TOKEN` because pushes made with `GITHUB_TOKEN` do not trigger downstream CI runs (GitHub's anti-recursion rule). A GitHub App token sidesteps this limitation.
- **Reference:** HyperShift uses `actions/create-github-app-token@v1` with a dedicated GitHub App for the same reason.
- **Reusable workflow** for shared setup (`pr-agent-shared.yml`):
  ```yaml
  name: PR Agent Shared Setup
  on:
    workflow_call:
      inputs:
        mode:
          type: string
          required: true
          description: 'periodic or on-demand'
        pr_url:
          type: string
          required: false
          description: 'PR URL (required for on-demand mode)'
        dry_run:
          type: boolean
          default: false
      secrets:
        OAPE_APP_ID:
          required: true
        OAPE_APP_PRIVATE_KEY:
          required: true
        GCP_WORKLOAD_IDENTITY_PROVIDER:
          required: true
        GCP_SERVICE_ACCOUNT:
          required: true
        GCP_PROJECT_ID:
          required: true

  jobs:
    pr-agent:
      runs-on: ubuntu-latest
      timeout-minutes: 55
      steps:
        - uses: actions/checkout@v4
        - name: Generate GitHub App Token
          id: app-token
          uses: actions/create-github-app-token@v1
          with:
            app-id: ${{ secrets.OAPE_APP_ID }}
            private-key: ${{ secrets.OAPE_APP_PRIVATE_KEY }}
        - name: Authenticate to GCP (Workload Identity Federation)
          uses: google-github-actions/auth@v2
          with:
            workload_identity_provider: ${{ secrets.GCP_WORKLOAD_IDENTITY_PROVIDER }}
            service_account: ${{ secrets.GCP_SERVICE_ACCOUNT }}
        - name: Setup Tools
          run: scripts/pr-agent/setup-tools.sh
        - name: Run PR Agent
          env:
            GH_TOKEN: ${{ steps.app-token.outputs.token }}
            CLAUDE_CODE_USE_VERTEX: '1'
            CLOUD_ML_REGION: global
            ANTHROPIC_VERTEX_PROJECT_ID: ${{ secrets.GCP_PROJECT_ID }}
            DRY_RUN: ${{ inputs.dry_run }}
          run: |
            if [[ "${{ inputs.mode }}" == "on-demand" ]]; then
              scripts/pr-agent/entrypoint.sh --mode on-demand --pr-url "${{ inputs.pr_url }}"
            else
              scripts/pr-agent/entrypoint.sh --mode periodic
            fi
        - name: Upload Audit Log
          if: always()
          uses: actions/upload-artifact@v4
          with:
            name: pr-agent-audit-${{ github.run_id }}
            path: ${{ runner.temp }}/pr-agent-audit-*.jsonl
            retention-days: 30
        - name: Upload Reports
          if: always()
          uses: actions/upload-artifact@v4
          with:
            name: pr-agent-reports-${{ github.run_id }}
            path: ${{ runner.temp }}/pr-agent-report-*.md
            retention-days: 30
  ```
  Both `periodic-pr-agent.yml` and `on-demand-pr-agent.yml` call this reusable workflow instead of duplicating setup steps.

### Files


| File                                          | Action                                                                          |
| --------------------------------------------- | ------------------------------------------------------------------------------- |
| `.github/workflows/pr-agent-shared.yml`       | Create (reusable workflow with shared setup)                                    |
| `.github/workflows/periodic-pr-agent.yml`     | Create (calls pr-agent-shared)                                                  |
| `.github/workflows/on-demand-pr-agent.yml`    | Create (accepts workflow_dispatch + repository_dispatch, calls pr-agent-shared) |
| `.github/workflows/oape-pr-agent-trigger.yml` | Create (lightweight trigger workflow template for installation in target repos) |
| `scripts/pr-agent/setup-tools.sh`             | Create                                                                          |


---

## Subtask 1: Create entrypoint script with PR discovery and prechecks

### Description

Create the main bash entrypoint script that orchestrates the PR agent workflow. This script handles two execution modes: **periodic** (discovers all open PRs across allowed repos and processes each) and **on-demand** (processes a single specified PR). It includes argument parsing, prechecks, and the top-level processing loop that invokes downstream capabilities (CI monitoring, auto-fix, review handling).

> **Phase 1 implementation:** The entrypoint supports a `--monitor-only` flag that skips the auto-fix phase entirely, running only CI monitoring, deterministic classification, and status reporting. Phase 1 uses on-demand + `--monitor-only` mode exclusively. The periodic sweep and auto-fix code paths exist but are not exercised until Phase 2.

### Acceptance Criteria

1. Entrypoint script accepts `--mode` flag with values `periodic` or `on-demand`.
2. In `periodic` mode:
  - Queries GitHub for all open PRs across repos listed in `deploy/config/team-repos.csv`.
  - Processes up to `PR_AGENT_MAX_PRS` (default 4) PRs per run. Kept low to ensure the run completes within the GitHub App token's 1-hour TTL.
  - Adds a 60-second delay between processing each PR (rate limiting).
3. In `on-demand` mode:
  - Accepts `--pr-url <URL>` argument.
  - Parses PR URL in both formats: full URL (`https://github.com/org/repo/pull/123`) and shorthand (`org/repo#123`). Extracts owner, repo name, and PR number.
  - Validates the PR exists and is in `open` state.
  - Validates the PR targets a repo listed in `deploy/config/team-repos.csv`. Rejects PRs from repos not in the allowlist.
4. In `periodic` mode, filters out PRs with the `pr-agent:skip` label. Developers can add this label to exclude specific PRs from automated processing.
5. Before processing each PR, checks for merge conflicts via `gh pr view --json mergeable -q .mergeable`. If `CONFLICTING`, skips CI analysis and auto-fix phases, proceeding directly to the status report with "merge conflict" as the primary finding.
6. Prechecks all pass before any work begins:
  - `gh auth status` confirms GitHub CLI authentication.
  - Claude Code CLI is available (`claude --version`).
  - Required environment variables are set (`GH_TOKEN`, `CLAUDE_CODE_USE_VERTEX`).
7. Fails immediately with a clear, prefixed error message (e.g., `PRECHECK FAILED: PR #123 is not open`) when any precheck fails.
8. Emits structured log lines to stdout for each PR processed: `[PR #N] owner/repo#123 — processing started`.
9. Stays within 1-hour token TTL: GitHub App tokens expire after 1 hour. The periodic run limits `PR_AGENT_MAX_PRS` to 4 (default) to ensure processing completes within this window. The GHA job timeout is set to 55 minutes (`timeout-minutes: 55`) as a safety net.
10. Maintains lightweight state persistence to avoid re-processing: tracks which CI jobs have been analyzed and which review comments have been addressed. State is persisted **across GHA runs** by embedding a hidden state block in the PR report comment: `<!-- oape-pr-agent-state:BASE64_ENCODED_JSON -->`. The state schema includes `analyzed` (array of `name:url` job keys — URL changes after `/retest`, ensuring re-runs get fresh analysis), `addressed` (array of comment IDs), and `last_run` (ISO timestamp). On each run, the agent reads the existing report comment, parses the embedded state, and skips already-processed jobs and comments. Within a run, an in-memory copy in `$RUNNER_TEMP/pr-agent-state-<owner>-<repo>-<pr-number>.json` prevents duplicate work across multiple PRs.
11. Wraps `gh` API calls in a retry helper function with exponential backoff (3 retries at 5s/15s/45s intervals) for resilience against transient GitHub API failures.

### Dependencies

Subtask 0 (GHA infrastructure must exist).

### Implementation Hints

- **PR discovery for periodic mode:**
  ```bash
  # Query all open PRs across allowed repos
  {
    read -r  # Skip CSV header row
    while IFS=, read -r product role repo_url; do
      owner_repo=$(echo "$repo_url" | sed 's|https://github.com/||;s|\.git$||')
      prs=$(gh pr list --repo "$owner_repo" \
        --state open --json number,url,headRefName,title,labels --limit 20)
      # Filter out PRs with pr-agent:skip label
      prs=$(echo "$prs" | jq '[.[] | select(.labels | map(.name) | index("pr-agent:skip") | not)]')
      # Append to processing list
    done
  } < deploy/config/team-repos.csv
  ```
- **PR URL parsing:**
  ```bash
  parse_pr_url() {
    local url="$1"
    if [[ "$url" =~ https://github.com/([^/]+)/([^/]+)/pull/([0-9]+) ]]; then
      OWNER="${BASH_REMATCH[1]}"
      REPO="${BASH_REMATCH[2]}"
      PR_NUMBER="${BASH_REMATCH[3]}"
    elif [[ "$url" =~ ^([^/]+)/([^#]+)#([0-9]+)$ ]]; then
      OWNER="${BASH_REMATCH[1]}"
      REPO="${BASH_REMATCH[2]}"
      PR_NUMBER="${BASH_REMATCH[3]}"
    else
      echo "PRECHECK FAILED: Invalid PR URL format: $url" >&2
      return 1
    fi
  }
  ```
- **PR validation:**
  ```bash
  pr_state=$(gh pr view "$PR_URL" --json state -q .state)
  if [[ "$pr_state" != "OPEN" ]]; then
    echo "PRECHECK FAILED: PR $PR_URL is not open (state: $pr_state)" >&2
    return 1
  fi
  ```
- **Merge conflict detection (run before processing):**
  ```bash
  check_merge_conflicts() {
    local pr_url="$1"
    local mergeable
    mergeable=$(gh_retry gh pr view "$pr_url" --json mergeable -q .mergeable)
    if [[ "$mergeable" == "CONFLICTING" ]]; then
      echo "[PR] Merge conflict detected — skipping CI analysis and auto-fix"
      return 1
    fi
    return 0
  }
  ```
- **GitHub API retry helper:**
  ```bash
  gh_retry() {
    local retries=3 delay=5
    for ((i = 1; i <= retries; i++)); do
      if "$@"; then return 0; fi
      if [[ "$i" -lt "$retries" ]]; then
        echo "[retry] Attempt $i/$retries failed, waiting ${delay}s..." >&2
        sleep "$delay"
        delay=$((delay * 3))
      fi
    done
    echo "[retry] All $retries attempts failed for: $*" >&2
    return 1
  }
  ```
- **Processing loop structure:**
  ```bash
  process_pr() {
    local pr_url="$1"
    parse_pr_url "$pr_url"
    
    echo "[PR #${PR_NUMBER}] ${OWNER}/${REPO}#${PR_NUMBER} — processing started"

    # Phase 0: Merge conflict check
    if ! check_merge_conflicts "$pr_url"; then
      # Skip to status report with merge conflict finding
      scripts/pr-agent/report.sh --pr-url "$pr_url" --merge-conflict
      return 0
    fi
    
    # Phase 1: CI Check Monitoring (Subtask 2)
    # Phase 2: Failure Analysis + Auto-Fix (Subtasks 3, 4)
    # Phase 3: Review Comment Handling (Subtask 5)
    # Phase 4: Status Report (Subtask 8)
    
    echo "[PR #${PR_NUMBER}] ${OWNER}/${REPO}#${PR_NUMBER} — processing complete"
  }
  ```
- **Reference:** HyperShift's Jira Agent iterates over issues with a 60-second rate limit between each. The Review Agent iterates over PRs similarly.

### Files


| File                             | Action |
| -------------------------------- | ------ |
| `scripts/pr-agent/entrypoint.sh` | Create |


---

## Subtask 2: Implement CI check monitoring and status polling

### Description

Add the CI monitoring capability as a standalone executable script. The agent needs to fetch the current state of all CI checks on the PR, categorize the overall status, and extract details about any failures. This is the primary input that drives the analyze-fix cycle. Uses `gh pr checks` which aggregates both GitHub Actions checks (Checks API) and Prow/OpenShift CI status checks (Status API) in a single call, matching the yolo-agent pattern.

### Acceptance Criteria

1. Fetches all CI checks for the PR using `gh pr checks` which aggregates both the Checks API (GitHub Actions) and the Status API (Prow/OpenShift CI) in one call.
2. Categorizes overall PR CI status into one of: `all-passed`, `some-failed`, `all-pending`, `mixed-pending`, `no-checks`.
3. For each failed check, extracts: check name, workflow/job name, conclusion (failure/cancelled/timed_out), and the URL to the failed run.
4. Handles `pending` state correctly — reports it as "in progress" rather than treating it as a failure. When all non-pending checks pass, reports status as `mixed-pending`.
5. Outputs structured JSON to a temp file (`$RUNNER_TEMP/ci-status-<owner>-<repo>-<pr-number>.json`) for consumption by downstream scripts.
6. Writes a one-line summary to stdout: `[CI] 8/10 passed | 1 failed | 1 pending`.
7. Is a standalone executable script that accepts `--owner`, `--repo`, and `--pr-number` arguments and writes output to `$RUNNER_TEMP`.

### Dependencies

Subtask 1 (entrypoint must exist and provide PR context variables).

### Implementation Hints

- **CI status fetching via `gh pr checks`** (aggregates both Checks API and Status API):
  ```bash
  fetch_ci_status() {
    local owner="$1" repo="$2" pr_number="$3"
    local output_file="${RUNNER_TEMP}/ci-status-${owner}-${repo}-${pr_number}.json"

    # gh pr checks aggregates both GitHub Actions (Checks API) and Prow (Status API)
    gh_retry gh pr checks "$pr_number" --repo "${owner}/${repo}" \
      --json name,state,link,bucket \
      > "$output_file"

    # Compute and append summary
    local total passed failed pending
    total=$(jq 'length' "$output_file")
    passed=$(jq '[.[] | select(.bucket == "pass")] | length' "$output_file")
    failed=$(jq '[.[] | select(.bucket == "fail")] | length' "$output_file")
    pending=$(jq '[.[] | select(.bucket == "pending")] | length' "$output_file")

    echo "[CI] ${passed}/${total} passed | ${failed} failed | ${pending} pending"
  }
  ```
- **Status aggregation logic:**
  ```bash
  aggregate_ci_status() {
    local status_file="${RUNNER_TEMP}/ci-status-${1}-${2}-${3}.json"  # owner, repo, pr_number
    local total passed failed pending
    total=$(jq 'length' "$status_file")
    passed=$(jq '[.[] | select(.bucket == "pass")] | length' "$status_file")
    failed=$(jq '[.[] | select(.bucket == "fail")] | length' "$status_file")
    pending=$(jq '[.[] | select(.bucket == "pending")] | length' "$status_file")

    if [[ "$total" -eq 0 ]]; then echo "no-checks"
    elif [[ "$failed" -gt 0 ]]; then echo "some-failed"
    elif [[ "$pending" -eq "$total" ]]; then echo "all-pending"
    elif [[ "$pending" -gt 0 ]]; then echo "mixed-pending"
    else echo "all-passed"
    fi
  }
  ```
- **Reference:** The yolo-agent uses `gh pr checks` with the same `--json name,state,link,bucket` pattern. HyperShift's review agent skips PRs where all checks pass.

### Files


| File                             | Action                                                    |
| -------------------------------- | --------------------------------------------------------- |
| `scripts/pr-agent/ci-monitor.sh` | Create (standalone executable, called by `entrypoint.sh`) |


---

## Subtask 3: Implement CI failure log analysis and root cause classification

### Description

Create the failure log fetching and classification pipeline as a standalone executable script. Classification uses a **two-tier approach**: deterministic regex-based classification first (handles ~80-90% of cases with zero API cost), with Claude Code CLI as a fallback only for failures classified as `unknown`. A Claude Code skill at `plugins/oape/skills/ci-failure-analysis/SKILL.md` serves as the single source of truth for classification taxonomy — its content is included via `cat` in the Claude prompt.

### Acceptance Criteria

1. A Claude Code skill exists at `plugins/oape/skills/ci-failure-analysis/SKILL.md` following the project's skill pattern. Its content is included in the Claude prompt via `cat` (not loaded via the plugin system).
2. **Deterministic classification first:** A bash function `classify_failure_deterministic()` uses regex patterns to classify failures without any Claude API call. Covers: `trivial-lint`, `trivial-format`, `trivial-import`, `trivial-generated-files`, `build-error`, `test-failure`, `infra-flake`.
3. **Claude Code as fallback only:** Claude CLI is invoked only for failures classified as `unknown` by the deterministic step. The classification step is read-only — it analyzes logs but never modifies files or runs git write operations. The skill content is included via `cat`:
  ```bash
   CLASSIFICATION_SCHEMA='{"type":"array","items":{"type":"object","properties":{"category":{"type":"string","enum":["trivial-lint","trivial-format","trivial-import","trivial-generated-files","build-error","test-failure","infra-flake","unknown"]},"confidence":{"type":"string","enum":["high","medium","low"]},"affected_files":{"type":"array","items":{"type":"string"}},"root_cause":{"type":"string"},"suggested_fix":{"type":"string"}},"required":["category","confidence","root_cause"]}}'

   claude --print -p "$(cat plugins/oape/skills/ci-failure-analysis/SKILL.md)

   Analyze the following CI failure log: $(cat "$LOG_FILE")" \
     --allowedTools "Bash(curl*),Read" \
     --json-schema "$CLASSIFICATION_SCHEMA" --max-budget-usd "${MAX_BUDGET_PER_PR:-5.00}"
  ```
4. Classifies each failure into exactly one category: `trivial-lint`, `trivial-format`, `trivial-import`, `trivial-generated-files`, `build-error`, `test-failure`, `infra-flake`, or `unknown`.
5. For trivial failures, identifies the specific files and (where possible) line numbers causing the issue.
6. Distinguishes infrastructure flakes (timeouts, network errors, pod scheduling failures, registry pull errors) from genuine code issues.
7. Produces a structured JSON analysis output per failed check containing: category, confidence level (high/medium/low), affected files, root cause summary, and suggested fix action.
8. Is a standalone executable script that accepts `--owner`, `--repo`, and `--pr-number` and reads CI status from `$RUNNER_TEMP/ci-status-<owner>-<repo>-<pr-number>.json`.

### Dependencies

Subtask 2 (needs the list of failed checks and their URLs from the CI status JSON).

### Implementation Hints

- **Log fetching (deterministic bash, before classification):**
  ```bash
  fetch_failure_logs() {
    local pr_number="$1"
    local status_file="${RUNNER_TEMP}/ci-status-${owner}-${repo}-${pr_number}.json"

    # gh pr checks output uses .bucket and .link fields
    jq -r '.[] | select(.bucket == "fail") | .link' "$status_file" | while read -r url; do
      if [[ "$url" == *"github.com"*"/actions/"* ]]; then
        # GitHub Actions: extract run ID, fetch failed logs
        run_id=$(echo "$url" | grep -oP 'runs/\K[0-9]+')
        gh_retry gh run view "$run_id" --log-failed > "${RUNNER_TEMP}/log-${run_id}.txt" 2>/dev/null || true
      elif [[ "$url" == *"prow.ci.openshift.org"* ]]; then
        # Prow: target_url points to Prow UI (e.g., https://prow.ci.openshift.org/view/gs/BUCKET/PATH)
        # Extract the GCS path and fetch build-log.txt from gcsweb
        local gcs_path
        gcs_path=$(echo "$url" | sed -n 's|.*/view/g[cs]s\?/||p')
        if [[ -n "$gcs_path" ]]; then
          local gcsweb_base="${GCSWEB_BASE_URL:-https://gcsweb-ci.apps.ci.l2s4.p1.openshiftapps.com}"
          local gcsweb_url="${gcsweb_base}/gcs/${gcs_path}/build-log.txt"
          # Prow build-log.txt can be 100K+ lines; truncate to last 1000 lines (failure is at the tail)
          curl -sSL "$gcsweb_url" | tail -1000 > "${RUNNER_TEMP}/log-prow-$(date +%s).txt" 2>/dev/null || true
        fi
      fi
    done
  }
  ```
- **Deterministic classification (handles ~80-90% of cases, zero API cost):**
  ```bash
  classify_failure_deterministic() {
    local log_file="$1"
    local content
    content=$(cat "$log_file")

    if echo "$content" | grep -qiE 'golangci-lint|golint|staticcheck|revive'; then
      echo "trivial-lint"
    elif echo "$content" | grep -qiE 'gofmt|goimports|formatting differs|diff.*\.go'; then
      echo "trivial-format"
    elif echo "$content" | grep -qiE 'imported and not used|could not import|import ordering'; then
      echo "trivial-import"
    elif echo "$content" | grep -qiE 'generated code is out of date|make generate|make manifests|deepcopy-gen|zz_generated'; then
      echo "trivial-generated-files"
    elif echo "$content" | grep -qiE 'cannot compile|undefined:|syntax error|cannot use.*as.*in'; then
      echo "build-error"
    elif echo "$content" | grep -qiE '--- FAIL|FAIL\s|panic:.*test|assertion failed'; then
      echo "test-failure"
    elif echo "$content" | grep -qiE 'context deadline exceeded|connection refused|i/o timeout|ErrImagePull|pod sandbox|TLS handshake timeout'; then
      echo "infra-flake"
    else
      echo "unknown"
    fi
  }
  ```
- **Two-tier classification flow:**
  ```bash
  classify_failures() {
    local pr_number="$1"
    local log_dir="${RUNNER_TEMP}"
    local results="[]"
    local unknown_logs=""

    for log_file in "${log_dir}"/log-*.txt; do
      [[ -f "$log_file" ]] || continue
      local category
      category=$(classify_failure_deterministic "$log_file")

      if [[ "$category" != "unknown" ]]; then
        # Deterministic classification — no Claude API cost
        results=$(echo "$results" | jq --arg cat "$category" --arg file "$log_file" \
          '. + [{"category": $cat, "confidence": "high", "affected_files": [], "root_cause": $cat, "suggested_fix": ""}]')
      else
        unknown_logs="${unknown_logs} ${log_file}"
      fi
    done

    # Fallback: invoke Claude only for unknown failures (read-only analysis)
    if [[ -n "$unknown_logs" ]]; then
      local claude_result
      local classification_schema='{"type":"array","items":{"type":"object","properties":{"category":{"type":"string","enum":["trivial-lint","trivial-format","trivial-import","trivial-generated-files","build-error","test-failure","infra-flake","unknown"]},"confidence":{"type":"string","enum":["high","medium","low"]},"affected_files":{"type":"array","items":{"type":"string"}},"root_cause":{"type":"string"},"suggested_fix":{"type":"string"}},"required":["category","confidence","root_cause"]}}'
      if ! claude_result=$(claude --print \
        --max-budget-usd "${MAX_BUDGET_PER_PR:-5.00}" \
        -p "$(cat plugins/oape/skills/ci-failure-analysis/SKILL.md)
      Analyze the following CI failure logs and classify each failure.
      $(for f in $unknown_logs; do echo "--- $(basename "$f") ---"; tail -1000 "$f"; done)" \
        --allowedTools "Bash(curl*),Read" \
        --json-schema "$classification_schema" 2>"${RUNNER_TEMP}/claude-stderr.txt"); then
        audit_log "error" "claude-classification" "" "" \
          "Claude CLI failed: $(head -1 "${RUNNER_TEMP}/claude-stderr.txt")"
        claude_result='[]'
      fi
      results=$(echo "$results" | jq --argjson cr "$claude_result" '. + $cr')
    fi

    echo "$results" > "${RUNNER_TEMP}/failure-analysis-${owner}-${repo}-${pr_number}.json"
  }
  ```
- **Classification heuristics (documented in the skill for Claude's guidance):**
  - `trivial-lint`: Log contains `golangci-lint`, `golint`, `staticcheck`, or linter rule names.
  - `trivial-format`: Log contains `gofmt`, `goimports`, `diff` output showing whitespace/formatting-only changes.
  - `trivial-import`: Log contains `imported and not used`, `could not import`, or import ordering errors.
  - `trivial-generated-files`: Log contains `generated code is out of date`, `make generate`, `make manifests`, `deepcopy-gen`.
  - `build-error`: Log contains `cannot compile`, `undefined:`, `syntax error`, compilation errors.
  - `test-failure`: Log contains `FAIL`, `--- FAIL`, test function names, assertion failures.
  - `infra-flake`: Log contains `context deadline exceeded`, `connection refused`, `i/o timeout`, `ErrImagePull`, `pod sandbox`.
- **Skill structure:** Follow `plugins/oape/skills/analyze-rfe/SKILL.md` pattern — persona, prerequisites, step-by-step procedure.

### Files


| File                                               | Action                                                                                      |
| -------------------------------------------------- | ------------------------------------------------------------------------------------------- |
| `scripts/pr-agent/log-analyzer.sh`                 | Create (standalone executable: log fetching, deterministic classification, Claude fallback) |
| `plugins/oape/skills/ci-failure-analysis/SKILL.md` | Create                                                                                      |


---

## Subtask 4: Implement trivial auto-fix engine

### Description

Build the automated fix-and-push capability for trivial CI failures. When the failure analysis (Subtask 3) identifies a trivial issue, the agent checks out the PR branch, applies the appropriate fix command, verifies the fix compiles, and pushes. Auto-fix is always enabled in the CI job context (unlike the interactive mode which required `--auto-fix`). The `DRY_RUN` environment variable controls whether modifications are actually committed and pushed.

### Acceptance Criteria

1. In `DRY_RUN=true` mode, reports what *would* be fixed without modifying files or pushing.
2. Maps each trivial failure category to the correct fix command:
  - `trivial-format` → `go fmt ./...`
  - `trivial-import` → `goimports -w <affected-files>` (or `go fmt ./...` if goimports unavailable)
  - `trivial-lint` → targeted fix based on linter rule (e.g., `golangci-lint run --fix` where supported)
  - `trivial-generated-files` → `make generate && make manifests`
3. Verifies fix compiles successfully (`go build ./...` and `go vet ./...`) before committing.
4. Creates a commit with a descriptive message following repository conventions (e.g., `fix: run goimports to resolve CI lint failure`).
5. Pushes to the PR's head branch using the GitHub App token (not `GITHUB_TOKEN`) to ensure CI is re-triggered.
6. Reports the fix to the audit log (commit SHA, files changed, fix type).
7. Respects all safety guardrails from Subtask 7 (file blocklist, commit limits, diff size limits).
8. **(Phase 2)** For `infra-flake` failures: posts a targeted `/test <job-name>` comment to re-trigger only the flaky job (not blanket `/retest`). Gated by `RETEST_INFRA_FLAKES` config flag (default `false`). Limited to max 2 retests per job per run to prevent retry loops. Tracked in the state to avoid re-posting on subsequent runs.

### Dependencies

Subtask 3 (needs failure classification to determine fix type and affected files).
Subtask 7 (safety guardrails must be enforced before any file modification).

### Implementation Hints

- **Checkout and fix flow:**
  ```bash
  apply_trivial_fixes() {
    local owner="$1" repo="$2" pr_number="$3"
    local analysis_file="${RUNNER_TEMP}/failure-analysis-${owner}-${repo}-${pr_number}.json"
    local pr_commit_count=0
    # Global commit counter file shared across auto-fix and review handler
    local commit_counter_file="${RUNNER_TEMP}/pr-agent-commit-count.txt"
    local total_commits
    total_commits=$(cat "$commit_counter_file" 2>/dev/null || echo 0)

    # Clone with blobless filter for performance (OpenShift repos can be multi-GB)
    local workdir="${RUNNER_TEMP}/repo-${owner}-${repo}-${pr_number}"
    gh repo clone "${owner}/${repo}" "$workdir" -- --filter=blob:none --single-branch
    cd "$workdir"
    gh pr checkout "$pr_number"

    # Configure git identity for the bot
    git config user.name "oape-bot[bot]"
    git config user.email "oape-bot[bot]@users.noreply.github.com"
    git remote set-url origin "https://x-access-token:${GH_TOKEN}@github.com/${owner}/${repo}.git"

    while read -r fix; do
      local category=$(echo "$fix" | jq -r '.category')
      local files=$(echo "$fix" | jq -r '.affected_files[]')

      # Pre-fix blocklist check (fast guard on known affected files, category-aware for go.sum exception)
      if ! check_blocklist "$files" "$category"; then
        audit_log "blocked" "$category" "$files" "" "security-sensitive file"
        continue
      fi

      # Check global commit limits
      if [[ "$total_commits" -ge "${MAX_COMMITS_PER_RUN:-10}" ]]; then
        audit_log "skipped" "$category" "$files" "" "run commit limit reached"
        continue
      fi
      if [[ "$pr_commit_count" -ge "${MAX_COMMITS_PER_PR:-3}" ]]; then
        audit_log "skipped" "$category" "$files" "" "per-PR commit limit reached"
        continue
      fi

      # Apply the fix (framework-aware for generated files)
      # Determine PR base branch for scoping fixes to PR-changed files only
      local base_branch
      base_branch=$(gh pr view "$pr_number" --repo "${owner}/${repo}" --json baseRefName -q .baseRefName)
      git fetch origin "${base_branch}" --depth=1 2>/dev/null || true

      case "$category" in
        trivial-format)
          git diff --name-only HEAD "$(git merge-base HEAD "origin/${base_branch}")" -- '*.go' | xargs -r go fmt
          ;;
        trivial-import)  goimports -w $files ;;
        trivial-lint)    golangci-lint run --fix ./... 2>/dev/null || true ;;
        trivial-generated-files)
          if grep -q 'sigs.k8s.io/controller-runtime' go.mod; then
            make generate && make manifests
          elif grep -q 'github.com/openshift/library-go' go.mod; then
            make update
          else
            make generate 2>/dev/null || make update 2>/dev/null || true
          fi
          ;;
      esac

      # Verify fix compiles
      if ! go build ./... || ! go vet ./...; then
        git checkout -- .
        git clean -fd
        audit_log "reverted" "$category" "$files" "" "fix broke compilation"
        continue
      fi

      # Post-fix blocklist check (safety net — verify ACTUAL modified files)
      local modified_files
      modified_files=$(git diff --name-only; git ls-files --others --exclude-standard)
      if ! check_blocklist "$modified_files" "$category"; then
        git checkout -- .
        git clean -fd
        audit_log "reverted" "$category" "$modified_files" "" "post-fix blocklist violation"
        continue
      fi

      # Check diff size guard (count both insertions and deletions)
      local diff_lines
      diff_lines=$(git diff --numstat | awk '{s+=$1+$2} END {print s+0}')
      if [[ "$diff_lines" -gt 500 ]]; then
        git checkout -- .
        git clean -fd
        audit_log "reverted" "$category" "$files" "" "diff too large ($diff_lines lines)"
        continue
      fi

      if [[ "${DRY_RUN:-false}" == "true" ]]; then
        audit_log "dry-run" "$category" "$files" "" "would commit and push"
        git checkout -- .
        git clean -fd
        continue
      fi

      # Stage both modified tracked files AND new untracked files
      git diff --name-only -z | xargs -0 git add
      git ls-files --others --exclude-standard -z | xargs -0 git add
      git commit -m "fix: ${category} — auto-fix by oape-pr-agent"
      local sha=$(git rev-parse HEAD)

      # Pull before push to handle concurrent pushes to the same branch
      if ! git pull --rebase origin HEAD 2>/dev/null; then
        git rebase --abort 2>/dev/null || true
        audit_log "reverted" "$category" "$files" "$sha" "rebase conflict — concurrent push detected"
        git reset --hard HEAD~1
        continue
      fi
      git push origin HEAD
      pr_commit_count=$((pr_commit_count + 1))
      total_commits=$((total_commits + 1))
      echo "$total_commits" > "$commit_counter_file"

      audit_log "auto-fix" "$category" "$files" "$sha" "success"
    done < <(jq -c '.[] | select(.category | startswith("trivial-"))' "$analysis_file")
  }
  ```
- **GitHub App token for push:** The token from `actions/create-github-app-token` is set as `GH_TOKEN` and also used for git push via:
  ```bash
  git remote set-url origin "https://x-access-token:${GH_TOKEN}@github.com/${owner}/${repo}.git"
  ```
- **Reference:** `plugins/oape/commands/implement-review-fixes.md` for the fix-verify-commit pattern already used in OAPE. HyperShift's Jira Agent uses a similar clone → fix → push → PR flow.

### Files


| File                           | Action                                                    |
| ------------------------------ | --------------------------------------------------------- |
| `scripts/pr-agent/auto-fix.sh` | Create (standalone executable, called by `entrypoint.sh`) |


---

## Subtask 5: Implement review comment monitoring and response

### Description

Add the ability to fetch, analyze, and respond to review comments on PRs in allowed repos. Following HyperShift's Review Agent pattern, the agent identifies unresolved review threads that need attention, skips threads already addressed by the bot, and invokes Claude Code CLI to generate appropriate responses (code changes for actionable requests, explanations for questions). Bot-generated comments are filtered via `SKIP_USERS`.

### Acceptance Criteria

1. Fetches all review threads (inline and top-level) and review summaries from the PR.
2. Implements HyperShift-style comment analysis logic:
  - **Process**: No bot reply in thread (first response needed), or human replied after bot's last comment (follow-up needed).
  - **Skip**: Bot already replied with no human follow-up, thread is resolved, thread is outdated (code changed).
3. Filters out bot-generated comments using a configurable skip list (default: `openshift-ci`, `openshift-bot`, `dependabot`, `codecov`, `sonarcloud`, `coderabbitai[bot]`). Additional users configured via `SKIP_USERS` env var.
4. Skips known bot accounts (via `SKIP_USERS`). All other commenters are treated as legitimate reviewers — branch protection and repo permissions provide the authorization boundary.
5. Invokes Claude Code CLI to address each unresolved thread. Claude receives the full thread context and decides whether to make code changes or provide an explanation — no separate intent classification step. The safety skill content is included via `cat` in the prompt.
6. Pushes code changes (if any) and posts inline reply comments via `gh api`.
7. Respects the global commit counter shared with the auto-fix engine (via `$RUNNER_TEMP/pr-agent-commit-count.txt`). Increments the counter for each commit pushed.
8. Claude Code invocations use `--allowedTools` to exclude destructive git operations (no `git push --force`, `git push -f`, `git rebase`, `git reset --hard`).

### Dependencies

Subtask 1 (entrypoint must provide PR context).

### Implementation Hints

- **Thread analysis (deterministic bash):**
  ```bash
  analyze_review_threads() {
    local owner="$1" repo="$2" pr_number="$3"

    # Fetch review comments (inline)
    local comments
    comments=$(gh api "repos/${owner}/${repo}/pulls/${pr_number}/comments" \
      --paginate --jq '.')

    # Fetch review summaries
    local reviews
    reviews=$(gh api "repos/${owner}/${repo}/pulls/${pr_number}/reviews" \
      --paginate --jq '.')

    # Fetch top-level PR conversation comments (not inline on code)
    local issue_comments
    issue_comments=$(gh api "repos/${owner}/${repo}/issues/${pr_number}/comments" \
      --paginate --jq '.')

    # Group by thread (in_reply_to_id), determine if bot has replied
    # Filter: skip resolved, skip outdated, skip unauthorized authors
    # Output: list of threads needing attention
  }
  ```
- **Bot detection:**
  ```bash
  SKIP_USERS="${SKIP_USERS:-openshift-ci,openshift-bot,dependabot,codecov,sonarcloud,coderabbitai[bot]}"
  is_bot_or_skipped() {
    local login="$1" user_type="$2"
    [[ "$user_type" == "Bot" ]] && return 0
    echo "$SKIP_USERS" | tr ',' '\n' | grep -qx "$login" && return 0
    return 1
  }
  ```
- **Claude Code CLI invocation for review response:**
Claude receives the full thread context and decides whether to make code changes or provide an explanation. No separate `classify_thread_intent()` step — Claude handles this naturally based on the comment content.
  ```bash
  address_review_thread() {
    local owner="$1" repo="$2" pr_number="$3" thread_file="$4"
    local workdir="${RUNNER_TEMP}/repo-${owner}-${repo}-${pr_number}"

    cd "$workdir"

    # Check global commit limit before invoking Claude
    local commit_counter_file="${RUNNER_TEMP}/pr-agent-commit-count.txt"
    local total_commits
    total_commits=$(cat "$commit_counter_file" 2>/dev/null || echo 0)
    if [[ "$total_commits" -ge "${MAX_COMMITS_PER_RUN:-10}" ]]; then
      echo "[review] Skipping thread — commit limit reached"
      return 0
    fi

    # Include safety skill content and let Claude decide how to respond
    claude --print \
      --max-budget-usd "${MAX_BUDGET_PER_PR:-5.00}" \
      -p "$(cat plugins/oape/skills/pr-agent-safety/SKILL.md)

  Address the following review comment on PR #${pr_number} in ${owner}/${repo}.
  Review thread: $(cat "$thread_file")

  If the reviewer requests a code change (imperative language like 'change', 'fix', 'update',
  'remove', 'add'), make the change, verify it compiles (go build ./...), and commit.
  If the reviewer asks a question, reply with a concise explanation only — do NOT change code.
  One response per feedback — never respond via both inline reply AND general PR comment." \
      --allowedTools "Bash(git diff*),Bash(git add*),Bash(git commit*),Bash(git push origin HEAD),Bash(git log*),Bash(git status*),Bash(go*),Bash(make*),Bash(gh api*),Bash(gh pr comment*),Read,Write,Edit"

    # Update global commit counter if Claude pushed commits
    local new_commits
    new_commits=$(git rev-list --count HEAD ^"${HEAD_SHA_BEFORE}")
    if [[ "$new_commits" -gt 0 ]]; then
      total_commits=$((total_commits + new_commits))
      echo "$total_commits" > "$commit_counter_file"
    fi
  }
  ```
  > **Note:** The `--allowedTools` restriction explicitly excludes `git push --force`,
  > `git push -f`, `git rebase`, and `git reset --hard` — only safe git operations are
  > permitted. The existing `/oape:implement-review-fixes` command pattern is referenced
  > in the prompt for fix prioritization and verification patterns.
- **Reference:** HyperShift's Review Agent (`periodic-review-agent`) uses identical thread analysis logic. Their `/utils:address-reviews` command is the equivalent of this Claude Code invocation.

### Files


| File                                 | Action                                                    |
| ------------------------------------ | --------------------------------------------------------- |
| `scripts/pr-agent/review-handler.sh` | Create (standalone executable, called by `entrypoint.sh`) |


---

## Subtask 6: Wire together the PR processing pipeline

### Description

Create the `process_pr()` orchestration function in `entrypoint.sh` that wires together all capabilities from Subtasks 2–5 and 7–8 into the end-to-end processing pipeline. This subtask does NOT modify the workflow YAML files (those are fully specified in Subtask 0) — it only adds the function that sequences CI monitoring → failure analysis → auto-fix → review handling → status reporting for a single PR.

> **Phase 1 implementation:** `process_pr()` checks the `MONITOR_ONLY` environment variable (set by the `--monitor-only` CLI flag). When `MONITOR_ONLY=true`, the auto-fix phase is skipped entirely — the pipeline runs: merge conflict check → CI monitoring → failure classification → status report. This allows Phase 1 to validate CI monitoring and reporting without risk of pushing code changes.

### Acceptance Criteria

1. The `process_pr()` function invokes all phases in order: CI status check → failure log analysis → trivial auto-fix → review comment handling → status report.
2. Phases are conditional: failure analysis and auto-fix only run when CI status is `some-failed`; review comment handling only runs when there are unresolved threads.
3. Each phase logs its start/end with structured output: `[PR #N] Phase: <name> — started/completed`.
4. If a phase fails, it logs the error and continues to the next phase (best-effort processing).
5. The `run_periodic()` loop and `run_on_demand()` entry point call `process_pr()` for each PR.
6. Each PR is processed with a per-PR time limit (`PR_TIMEOUT_SECONDS`, default 720 = 12 minutes). On timeout, posts a partial status report and continues to the next PR, preventing one complex PR from starving subsequent PRs.

### Dependencies

Subtasks 1, 2, 3, 4, 5, 7, 8 (all capabilities must exist before they can be wired together).

### Implementation Hints

- **Periodic mode main loop** (in `entrypoint.sh`):
  ```bash
  run_periodic() {
    local max_prs="${PR_AGENT_MAX_PRS:-4}"
    local processed=0

    discover_oape_prs  # Populates $PR_LIST_FILE

    while IFS= read -r pr_url; do
      if [[ "$processed" -ge "$max_prs" ]]; then
        echo "[periodic] Reached max PRs ($max_prs), stopping"
        break
      fi

      echo "[periodic] Processing PR $((processed + 1))/${max_prs}: $pr_url"
      local pr_timeout="${PR_TIMEOUT_SECONDS:-720}"
      if timeout "$pr_timeout" bash -c "process_pr '$pr_url'"; then
        echo "[periodic] PR $pr_url — completed successfully"
      elif [[ $? -eq 124 ]]; then
        echo "[periodic] PR $pr_url — timed out after ${pr_timeout}s, posting partial report"
        parse_pr_url "$pr_url"
        scripts/pr-agent/report.sh --owner "$OWNER" --repo "$REPO" --pr-number "$PR_NUMBER" --partial
      else
        echo "[periodic] PR $pr_url — failed (continuing to next)"
      fi

      processed=$((processed + 1))

      # Rate limit between PRs
      if [[ "$processed" -lt "$max_prs" ]]; then
        echo "[periodic] Waiting 60s before next PR..."
        sleep 60
      fi
    done < "$PR_LIST_FILE"

    echo "[periodic] Processed $processed PRs"
  }
  ```
- **On-demand mode** (in `entrypoint.sh`):
  ```bash
  run_on_demand() {
    local pr_url="$1"
    echo "[on-demand] Processing single PR: $pr_url"
    process_pr "$pr_url"
    echo "[on-demand] Done"
  }
  ```
- **Process function** (invokes all phases via standalone scripts):
  ```bash
  process_pr() {
    local pr_url="$1"
    parse_pr_url "$pr_url"

    # Phase 0: Merge conflict check
    local mergeable
    mergeable=$(gh_retry gh pr view "$pr_url" --json mergeable -q .mergeable)
    if [[ "$mergeable" == "CONFLICTING" ]]; then
      echo "[PR #${PR_NUMBER}] Merge conflict detected — skipping to report"
      scripts/pr-agent/report.sh --owner "$OWNER" --repo "$REPO" \
        --pr-number "$PR_NUMBER" --merge-conflict
      return 0
    fi

    # Phase 1: CI Check Monitoring (standalone script — outputs aggregate status to stdout, saves details to JSON)
    local ci_status
    ci_status=$(scripts/pr-agent/ci-monitor.sh --owner "$OWNER" --repo "$REPO" --pr-number "$PR_NUMBER")
    echo "[CI] Status: $ci_status"

    # Phase 2: Failure Analysis + Auto-Fix (only if failures exist)
    if [[ "$ci_status" == "some-failed" ]]; then
      scripts/pr-agent/log-analyzer.sh --owner "$OWNER" --repo "$REPO" --pr-number "$PR_NUMBER"
      scripts/pr-agent/auto-fix.sh --owner "$OWNER" --repo "$REPO" --pr-number "$PR_NUMBER"
    fi

    # Phase 3: Review Comment Handling (standalone script)
    scripts/pr-agent/review-handler.sh --owner "$OWNER" --repo "$REPO" --pr-number "$PR_NUMBER"

    # Phase 4: Status Report (standalone script)
    scripts/pr-agent/report.sh --owner "$OWNER" --repo "$REPO" --pr-number "$PR_NUMBER"
  }
  ```
- **Reference:** HyperShift's `periodic-review-agent` runs every 3 hours and processes up to 10 PRs. The `address-review-comments` job is the on-demand equivalent. Both share setup steps and use the same processing logic.

### Files


| File                             | Action                                                                     |
| -------------------------------- | -------------------------------------------------------------------------- |
| `scripts/pr-agent/entrypoint.sh` | Modify (add `process_pr()`, `run_periodic()`, `run_on_demand()` functions) |


---

## Subtask 7: Implement safety guardrails and file-modification boundaries

### Description

Define and enforce safety boundaries for the autonomous agent. Since the agent can modify code and push to branches in a CI context, strong guardrails are essential to prevent accidental damage. This includes file blocklists, commit limits, diff size limits, force-push prevention, and a comprehensive audit log. A dedicated safety script encapsulates the guardrail functions, and a Claude Code skill documents the safety rules for the LLM's awareness.

### Acceptance Criteria

1. Maintains a blocklist of file patterns that are never auto-modified. Uses extension-aware patterns to protect actual secret storage files while allowing Go source files that operate on Kubernetes Secret/Token resources:
  - Secret storage files: `*.key`, `*.pem`, `*.crt`, `*.cert`, `*.p12`, `*.pfx`, `*.env`, `credentials.`*, `kubeconfig`
  - Container/CI files: `Dockerfile`, `Containerfile`, `.dockerignore`
  - Workflow/build files: `.github/workflows/*`, `.tekton/*`, `Makefile`
  - RBAC manifests: `**/rbac/*.yaml`, `**/clusterrole*.yaml`
  - Dependency files: `go.mod` (blocked by default, but **allowed for the `trivial-generated-files` category** since `make generate` legitimately modifies it via `go mod tidy`)
  - `go.sum` (blocked by default, but **allowed for the `trivial-generated-files` category** since `make generate` legitimately modifies it via `go mod tidy`)
2. Enforces commit limits: max 3 commits per PR processing, max 10 total commits across all PRs in a single run. Stops auto-fixing (but continues monitoring/reporting) when limits are reached.
3. Never executes `git push --force` or any destructive operation that modifies remote/shared history. Local rollback of unpushed agent commits (e.g., `git reset --hard HEAD~1` after a failed rebase, `git pull --rebase` to sync with concurrent pushes) is permitted as a recovery mechanism.
4. Logs every action to a structured audit log (JSON lines format) at `$RUNNER_TEMP/pr-agent-audit-<run-id>.jsonl` including: timestamp, PR URL, action type, affected files, commit SHA (if applicable), and outcome.
5. `DRY_RUN=true` mode executes the full analysis pipeline but skips all file modifications, commits, and pushes. Reports what *would* have been done.
6. Diff size guard: if an auto-fix produces more than 500 lines of changes, abort and report.
7. Audit log is uploaded as a GitHub Actions artifact (30-day retention) at the end of every run.

### Dependencies

None — this is a standalone utility module. Its functions are consumed by Subtasks 4, 5, and 6 but it has no dependency on them.

### Implementation Hints

- **Blocklist check function (category-aware for go.sum exception):**
  ```bash
  # Protect actual secret storage files (not Go source files that operate on Secrets)
  BLOCKED_PATTERNS='\.(key|pem|crt|cert|p12|pfx)$|\.env$|credentials\.|(^|/)kubeconfig$'
  BLOCKED_PATTERNS+='|(^|/)Dockerfile$|(^|/)Containerfile$|\.dockerignore$'
  BLOCKED_PATTERNS+='|\.github/workflows|\.tekton/|(^|/)Makefile$'
  BLOCKED_PATTERNS+='|rbac/.*\.yaml|clusterrole.*\.yaml'
  BLOCKED_PATTERNS+='|go\.mod|go\.sum'
  # Same patterns but without go.mod and go.sum (allowed for trivial-generated-files)
  BLOCKED_PATTERNS_GENERATED='\.(key|pem|crt|cert|p12|pfx)$|\.env$|credentials\.|(^|/)kubeconfig$'
  BLOCKED_PATTERNS_GENERATED+='|(^|/)Dockerfile$|(^|/)Containerfile$|\.dockerignore$'
  BLOCKED_PATTERNS_GENERATED+='|\.github/workflows|\.tekton/|(^|/)Makefile$'
  BLOCKED_PATTERNS_GENERATED+='|rbac/.*\.yaml|clusterrole.*\.yaml'

  check_blocklist() {
    local files="$1"
    local category="${2:-}"
    local patterns="$BLOCKED_PATTERNS"
    # Allow go.mod and go.sum for trivial-generated-files (make generate legitimately modifies them via go mod tidy)
    if [[ "$category" == "trivial-generated-files" ]]; then
      patterns="$BLOCKED_PATTERNS_GENERATED"
    fi
    if echo "$files" | grep -iqE "$patterns"; then
      return 1  # blocked
    fi
    return 0  # safe
  }
  ```
- **Audit log function:**
  ```bash
  AUDIT_LOG="${RUNNER_TEMP}/pr-agent-audit-${GITHUB_RUN_ID:-local}.jsonl"

  audit_log() {
    local action="$1" category="$2" files="$3" commit="$4" outcome="$5"
    local ts
    ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    printf '{"ts":"%s","pr":"%s","action":"%s","type":"%s","files":%s,"commit":"%s","outcome":"%s"}\n' \
      "$ts" "${CURRENT_PR_URL:-}" "$action" "$category" \
      "$(echo "$files" | jq -R 'split(" ")' 2>/dev/null || echo '[]')" \
      "$commit" "$outcome" \
      >> "$AUDIT_LOG"
  }
  ```
- **Commit counter (global across the run):**
  ```bash
  TOTAL_COMMITS=0
  MAX_COMMITS_PER_RUN="${MAX_COMMITS_PER_RUN:-10}"
  MAX_COMMITS_PER_PR=3

  check_commit_limit() {
    if [[ "$TOTAL_COMMITS" -ge "$MAX_COMMITS_PER_RUN" ]]; then
      echo "GUARDRAIL: Total commit limit reached ($TOTAL_COMMITS/$MAX_COMMITS_PER_RUN)"
      return 1
    fi
    return 0
  }
  ```
- **Diff size guard:**
  ```bash
  check_diff_size() {
    local max_lines="${MAX_DIFF_LINES:-500}"
    local changed_lines
    changed_lines=$(git diff --numstat | awk '{s+=$1+$2} END {print s+0}')
    if [[ "$changed_lines" -gt "$max_lines" ]]; then
      echo "GUARDRAIL: Diff too large ($changed_lines lines > $max_lines limit)"
      return 1
    fi
    return 0
  }
  ```
- **Skill for Claude's awareness:**
  ```markdown
  # Safety Guardrails for PR Agent

  When operating as the OAPE PR agent, you MUST follow these rules:
  1. NEVER modify files matching: [blocklist patterns]
  2. NEVER use git push --force, git rebase, or git reset --hard
  3. ALWAYS verify changes compile before committing
  4. STOP if diff exceeds 500 lines
  ```
- **Reference:** KNOWN-ISSUES.md documents "Unrestricted agent permissions" as a critical issue. HyperShift's agents enforce similar guardrails: "Cannot execute destructive operations — no ability to delete resources or force-push."

### Files


| File                                           | Action                                                                                                                      |
| ---------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------- |
| `scripts/pr-agent/safety.sh`                   | Create (sourced utility library, provides shared functions to entrypoint.sh, auto-fix.sh, review-handler.sh, and report.sh) |
| `plugins/oape/skills/pr-agent-safety/SKILL.md` | Create                                                                                                                      |


---

## Subtask 8: Implement status reporting and PR comment summary

### Description

Build the reporting layer that gives developers clear visibility into what the agent did. The agent produces a structured markdown report and posts it as a PR comment, so developers see results directly in the PR conversation. The report is also uploaded as a GitHub Actions artifact for archival. Following HyperShift's pattern, the report includes token/cost tracking data.

### Acceptance Criteria

1. Produces a markdown summary report containing all of the following sections:
  - **PR Status:** current state, branch, title, URL.
  - **Merge Conflict Status:** if the PR has merge conflicts, prominently flagged as the primary action item. When merge conflicts are detected, CI analysis and auto-fix sections are replaced with a message directing the developer to resolve conflicts first.
  - **CI Check Results:** table of all checks with pass/fail/pending status.
  - **Fixes Applied:** list of auto-fixes with commit SHA, fix type, and files changed.
  - **Review Comments Addressed:** summary of review threads handled.
  - **Infrastructure Flakes:** list of CI jobs classified as infrastructure flakes (timeouts, network errors, registry pull failures) with job names and links. Presented separately from code failures so developers can quickly identify retestable jobs.
  - **Remaining Issues:** items requiring manual intervention, separated into "auto-fixable but blocked by guardrails" vs. "requires human judgment."
  - **Run Summary:** total time elapsed, commit count. (Claude API costs are tracked at the GCP project billing level via Vertex AI, not per-invocation.)
2. Each auto-fix entry includes a clickable link to the commit on GitHub (`https://github.com/{owner}/{repo}/commit/{sha}`).
3. Report is posted as a PR comment via `gh pr comment`. If a previous agent comment exists, it is updated (not duplicated).
4. Report is saved to `$RUNNER_TEMP/pr-agent-report-<owner>-<repo>-<pr-number>.md` and uploaded as a GHA artifact.
5. When `DRY_RUN=true`, the report clearly states it was a dry run and no changes were made.
6. Before pushing any auto-fixes, posts an "in progress" comment (or updates the existing report comment with a "Processing..." header) so developers see context before surprise commits appear on the branch. The final report replaces this in-progress state.
7. On agent crash or failure, a `trap` handler posts a brief error note to the PR comment so developers know the agent attempted but failed.

### Dependencies

Subtasks 2–7 (aggregates data from all other capabilities).

### Implementation Hints

- **Report generation:**
  ```bash
  generate_status_report() {
    local owner="$1" repo="$2" pr_number="$3"
    local report_file="${RUNNER_TEMP}/pr-agent-report-${owner}-${repo}-${pr_number}.md"
    local audit_file="${RUNNER_TEMP}/pr-agent-audit-${GITHUB_RUN_ID:-local}.jsonl"
    local ci_file="${RUNNER_TEMP}/ci-status-${owner}-${repo}-${pr_number}.json"

    local pr_info
    pr_info=$(gh pr view "$pr_number" --repo "${owner}/${repo}" \
      --json title,url,headRefName,baseRefName -q '.')

    local title=$(echo "$pr_info" | jq -r '.title')
    local url=$(echo "$pr_info" | jq -r '.url')
    local head=$(echo "$pr_info" | jq -r '.headRefName')
    local base=$(echo "$pr_info" | jq -r '.baseRefName')

    local passed failed pending
    passed=$(jq '[.[] | select(.bucket == "pass")] | length' "$ci_file")
    failed=$(jq '[.[] | select(.bucket == "fail")] | length' "$ci_file")
    pending=$(jq '[.[] | select(.bucket == "pending")] | length' "$ci_file")

    local fixes_applied
    fixes_applied=$(grep '"action":"auto-fix"' "$audit_file" 2>/dev/null | wc -l || echo 0)

    cat > "$report_file" <<EOF
  ## PR Agent Report: ${repo}#${pr_number}

  **PR:** [${title}](${url})
  **Branch:** \`${head}\` → \`${base}\`
  **Run:** [GHA #${GITHUB_RUN_ID:-N/A}](https://github.com/${GITHUB_REPOSITORY:-}/actions/runs/${GITHUB_RUN_ID:-})
  **Mode:** ${PR_AGENT_MODE:-periodic}
  ${DRY_RUN:+**DRY RUN — no changes were made**}

  ### CI Check Results
  | Status | Count |
  |--------|-------|
  | Passed | ${passed} |
  | Failed | ${failed} |
  | Pending | ${pending} |

  ### Fixes Applied
  $(grep '"action":"auto-fix"' "$audit_file" 2>/dev/null | jq -r '"- [\(.commit)](https://github.com/'${owner}'/'${repo}'/commit/\(.commit)) — `\(.type)`: \(.outcome)"' || echo "- (none)")

  ### Remaining Issues
  $(grep '"action":"blocked\|"action":"skipped"' "$audit_file" 2>/dev/null | jq -r '"- `\(.type)` on \(.files | join(", ")): \(.outcome)"' || echo "- (none)")

  ---
  *Generated by oape-pr-agent on $(date -u +"%Y-%m-%d %H:%M UTC")*
  EOF
  }
  ```
- **Post as PR comment (update if exists):**
  ```bash
  Fire on CI failures for any open PR in this repopost_status_comment() {
    local owner="$1" repo="$2" pr_number="$3"
    local report_file="${RUNNER_TEMP}/pr-agent-report-${owner}-${repo}-${pr_number}.md"
    local marker="<!-- oape-pr-agent-report -->"

    # Check for existing agent comment and load persisted state
    local existing_comment_id existing_body
    existing_comment_id=$(gh api "repos/${owner}/${repo}/issues/${pr_number}/comments" \
      --jq ".[] | select(.body | contains(\"${marker}\")) | .id" | head -1)
    if [[ -n "$existing_comment_id" ]]; then
      existing_body=$(gh api "repos/${owner}/${repo}/issues/comments/${existing_comment_id}" --jq .body)
      # Extract and restore persisted state from previous run
      local persisted_state
      persisted_state=$(echo "$existing_body" | grep -oP '(?<=oape-pr-agent-state:)[A-Za-z0-9+/=]+' | head -1)
      if [[ -n "$persisted_state" ]]; then
        echo "$persisted_state" | base64 -d > "${RUNNER_TEMP}/pr-agent-state-${owner}-${repo}-${pr_number}.json"
      fi
    fi

    # Embed cross-run state in the comment for persistence across GHA runs
    local state_file="${RUNNER_TEMP}/pr-agent-state-${owner}-${repo}-${pr_number}.json"
    local state_block=""
    if [[ -f "$state_file" ]]; then
      local state_b64
      state_b64=$(base64 -w0 < "$state_file")
      state_block="<!-- oape-pr-agent-state:${state_b64} -->"
    fi

    local body="${marker}${state_block}
      $(cat "$report_file")"

    if [[ -n "$existing_comment_id" ]]; then
      gh api "repos/${owner}/${repo}/issues/comments/${existing_comment_id}" \
        -X PATCH -f body="$body"
    else
      gh pr comment "$pr_number" --repo "${owner}/${repo}" --body "$body"
    fi
  }
  ```
- **Reference:** HyperShift's Dependabot Triage Agent generates an HTML report with token usage and cost breakdown. The OAPE report follows the same principle but in markdown.

### Files


| File                         | Action                                                    |
| ---------------------------- | --------------------------------------------------------- |
| `scripts/pr-agent/report.sh` | Create (standalone executable, called by `entrypoint.sh`) |


---

## Subtask 9: PR agent testing and validation

### Description

Add automated testing for the PR agent itself. Since the agent autonomously pushes code to production repositories, it must be validated before deployment. This includes static analysis of bash scripts, a dry-run integration test against a known-state test PR, and a CI workflow that runs validation on every push to this repo.

### Acceptance Criteria

1. All bash scripts in `scripts/pr-agent/*.sh` pass **shellcheck** with zero errors and zero warnings.
2. A **dry-run integration test** script exists that:
  - Creates a test PR in a designated test repository (or uses a pre-existing test PR).
  - Runs the full agent pipeline in `DRY_RUN=true` mode.
  - Verifies: PR discovery finds the test PR, CI status is fetched, failure analysis produces valid JSON, report is generated (but not posted).
  - Exits with a non-zero status if any phase fails.
3. A **CI validation workflow** (`.github/workflows/pr-agent-test.yml`) runs on every push and PR to this repo:
  - Runs shellcheck on all `scripts/pr-agent/*.sh` files.
  - Runs the dry-run integration test.
  - Validates workflow YAML syntax.
4. Test scripts themselves follow shellcheck-clean conventions.

### Dependencies

Subtasks 0–8 (all agent components must exist before they can be tested).

### Implementation Hints

- **Shellcheck in CI:**
  ```yaml
  - name: Lint bash scripts
    run: |
      shellcheck scripts/pr-agent/*.sh
  ```
- **Dry-run integration test:**
  ```bash
  #!/usr/bin/env bash
  set -euo pipefail
  # Run the full agent pipeline against a known test PR in dry-run mode
  export DRY_RUN=true
  export PR_AGENT_MAX_PRS=1

  # Use a pre-existing test PR (created once, kept open for testing)
  TEST_PR_URL="${TEST_PR_URL:-https://github.com/openshift-eng/oape-ai-e2e/pull/1}"

  scripts/pr-agent/entrypoint.sh --mode on-demand --pr-url "$TEST_PR_URL"

  # Verify outputs were generated (owner-repo-pr_number naming convention)
  [[ -f "${RUNNER_TEMP}/ci-status-openshift-eng-oape-ai-e2e-1.json" ]] || { echo "FAIL: CI status not generated"; exit 1; }
  [[ -f "${RUNNER_TEMP}/pr-agent-report-openshift-eng-oape-ai-e2e-1.md" ]] || { echo "FAIL: Report not generated"; exit 1; }

  echo "PASS: Dry-run integration test completed successfully"
  ```
- **Workflow YAML validation:**
  ```bash
  # Use actionlint for GHA workflow syntax validation
  actionlint .github/workflows/periodic-pr-agent.yml .github/workflows/on-demand-pr-agent.yml
  ```

### Files


| File                                  | Action |
| ------------------------------------- | ------ |
| `.github/workflows/pr-agent-test.yml` | Create |
| `scripts/pr-agent/test-dry-run.sh`    | Create |


---

## Subtask 10: Create `/oape:pr-agent` command

### Description

Create a Claude Code command that serves as the **interactive/developer** entry point for the PR agent, following the pattern of all existing OAPE commands (`/oape:review`, `/oape:init`, etc.). This command is for developers running the agent locally in their terminal — the GHA workflow calls `scripts/pr-agent/entrypoint.sh` directly (deterministic, no Claude orchestration overhead). This separation ensures the CI path is fast and predictable, while the interactive path provides a richer developer experience.

### Acceptance Criteria

1. A command file exists at `plugins/oape/commands/pr-agent.md` following the project's command pattern (frontmatter with `description` and `argument-hint`, Synopsis, Description, Arguments, Implementation sections).
2. Accepts a PR URL as the primary argument.
3. Supports flags: `--dry-run` (no modifications), `--auto-fix` (default true).
4. Prompts the user before pushing fixes, displays status inline, and offers to monitor the PR on a schedule (via `CronCreate`).
5. Delegates to the same bash scripts (`ci-monitor.sh`, `auto-fix.sh`, etc.) used by the GHA workflow, ensuring parity between interactive and CI execution.
6. The CLAUDE.md command table is updated to include `/oape:pr-agent`.
7. **Note:** The GHA workflow (`pr-agent-shared.yml`) calls `scripts/pr-agent/entrypoint.sh` directly — it does NOT invoke this command. This command is for developer use only.

### Dependencies

Subtasks 1–8 (the command wraps all existing capabilities).

### Implementation Hints

- **Command frontmatter pattern** (follow `plugins/oape/commands/review.md`):
  ```markdown
  ---
  description: Monitor a PR, auto-fix trivial CI failures, address review comments, and report status
  argument-hint: <PR-URL> [--dry-run] [--auto-fix]
  ---
  ```
- **Interactive monitoring** uses `CronCreate` for periodic re-checks (like yolo-agent's interactive mode):
  ```
  After the initial pass, offer: "Would you like me to keep monitoring this PR?"
  If yes, schedule a one-shot CronCreate to re-run the analysis in 5 minutes.
  ```
- **GHA path is separate:** The GHA workflow (`pr-agent-shared.yml`) calls `scripts/pr-agent/entrypoint.sh` directly — it does not use this command. This keeps the CI path deterministic and avoids Claude orchestration overhead.

### Files


| File                                | Action |
| ----------------------------------- | ------ |
| `plugins/oape/commands/pr-agent.md` | Create |


---

## Data Flow and Security

### Authentication


| System              | Method                                         | Details                                                                                                                                                                                        |
| ------------------- | ---------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| GitHub (read/write) | GitHub App token                               | Generated via `actions/create-github-app-token@v1`. Required for push (avoids `GITHUB_TOKEN` anti-recursion). App needs `contents: write`, `pull-requests: write`, `checks: read` permissions. |
| Claude API          | GCP Workload Identity Federation via Vertex AI | `CLAUDE_CODE_USE_VERTEX=1`, `ANTHROPIC_VERTEX_PROJECT_ID`. Authentication via `google-github-actions/auth@v2` using Workload Identity Federation (no service account key needed).              |
| GitHub (CI logs)    | Same GitHub App token                          | Used via `gh` CLI for `gh run view --log-failed` and `gh api` calls.                                                                                                                           |


### Data Retention

- No persistent storage beyond PR comments and GHA artifacts.
- Audit logs retained for 30 days as GHA artifacts.
- No secrets are logged — the audit log contains only file paths, commit SHAs, and action outcomes.

### Data Flow: Periodic PR Agent

```
┌─────────────────────────────────────────────────────────────────┐
│  GitHub Actions Runner (periodic-pr-agent, cron: every 1h)     │
│                                                                 │
│  ┌──────────┐    ┌──────────────┐    ┌──────────────────────────┐│
│  │ Setup    │───▶│ Discover PRs │───▶│ For each PR:             ││
│  │ (tools,  │    │ (gh pr list  │    │  0. Check merge conflicts││
│  │  auth)   │    │  per repo,   │    │  1. Fetch CI (gh pr chk) ││
│  └──────────┘    │  skip label  │    │  2. Classify (regex+LLM) ││
│                  │  filter)     │    │  3. Auto-fix trivial     ││
│                  └──────────────┘    │  4. Address reviews      ││
│                                      │  5. Post report          ││
│                                      └──────────┬───────────────┘│
│                                                  │              │
│  ┌──────────────────┐                           │              │
│  │ Upload artifacts │◀──────────────────────────┘              │
│  │ (audit log,      │                                          │
│  │  reports)        │                                          │
│  └──────────────────┘                                          │
└─────────────────────────────────────────────────────────────────┘
        │                    │                    │
        ▼                    ▼                    ▼
   ┌─────────┐      ┌──────────────┐     ┌──────────────┐
   │ GitHub  │      │ Claude API   │     │ Target Repos │
   │ API     │      │ (Vertex AI)  │     │ (push fixes, │
   │ (PRs,   │      │              │     │  post        │
   │  checks)│      │              │     │  comments)   │
   └─────────┘      └──────────────┘     └──────────────┘
```

### Data Flow: On-Demand PR Agent

```
┌──────────────────────────────────────────────────────────────────┐
│  Target Repo (e.g., cert-manager-operator)                       │
│  ┌──────────────────────────────────┐                            │
│  │ oape-pr-agent-trigger.yml        │                            │
│  │ Listens: check_run + status      │──── repository_dispatch ──▶│
│  │ Filters: all open PRs             │                            │
│  └──────────────────────────────────┘                            │
└──────────────────────────────────────────────────────────────────┘
                                                     │
                                                     ▼
┌─────────────────────────────────────────────────────────────────┐
│  GitHub Actions Runner (on-demand-pr-agent, oape-ai-e2e repo)   │
│                                                                 │
│  Trigger: repository_dispatch(pr_url) ← from target repo       │
│           workflow_dispatch(pr_url)    ← manual                 │
│                                                                 │
│  ┌──────────┐    ┌───────────────────┐    ┌─────────────────┐  │
│  │ Shared   │───▶│ Parse PR URL      │───▶│ Process PR      │  │
│  │ setup    │    │ (from dispatch    │    │ (same phases    │  │
│  │ (reuse)  │    │  payload or input)│    │  as periodic)   │  │
│  └──────────┘    └───────────────────┘    └────────┬────────┘  │
│                                                     │           │
│  ┌──────────────────┐                              │           │
│  │ Upload artifacts │◀─────────────────────────────┘           │
│  └──────────────────┘                                          │
└─────────────────────────────────────────────────────────────────┘
```

---

## Configuration


| Variable              | Default                                                                      | Description                                                                                                              |
| --------------------- | ---------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------ |
| `BOT_USER`            | `oape-bot[bot]`                                                              | Git identity used for bot commits. Also used to detect bot's own replies in review threads (skip re-responding to self). |
| `PR_AGENT_MAX_PRS`    | `4`                                                                          | Maximum PRs to process per periodic run (kept low to stay within 1-hour GitHub App token TTL)                            |
| `MAX_BUDGET_PER_PR`   | `5.00`                                                                       | Maximum dollar amount to spend on Claude API per PR (passed to `--max-budget-usd`)                                       |
| `MAX_COMMITS_PER_RUN` | `10`                                                                         | Maximum total commits across all PRs in a single run                                                                     |
| `MAX_COMMITS_PER_PR`  | `3`                                                                          | Maximum commits per individual PR processing                                                                             |
| `MAX_DIFF_LINES`      | `500`                                                                        | Maximum lines changed by a single auto-fix before aborting                                                               |
| `PR_TIMEOUT_SECONDS`  | `720`                                                                        | Maximum seconds to spend processing a single PR (12 min). On timeout, posts partial report and continues.                |
| `DRY_RUN`             | `false`                                                                      | When `true`, skips all file modifications, commits, and pushes                                                           |
| `SKIP_USERS`          | `openshift-ci,openshift-bot,dependabot,codecov,sonarcloud,coderabbitai[bot]` | Comma-separated list of users whose comments are skipped                                                                 |
| `RATE_LIMIT_SECONDS`  | `60`                                                                         | Delay between processing PRs in periodic mode                                                                            |
| `RETEST_INFRA_FLAKES` | `false`                                                                      | (Phase 2) When `true`, posts targeted `/test <job-name>` for infrastructure flakes. Max 2 retests per job per run.       |
| `GCSWEB_BASE_URL`     | `https://gcsweb-ci.apps.ci.l2s4.p1.openshiftapps.com`                        | Base URL for OpenShift CI gcsweb (Prow log fetching). Update if CI infrastructure migrates.                              |


### Required Secrets


| Secret                           | Purpose                                                                                                                                       |
| -------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------- |
| `OAPE_APP_ID`                    | GitHub App ID for generating push tokens                                                                                                      |
| `OAPE_APP_PRIVATE_KEY`           | GitHub App private key (PEM format)                                                                                                           |
| `GCP_PROJECT_ID`                 | GCP project ID for Vertex AI                                                                                                                  |
| `GCP_WORKLOAD_IDENTITY_PROVIDER` | GCP Workload Identity Provider resource name (e.g., `projects/PROJECT_NUMBER/locations/global/workloadIdentityPools/POOL/providers/PROVIDER`) |
| `GCP_SERVICE_ACCOUNT`            | GCP service account email for Vertex AI access (e.g., `oape-ci@project.iam.gserviceaccount.com`)                                              |
| `OAPE_DISPATCH_TOKEN`            | (Target repos only) GitHub token with `repo` scope on `openshift-eng/oape-ai-e2e` for sending `repository_dispatch` events                    |


---

## Limitations

- **AI may produce incorrect or incomplete solutions** — all fixes pushed by the agent must be reviewed by repository OWNERS before merging.
- **Complex issues may not be fully addressed** — multi-faceted build errors, test failures, and architectural issues require human intervention.
- **Rate limited**: 4 PRs per periodic run (configurable via `PR_AGENT_MAX_PRS`), 100 agentic turns per PR.
- **Cannot access private resources** — no access to internal systems beyond GitHub and Jira.
- **Cannot execute destructive operations** — no ability to force-push, rebase, or delete branches. Enforced via `--allowedTools` restrictions on Claude CLI invocations.
- **Concurrent processing race** — a periodic run and an on-demand run could process the same PR simultaneously. The consequence is duplicate work (not data loss): both runs may analyze the same failures and attempt the same fixes, with the second push either succeeding (identical fix) or gracefully failing (conflict detected by `git pull --rebase`). State persistence uses last-writer-wins, which may cause already-addressed comments to be re-analyzed on the next run.
- **GitHub Actions timeout** — workflow `timeout-minutes: 55` to stay within the 1-hour GitHub App token TTL.
- **Token expiry** — GitHub App tokens are valid for 1 hour. The 55-minute timeout and 4-PR limit ensure processing completes within this window.
- **Cost** — deterministic classification handles ~80-90% of cases without Claude API cost. Claude Code is invoked only for `unknown` failures and review comment handling. The periodic job processes up to 4 PRs per run.
- **Target repo trigger installation** — the on-demand trigger workflow (`oape-pr-agent-trigger.yml`) must be installed in each target repo. Requires approval from target repo maintainers and a `OAPE_DISPATCH_TOKEN` secret.

---

## Monitoring and Effectiveness

### Performance Monitoring

- **GitHub Actions logs**: View at `Actions` tab → `periodic-pr-agent` / `on-demand-pr-agent` workflows.
- **Audit artifacts**: Download from the workflow run's artifacts tab (30-day retention).
- Track job success/failure rates via GitHub Actions workflow run history.

### Metrics and Indicators


| Metric                   | Description                                          |
| ------------------------ | ---------------------------------------------------- |
| PRs processed per run    | Number of PRs successfully analyzed per periodic run |
| Auto-fixes applied       | Count of trivial CI failures automatically resolved  |
| Review threads addressed | Count of review comments handled by the agent        |
| Fix success rate         | Percentage of auto-fixes that pass subsequent CI     |
| Time to CI-green         | Duration from PR creation to all checks passing      |


### Periodic Review Process

The OAPE team should conduct monthly reviews:

- Review auto-fix commits for quality and correctness.
- Track false positives (agent applied a fix that was wrong) and false negatives (agent missed a trivial fix).
- Adjust classification heuristics in the `ci-failure-analysis` skill based on results.
- Monitor Claude API costs and adjust `MAX_BUDGET_PER_PR` if needed.
- Review safety guardrail effectiveness — are blocked patterns correct? Are commit limits appropriate?

---

## Summary


| #   | Subtask                                                                                                         | Type                   | Effort Estimate |
| --- | --------------------------------------------------------------------------------------------------------------- | ---------------------- | --------------- |
| 0   | GitHub Actions CI infrastructure + target repo trigger workflow                                                 | GHA Workflows + Script | Medium          |
| 1   | Create entrypoint script with PR discovery, prechecks, merge conflict detection, skip label, and state tracking | Script                 | Medium          |
| 2   | Implement CI check monitoring via `gh pr checks`                                                                | Script                 | Medium          |
| 3   | Implement CI failure log analysis with deterministic classification + Claude fallback                           | Script + Skill         | Large           |
| 4   | Implement trivial auto-fix engine with blobless clone, pre/post blocklist, global commit counter                | Script                 | Large           |
| 5   | Implement review comment monitoring and response with `--allowedTools` restrictions                             | Script + Claude Code   | Medium          |
| 6   | Wire together the PR processing pipeline (standalone scripts)                                                   | Script                 | Small           |
| 7   | Implement safety guardrails and file-modification boundaries (sourced utility library, no dependencies)         | Script + Skill         | Medium          |
| 8   | Implement status reporting with merge conflict section and PR comment summary                                   | Script                 | Medium          |
| 9   | PR agent testing and validation                                                                                 | GHA Workflow + Script  | Small           |
| 10  | Create `/oape:pr-agent` command                                                                                 | Command                | Small           |


### Files Created


| File                                               | Purpose                                                                                                               |
| -------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------- |
| `.github/workflows/pr-agent-shared.yml`            | Reusable workflow with shared setup (tools, auth, artifacts), timeout: 55 min                                         |
| `.github/workflows/periodic-pr-agent.yml`          | Periodic scanner workflow (cron every 1h weekdays, calls shared)                                                      |
| `.github/workflows/on-demand-pr-agent.yml`         | On-demand per-PR workflow (`workflow_dispatch` + `repository_dispatch`, calls shared)                                 |
| `.github/workflows/oape-pr-agent-trigger.yml`      | Lightweight trigger workflow template for installation in target repos (listens for `check_run`/`status` failures)    |
| `.github/workflows/pr-agent-test.yml`              | CI validation workflow (shellcheck, dry-run test)                                                                     |
| `scripts/pr-agent/entrypoint.sh`                   | Main orchestration script (both modes, merge conflict check, skip label filter, state tracking)                       |
| `scripts/pr-agent/setup-tools.sh`                  | Tool installation (Go, goimports, golangci-lint, Claude CLI)                                                          |
| `scripts/pr-agent/ci-monitor.sh`                   | CI check fetching via `gh pr checks` and status aggregation (standalone executable)                                   |
| `scripts/pr-agent/log-analyzer.sh`                 | Log fetching + deterministic classification + Claude fallback for unknowns (standalone executable)                    |
| `scripts/pr-agent/auto-fix.sh`                     | Trivial fix application with blobless clone, pre/post blocklist checks, global commit counter (standalone executable) |
| `scripts/pr-agent/review-handler.sh`               | Review comment analysis and Claude Code invocation with `--allowedTools` restrictions (standalone executable)         |
| `scripts/pr-agent/safety.sh`                       | Blocklists (category-aware go.sum exception), commit limits, audit logging, retry helper (sourced utility library)    |
| `scripts/pr-agent/report.sh`                       | Status report generation with merge conflict section and PR comment posting (standalone executable)                   |
| `scripts/pr-agent/test-dry-run.sh`                 | Dry-run integration test script                                                                                       |
| `plugins/oape/skills/ci-failure-analysis/SKILL.md` | Claude Code skill for failure classification (content included via `cat` in prompts)                                  |
| `plugins/oape/skills/pr-agent-safety/SKILL.md`     | Safety guardrails skill (content included via `cat` in prompts)                                                       |
| `plugins/oape/commands/pr-agent.md`                | `/oape:pr-agent` command for interactive developer use (GHA uses `entrypoint.sh` directly)                            |


### User Guide

#### Viewing Agent Output

Track PRs processed by the agent:

- **Periodic runs**: `Actions` tab → `periodic-pr-agent` workflow
- **Agent comments**: Look for comments containing `<!-- oape-pr-agent-report -->` on PRs in allowed repos
- **Audit logs**: Download from workflow run artifacts

#### Triggering On-Demand

The agent triggers automatically on CI failure via target repo trigger workflows, or manually:

1. **Automatic (primary)**: Lightweight trigger workflow in the target repo detects `check_run`/`status` failure on any open PR and dispatches to `oape-ai-e2e` via `repository_dispatch`
2. **Via GitHub UI**: `Actions` → `on-demand-pr-agent` → `Run workflow` → enter PR URL
3. **Via CLI**: `gh workflow run on-demand-pr-agent.yml -f pr_url=https://github.com/org/repo/pull/123`

#### Skipping a PR

To exclude a PR from automated processing, add the `pr-agent:skip` label. The periodic scanner and on-demand triggers will skip PRs with this label.

#### Reprocessing

The agent maintains lightweight state across runs via the PR report comment (tracking which CI jobs have been analyzed and which review comments have been addressed). On each run, already-processed items are skipped to avoid duplicate work. To force a full reprocessing of a PR, delete the agent's report comment (containing `<!-- oape-pr-agent-report -->`) from the PR, then trigger another run. The periodic scanner will pick it up on the next cycle, or use on-demand triggering.

---

## Implementation Phasing

The subtasks above describe the full target architecture (17 files). Implementation is phased to deliver value incrementally and validate the approach before investing in the full design.

### Phase 1: MVP — GHA CI Monitor in Target Repos (Report-Only)

**Goal**: Prove the concept by adding a GitHub Actions workflow to target repos that monitors CI and reports failures. The workflow triggers on GitHub `status` events — each time a Prow or GHA job completes, the workflow fires, checks if ALL checks are now terminal, and only runs the full analysis once everything is done. No idle polling, no wasted runner minutes. `dispatch.sh` then logs planned next-step actions (no-op in Phase 1, real invocations in Phase 2+). No auto-fix, no review comment handling, no Claude dependency. No container images.

**Architecture**: Each target repo adds a `.github/workflows/oape-ci-monitor.yml` (copied from `docs/target-repo-ci-monitor.yml`). Triggered by `status` events, the workflow gates on "all checks complete" before cloning oape-ai-e2e and running the analysis. Typical latency: analysis starts within ~30s of the last CI job finishing.

```
Prow/GHA job finishes → GitHub fires status event
  → GHA triggers oape-ci-monitor workflow
  → Gate step: finds PR for commit, checks if all checks are terminal
  → If checks still pending → exits in seconds (no work done)
  → If all complete → clones oape-ai-e2e from GitHub
  → monitor.sh: polls gh pr checks → collects GCS artifacts → classifies → Sippy → report → result JSON
  → dispatch.sh: reads result JSON → logs planned actions (Phase 1) / invokes auto-fix, Claude, /retest (Phase 2+)
```

| File                                        | Purpose                                                                                                                                         | Maps to Subtasks  |
| ------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------- | ----------------- |
| `scripts/ci-monitor/monitor.sh`             | CI monitor: polls checks, collects GCS artifacts, classifies failures, queries Sippy, generates report, posts comment, writes result JSON        | 2, 3 (partial)    |
| `scripts/ci-monitor/dispatch.sh`            | Failure dispatch: reads result JSON, logs planned actions (Phase 1), invokes further oape-ai-e2e tools on failure (Phase 2+)                     | 6 (partial)       |
| `docs/target-repo-ci-monitor.yml`           | GHA workflow template that target repos copy into `.github/workflows/oape-ci-monitor.yml`                                                       | 0 (partial)       |
| `.github/workflows/pr-agent-test.yml`       | shellcheck + syntax validation for `scripts/pr-agent/`, `scripts/ci-monitor/`, and the workflow template                                        | 9 (partial)       |

**Scope**: Report-only CI monitoring via a GHA workflow in each target repo. First target repo: must-gather-operator. The workflow uses GitHub `status` event triggers with a gate step that exits in seconds if checks are still pending — no idle polling or wasted runner minutes. Once all checks are terminal, it clones oape-ai-e2e and runs `monitor.sh` (with `SKIP_POLL=true`) which fetches `gh pr checks`, collects `build-log.txt` from GCS for failed Prow jobs, classifies failures into categories (`install-failure`, `test-failure`, `build-failure`, `lint-failure`, `infra-flake`, `unknown`), queries Sippy for flake history, and posts a structured markdown report on the PR. A machine-readable JSON result (`ci-monitor-result.json`) includes suggested trigger actions (retest, auto-fix-lint, investigate). `dispatch.sh` reads this result and logs planned actions — in Phase 1 these are no-ops, in Phase 2+ they become real invocations of oape-ai-e2e tools.

**Phase 1 enhancements (from PR #60 analysis):**
- **Release repo discovery**: `monitor.sh` fetches the ci-operator config from `openshift/release` for the target repo/branch, providing authoritative job metadata (required/optional, cluster_profile, OCP release version). Falls back to name-based heuristics if unavailable.
- **Non-test context exclusions**: Filters out non-CI contexts (`tide`, `Mergeable`, `DCO`, `CodeRabbit`, `stale`, `sonarcloud`, `codecov`) that should never be counted as failures.
- **Expanded failure patterns**: Infra-flake detection includes `registry.ci.openshift.org` errors, `etcdserver` timeouts, lease failures, cloud quota errors, `dial tcp` timeouts. Install-failure detection includes `level=fatal.*installer`, `bootstrapComplete` waits.
- **Dynamic Sippy release version**: Resolves OCP version from ci-operator config (`releases.latest.release.version`) or Prow job name pattern, providing accurate flake data per release.
- **Prow Job Breakdown table**: Report includes a table of ALL checks (pass/fail) with state, category, required/optional status, flake%, and recommended action.

**Retained for future phases**: The PR agent scripts (`scripts/pr-agent/entrypoint.sh`, `safety.sh`) are retained as the foundation for `dispatch.sh` to invoke in Phase 2+. Since the workflow clones the full oape-ai-e2e repo, all tools are available at runtime.

### Phase 2: Auto-Fix + Claude Intelligence

**Goal**: Add CI-triggered auto-fix for trivial failures, Claude-powered analysis for unknown failures, and auto-retest for confirmed flakes. The CI monitor's `trigger_actions` output from Phase 1 drives dispatch. Incorporate context-aware analysis patterns from PR #60's ci-monitor skill.

| File                                               | Purpose                                                                                                 | Maps to Subtasks |
| -------------------------------------------------- | ------------------------------------------------------------------------------------------------------- | ---------------- |
| `.github/workflows/ci-monitor-dispatch.yml`        | GHA workflow triggered by ci-monitor result: dispatches auto-fix, retest, or Claude analysis            | 0 (partial)      |
| `scripts/pr-agent/auto-fix.sh`                     | Extracted auto-fix engine: `go fmt`, `goimports`, `make generate`, scoped to PR-changed files           | 4                |
| `scripts/pr-agent/log-analyzer.sh`                 | Deterministic + Claude fallback classification for `unknown` failures                                   | 3                |
| `plugins/oape/skills/ci-failure-analysis/SKILL.md` | Claude skill for unknown failure classification (reference: PR #60's `plugins/oape/skills/ci-monitor/SKILL.md`) | 3                |
| `scripts/pr-agent/safety.sh`                       | Retained guardrails: blocklist, audit log, commit limits, diff size guard                               | 7                |

**Scope adds**: Auto-fix for `lint-failure` and `build-failure` categories, auto-retest (`/retest`) for `infra-flake`, Claude Code CLI fallback for `unknown` failures, dispatch workflow that reads `ci-monitor-result.json` and takes action.

**Learnings from PR #60 to incorporate in Phase 2:**

- **Auto-retest protocol**: When ALL failures on a PR are infra-flake (Mode E), `dispatch.sh` posts `/retest` automatically (max 2 per session). Only triggers when every failure is infrastructure-related. Disable with `--no-auto-retest`. Each auto-retest is logged in the report with timestamp, affected contexts, and outcome.

- **On-demand PR diff fetch**: When a build/test failure references a specific file, fetch the diff for that file only (`gh pr diff $PR -- $FILE`) to correlate the error with the actual code change. Only fetch for files in `PR_CHANGED_FILES` — if the error is in a file not changed by the PR, flag it as a dependency or generated-code issue.

- **Error signature hashing**: Normalize error messages (strip timestamps, line numbers, hex addresses `0x[a-f0-9]+`, UUIDs `[a-f0-9-]{36}`, temp paths `/tmp/[^ ]+`), then SHA-256 hash. Track `context_name -> error_hash` per fix round. If >= 75% of failed contexts share the same hash as the previous round, the fix was ineffective — stop the fix loop.

- **Root cause tracing protocol**: Step-by-step diagnostic decision tree for each failure:
  1. Does the error reference a specific file? Is it in `PR_CHANGED_FILES`? → PR likely introduced the issue.
  2. Is it about a missing tool, command, or image? → Check ci-operator config's `container.from` or step `from:` image.
  3. Is it about authentication/credentials? → Check ci-operator `credentials` entries (Vault-injected, declared in `openshift/release`).
  4. Is it transient/environmental (network, quota, lease)? → Recommend `/retest`.
  5. Is it about missing generated code (`zz_generated.deepcopy.go`, CRD YAML)? → Check if `_types.go` changed but generated files weren't updated.
  6. None of the above → Report with all available evidence, confidence: low.
  Each step cites concrete artifacts (log line, file path, config entry). Output format: numbered trace steps, fix location, fix owner, confidence level.

- **PR change context**: Fetch changed files list per PR (`gh pr view --json files`). Classify change types: API (`_types.go`), controller (`controller|reconcil*.go`), test (`_test.go`), CRD (`crd/*.yaml`), RBAC (`rbac*.yaml`). Used for error-to-file correlation and stage-aware summary.

- **Operator repo context**: Detect operator framework from `go.mod` (`sigs.k8s.io/controller-runtime` vs `github.com/openshift/library-go`). Detect Makefile presence, test directories. Used for targeted fix suggestions and local verification commands.

- **Step registry resolution**: For failed Prow jobs with multi-stage steps, resolve step refs from `openshift/release` step registry (`ci-operator/step-registry/`). Maps "e2e-aws failed" to "step `openshift-e2e-test` failed, running `openshift-tests run openshift/conformance/parallel`". Resolved on demand only for failed jobs (saves API calls).

- **Optional job severity**: Jobs marked `optional: true` in ci-operator config should never be labeled as "Blocker" or "Critical". Label as "Non-blocking (optional)" regardless of failure mode. Optional job failures should not change the PR's overall verdict from PASS to FAIL.

### Phase 3: Review Comments + Full Design

**Goal**: Complete the target architecture with review comment handling, the `/oape:pr-agent` command, and rollout to all target repos.

| File                                           | Purpose                                                                                    | Maps to Subtasks |
| ---------------------------------------------- | ------------------------------------------------------------------------------------------ | ---------------- |
| `scripts/pr-agent/review-handler.sh`           | Review comment monitoring/response with restricted `--allowedTools`                         | 5                |
| `scripts/pr-agent/report.sh`                   | Extracted reporting logic (unified for CI monitor + PR agent)                               | 8                |
| `plugins/oape/skills/pr-agent-safety/SKILL.md` | Safety rules skill for Claude                                                              | 7                |
| `plugins/oape/commands/pr-agent.md`            | `/oape:pr-agent` command for interactive + headless use                                    | 10               |

**Scope adds**: Review comment handling, `/oape:pr-agent` command, rollout of `oape-ci-monitor` to all repos in `team-repos.csv`, full test suite.

---

## Support and Feedback

- **Slack channel**: #oape-support
- **Feedback**: File issues with label `pr-agent-feedback`
- **Urgent issues**: Contact OAPE team directly

