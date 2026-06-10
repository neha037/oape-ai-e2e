#!/usr/bin/env bash
# dispatch.sh — Reads ci-monitor-result.json and invokes further oape-ai-e2e
# tools based on the failure classification.
#
# Phase 1: Logs planned actions without executing them.
# Phase 2+: Branches will invoke auto-fix, Claude analysis, /retest, etc.
#
# This script is the bridge between "CI monitoring" (monitor.sh) and
# "further processing" (auto-fix, Claude, retest). It runs immediately
# after monitor.sh in the same CI job, with the oape-ai-e2e repo cloned
# and available at OAPE_ROOT.
#
# Required environment:
#   RESULT_FILE  — Path to ci-monitor-result.json (default: /tmp/ci-monitor-result.json)
#
# Optional environment:
#   OAPE_ROOT    — Root of the cloned oape-ai-e2e repo (default: /app)
#   DRY_RUN      — If "true", never execute real actions even in Phase 2+
#   PHASE        — Override dispatch phase (default: "1")

set -euo pipefail

RESULT_FILE="${RESULT_FILE:-/tmp/ci-monitor-result.json}"
OAPE_ROOT="${OAPE_ROOT:-/app}"
DRY_RUN="${DRY_RUN:-false}"
PHASE="${PHASE:-1}"

# ---------------------------------------------------------------------------
# Prechecks
# ---------------------------------------------------------------------------
if [[ ! -f "$RESULT_FILE" ]]; then
  echo "[dispatch] No result file found at ${RESULT_FILE} — nothing to dispatch"
  exit 0
fi

if ! command -v jq &>/dev/null; then
  echo "[dispatch] ERROR: jq is not installed" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Read result
# ---------------------------------------------------------------------------
OVERALL_STATUS=$(jq -r '.overall_status' "$RESULT_FILE")
TRIGGER_COUNT=$(jq '.trigger_actions | length' "$RESULT_FILE")
PR_URL=$(jq -r '.pr_url' "$RESULT_FILE")
OWNER=$(jq -r '.owner' "$RESULT_FILE")
REPO=$(jq -r '.repo' "$RESULT_FILE")
PR_NUMBER=$(jq -r '.pr_number' "$RESULT_FILE")

echo "============================================"
echo "  OAPE CI Monitor — Dispatch"
echo "  PR: ${PR_URL}"
echo "  Status: ${OVERALL_STATUS}"
echo "  Trigger Actions: ${TRIGGER_COUNT}"
echo "  Phase: ${PHASE}"
echo "  Dry Run: ${DRY_RUN}"
echo "============================================"

# ---------------------------------------------------------------------------
# If all passed, nothing to dispatch
# ---------------------------------------------------------------------------
if [[ "$OVERALL_STATUS" == "passed" ]]; then
  echo "[dispatch] All CI checks passed — no further action needed"
  exit 0
fi

if [[ "$TRIGGER_COUNT" -eq 0 ]]; then
  echo "[dispatch] No trigger actions in result — nothing to dispatch"
  exit 0
fi

# ---------------------------------------------------------------------------
# Dispatch each action
# ---------------------------------------------------------------------------
echo "[dispatch] Processing ${TRIGGER_COUNT} trigger action(s)..."
echo ""

jq -c '.trigger_actions[]' "$RESULT_FILE" | while IFS= read -r entry; do
  action=$(echo "$entry" | jq -r '.action')
  job=$(echo "$entry" | jq -r '.job')

  echo "[dispatch] Action: ${action} | Job: ${job}"

  case "$action" in

    # --- Retest: post /retest for infra flakes ---
    retest)
      if [[ "$PHASE" == "1" ]]; then
        echo "  -> Phase 1: Would post /retest for ${job} (not executed)"
      else
        echo "  -> Posting /retest for infra-flake: ${job}"
        if [[ "$DRY_RUN" != "true" ]]; then
          # Phase 2+: uncomment to enable
          # gh pr comment "$PR_NUMBER" --repo "${OWNER}/${REPO}" \
          #   --body "/retest" 2>/dev/null || true
          echo "  -> (auto-retest not yet enabled)"
        else
          echo "  -> DRY RUN: Would post /retest"
        fi
      fi
      ;;

    # --- Auto-fix for lint failures ---
    auto-fix-lint)
      if [[ "$PHASE" == "1" ]]; then
        echo "  -> Phase 1: Would run auto-fix for lint failure on ${job} (not executed)"
      else
        auto_fix_script="${OAPE_ROOT}/scripts/pr-agent/auto-fix.sh"
        if [[ -x "$auto_fix_script" ]]; then
          echo "  -> Running auto-fix for lint failure: ${job}"
          if [[ "$DRY_RUN" != "true" ]]; then
            "$auto_fix_script" --pr-url "$PR_URL" --category lint-failure || true
          else
            echo "  -> DRY RUN: Would run ${auto_fix_script}"
          fi
        else
          echo "  -> Auto-fix script not available at ${auto_fix_script} (Phase 2+)"
        fi
      fi
      ;;

    # --- Investigate: Claude analysis for complex failures ---
    investigate)
      if [[ "$PHASE" == "1" ]]; then
        echo "  -> Phase 1: Would invoke Claude analysis for ${job} (not executed)"
      else
        echo "  -> Claude analysis requested for: ${job}"
        if [[ "$DRY_RUN" != "true" ]]; then
          # Phase 2+: invoke Claude Code CLI or analysis script
          # "${OAPE_ROOT}/scripts/pr-agent/log-analyzer.sh" \
          #   --pr-url "$PR_URL" --job "$job" || true
          echo "  -> (Claude analysis not yet enabled)"
        else
          echo "  -> DRY RUN: Would invoke Claude analysis"
        fi
      fi
      ;;

    *)
      echo "  -> Unknown action: ${action} — skipping"
      ;;
  esac

  echo ""
done

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo "[dispatch] Dispatch complete"

CATEGORY_SUMMARY=$(jq -r '
  .failure_categories
  | to_entries
  | map("\(.key): \(.value)")
  | join(", ")' "$RESULT_FILE")

echo "[dispatch] Failure categories: ${CATEGORY_SUMMARY}"

if [[ "$PHASE" == "1" ]]; then
  echo "[dispatch] Phase 1 mode — all actions logged but not executed"
  echo "[dispatch] To enable actions, set PHASE=2 (requires Phase 2 scripts)"
fi
