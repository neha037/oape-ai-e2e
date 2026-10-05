#!/usr/bin/env bash
# log-analyzer.sh — Claude-powered failure analysis for the OAPE CI Monitor.
#
# Reads CI log files, runs deterministic regex classification first, then
# invokes Claude Code CLI for failures that remain "unknown". Called by
# dispatch.sh for the "investigate" action.
#
# Usage:
#   log-analyzer.sh --pr-url <URL> --log-dir <path> [options]
#
# Required:
#   --pr-url <URL>       PR URL (https://github.com/OWNER/REPO/pull/N)
#   --log-dir <path>     Directory containing CI log files (log-*.txt)
#
# Optional:
#   --job <name>         Specific Prow job name to analyze
#   --result-file <path> Path to ci-monitor-result.json (for PR context)
#   --dry-run            Show what would be done without invoking Claude

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OAPE_ROOT="${OAPE_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"

# shellcheck source=scripts/pr-agent/safety.sh
source "${SCRIPT_DIR}/safety.sh"
# shellcheck source=scripts/pr-agent/classify.sh
source "${SCRIPT_DIR}/classify.sh"

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
DRY_RUN="${DRY_RUN:-false}"
MAX_BUDGET_PER_PR="${MAX_BUDGET_PER_PR:-5.00}"
MAX_LOG_LINES="${MAX_LOG_LINES:-1000}"
SKILL_FILE="${OAPE_ROOT}/plugins/oape/skills/ci-monitor/SKILL.md"
CURRENT_PR_URL=""

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
usage() {
  echo "Usage: log-analyzer.sh --pr-url <URL> --log-dir <path> [--job <name>] [--result-file <path>] [--dry-run]"
  exit 1
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
PR_URL_ARG=""
LOG_DIR=""
JOB_NAME=""
RESULT_FILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pr-url)      PR_URL_ARG="$2"; shift 2 ;;
    --log-dir)     LOG_DIR="$2"; shift 2 ;;
    --job)         JOB_NAME="$2"; shift 2 ;;
    --result-file) RESULT_FILE="$2"; shift 2 ;;
    --dry-run)     DRY_RUN="true"; shift ;;
    --help|-h)     usage ;;
    *)             echo "[log-analyzer] ERROR: Unknown argument: $1" >&2; usage ;;
  esac
done

if [[ -z "$PR_URL_ARG" ]]; then
  echo "[log-analyzer] ERROR: --pr-url is required" >&2
  usage
fi

if [[ -z "$LOG_DIR" ]]; then
  echo "[log-analyzer] ERROR: --log-dir is required" >&2
  usage
fi

# ---------------------------------------------------------------------------
# Parse PR URL
# ---------------------------------------------------------------------------
OWNER=""
REPO=""
PR_NUMBER=""

if [[ "$PR_URL_ARG" =~ https://github.com/([^/]+)/([^/]+)/pull/([0-9]+) ]]; then
  OWNER="${BASH_REMATCH[1]}"
  REPO="${BASH_REMATCH[2]}"
  PR_NUMBER="${BASH_REMATCH[3]}"
else
  echo "[log-analyzer] ERROR: Invalid PR URL format: $PR_URL_ARG" >&2
  exit 1
fi
CURRENT_PR_URL="https://github.com/${OWNER}/${REPO}/pull/${PR_NUMBER}"

echo "============================================"
echo "  OAPE Log Analyzer"
echo "  PR: ${CURRENT_PR_URL}"
echo "  Job: ${JOB_NAME:-all}"
echo "  Log Dir: ${LOG_DIR}"
echo "  Dry Run: ${DRY_RUN}"
echo "  Max Budget: \$${MAX_BUDGET_PER_PR}"
echo "============================================"

# ---------------------------------------------------------------------------
# Collect log files
# ---------------------------------------------------------------------------
declare -a LOG_FILES=()

if [[ ! -d "$LOG_DIR" ]]; then
  echo "[log-analyzer] Log directory does not exist: ${LOG_DIR}"
  audit_log "info" "unknown" "" "" "log directory missing: ${LOG_DIR}"
  exit 0
fi

if [[ -n "$JOB_NAME" ]]; then
  log_id=$(echo "$JOB_NAME" | tr '/ ' '__')
  target="${LOG_DIR}/log-${log_id}.txt"
  if [[ -s "$target" ]]; then
    LOG_FILES+=("$target")
  fi
fi

if [[ ${#LOG_FILES[@]} -eq 0 ]]; then
  while IFS= read -r -d '' f; do
    LOG_FILES+=("$f")
  done < <(find "$LOG_DIR" -name 'log-*.txt' -size +0c -print0 2>/dev/null)
fi

if [[ ${#LOG_FILES[@]} -eq 0 ]]; then
  echo "[log-analyzer] No log files found in ${LOG_DIR}"
  audit_log "info" "unknown" "" "" "no log files found"
  exit 0
fi

echo "[log-analyzer] Found ${#LOG_FILES[@]} log file(s)"

# ---------------------------------------------------------------------------
# Classify each log file (classify_log is provided by classify.sh)
# ---------------------------------------------------------------------------
declare -A FILE_CLASSIFICATIONS=()
UNKNOWN_FILES=()

for log_file in "${LOG_FILES[@]}"; do
  classification=$(classify_log "$log_file")
  FILE_CLASSIFICATIONS["$log_file"]="$classification"
  echo "[log-analyzer] ${log_file##*/}: ${classification}"

  if [[ "$classification" == "unknown" ]]; then
    UNKNOWN_FILES+=("$log_file")
  fi
done

# ---------------------------------------------------------------------------
# Build analysis output
# ---------------------------------------------------------------------------
ANALYSIS_FILE="${LOG_DIR}/failure-analysis.json"

build_analysis_entry() {
  local job_name="$1" mode="$2" confidence="$3" root_cause="$4" suggested_fix="$5" evidence="$6"
  jq -n \
    --arg job "$job_name" \
    --arg mode "$mode" \
    --arg confidence "$confidence" \
    --arg root_cause "$root_cause" \
    --arg suggested_fix "$suggested_fix" \
    --arg evidence "$evidence" \
    '{job: $job, mode: $mode, confidence: $confidence, root_cause: $root_cause, suggested_fix: $suggested_fix, evidence: $evidence}'
}

ENTRIES="[]"

for log_file in "${LOG_FILES[@]}"; do
  classification="${FILE_CLASSIFICATIONS[$log_file]}"
  log_basename="${log_file##*/}"
  # shellcheck disable=SC2001
  job_label=$(echo "$log_basename" | sed 's/^log-//;s/\.txt$//')

  if [[ "$classification" != "unknown" ]]; then
    entry=$(build_analysis_entry "$job_label" "$classification" "high" \
      "Deterministic classification: ${classification}" \
      "" \
      "Pattern match in ${log_basename}")
    ENTRIES=$(echo "$ENTRIES" | jq --argjson e "$entry" '. + [$e]')
  fi
done

# ---------------------------------------------------------------------------
# Claude analysis for unknown failures
# ---------------------------------------------------------------------------
if [[ ${#UNKNOWN_FILES[@]} -gt 0 ]]; then
  echo ""
  echo "[log-analyzer] ${#UNKNOWN_FILES[@]} file(s) classified as 'unknown' — attempting Claude analysis"

  if [[ "$DRY_RUN" == "true" ]]; then
    echo "[log-analyzer] DRY RUN: Would invoke Claude for ${#UNKNOWN_FILES[@]} unknown failure(s)"
    for uf in "${UNKNOWN_FILES[@]}"; do
      log_basename="${uf##*/}"
      # shellcheck disable=SC2001
      job_label=$(echo "$log_basename" | sed 's/^log-//;s/\.txt$//')
      entry=$(build_analysis_entry "$job_label" "unknown" "low" \
        "Dry run — Claude analysis not invoked" \
        "" \
        "Would analyze ${log_basename}")
      ENTRIES=$(echo "$ENTRIES" | jq --argjson e "$entry" '. + [$e]')
    done
    audit_log "dry-run" "unknown" "" "" "would invoke Claude for ${#UNKNOWN_FILES[@]} file(s)"
  else
    # Check Claude CLI availability
    CLAUDE_CMD=""
    if command -v claude &>/dev/null; then
      CLAUDE_CMD="claude"
    elif command -v npx &>/dev/null; then
      CLAUDE_CMD="npx @anthropic-ai/claude-code"
    fi

    if [[ -z "$CLAUDE_CMD" ]]; then
      echo "[log-analyzer] Claude CLI not available (install nodejs + npm for npx)"
      for uf in "${UNKNOWN_FILES[@]}"; do
        log_basename="${uf##*/}"
        # shellcheck disable=SC2001
        job_label=$(echo "$log_basename" | sed 's/^log-//;s/\.txt$//')
        entry=$(build_analysis_entry "$job_label" "unknown" "low" \
          "Claude CLI not available" \
          "Install nodejs + npm in container image" \
          "")
        ENTRIES=$(echo "$ENTRIES" | jq --argjson e "$entry" '. + [$e]')
      done
      audit_log "skipped" "unknown" "" "" "Claude CLI not available"
    else
      # Load skill file
      SKILL_CONTENT=""
      if [[ -f "$SKILL_FILE" ]]; then
        SKILL_CONTENT=$(cat "$SKILL_FILE")
      else
        echo "[log-analyzer] WARN: Skill file not found at ${SKILL_FILE}"
      fi

      # Gather PR change context if available
      PR_CONTEXT=""
      if [[ -n "$RESULT_FILE" && -f "$RESULT_FILE" ]]; then
        PR_CONTEXT=$(jq -r '.pr_change_context // empty' "$RESULT_FILE" 2>/dev/null || true)
      fi

      for uf in "${UNKNOWN_FILES[@]}"; do
        log_basename="${uf##*/}"
        # shellcheck disable=SC2001
        job_label=$(echo "$log_basename" | sed 's/^log-//;s/\.txt$//')

        echo "[log-analyzer] Analyzing ${log_basename} with Claude..."

        log_excerpt=$(tail -n "$MAX_LOG_LINES" "$uf")

        prompt="You are analyzing a CI failure for an OpenShift operator PR.

${SKILL_CONTENT:+## CI Monitor Skill Reference
$SKILL_CONTENT

---
}
## Task

Analyze the following CI log for the failure mode and root cause.

Job: ${job_label}
PR: ${CURRENT_PR_URL}
Repository: ${OWNER}/${REPO}
${PR_CONTEXT:+
PR Change Context:
$PR_CONTEXT
}
## CI Log (last ${MAX_LOG_LINES} lines)

\`\`\`
${log_excerpt}
\`\`\`

## Required Output

Respond with ONLY a JSON object (no markdown fencing, no explanation) with these fields:
- \"mode\": one of \"install-failure\", \"test-failure\", \"build-failure\", \"lint-failure\", \"infra-flake\", \"unknown\"
- \"root_cause\": one-sentence root cause description
- \"confidence\": one of \"high\", \"medium\", \"low\"
- \"suggested_fix\": actionable fix suggestion (or empty string if none)
- \"evidence\": key log line(s) supporting the classification"

        claude_output=""
        if claude_output=$($CLAUDE_CMD --print \
          --max-turns 1 \
          --max-budget-usd "$MAX_BUDGET_PER_PR" \
          -p "$prompt" 2>&1); then

          # Try to parse Claude's response as JSON
          parsed=""
          if parsed=$(python3 -c "
import sys, json, re
text = sys.stdin.read()
for m in re.finditer(r'\{', text):
    try:
        obj = json.loads(text[m.start():])
        print(json.dumps(obj))
        sys.exit(0)
    except Exception:
        pass
sys.exit(1)
" <<< "$claude_output" 2>/dev/null); then
            mode=$(echo "$parsed" | jq -r '.mode // "unknown"')
            root_cause=$(echo "$parsed" | jq -r '.root_cause // "Claude analysis"')
            confidence=$(echo "$parsed" | jq -r '.confidence // "medium"')
            suggested_fix=$(echo "$parsed" | jq -r '.suggested_fix // ""')
            evidence=$(echo "$parsed" | jq -r '.evidence // ""')

            echo "[log-analyzer] Claude result for ${job_label}: mode=${mode}, confidence=${confidence}"
            entry=$(build_analysis_entry "$job_label" "$mode" "$confidence" "$root_cause" "$suggested_fix" "$evidence")
            ENTRIES=$(echo "$ENTRIES" | jq --argjson e "$entry" '. + [$e]')
            audit_log "analyzed" "$mode" "" "" "Claude analysis: ${root_cause}"
          else
            echo "[log-analyzer] WARN: Could not parse Claude output as JSON for ${job_label}"
            entry=$(build_analysis_entry "$job_label" "unknown" "low" \
              "Claude output not parseable" \
              "" \
              "Raw output saved to log")
            ENTRIES=$(echo "$ENTRIES" | jq --argjson e "$entry" '. + [$e]')
            audit_log "error" "unknown" "" "" "Claude output not parseable for ${job_label}"
          fi
        else
          echo "[log-analyzer] WARN: Claude invocation failed for ${job_label}"
          entry=$(build_analysis_entry "$job_label" "unknown" "low" \
            "Claude invocation failed" \
            "" \
            "")
          ENTRIES=$(echo "$ENTRIES" | jq --argjson e "$entry" '. + [$e]')
          audit_log "error" "unknown" "" "" "Claude invocation failed for ${job_label}"
        fi
      done
    fi
  fi
else
  echo "[log-analyzer] All failures classified deterministically — no Claude analysis needed"
fi

# ---------------------------------------------------------------------------
# Write analysis output
# ---------------------------------------------------------------------------
echo "$ENTRIES" | jq '{analysis: ., pr_url: $pr, analyzed_at: $ts}' \
  --arg pr "$CURRENT_PR_URL" \
  --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
  > "$ANALYSIS_FILE"

echo ""
echo "[log-analyzer] Analysis written to ${ANALYSIS_FILE}"
echo "[log-analyzer] Summary:"
echo "$ENTRIES" | jq -r '.[] | "  \(.job): \(.mode) (\(.confidence))"'
