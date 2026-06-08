"""Standalone worker entrypoint for K8s Job execution.

Reads EP_URL, REPO, BASE_BRANCH from environment variables and runs the full
operator feature development workflow. All output is printed to stdout
as JSON (one message per line), which the orchestrator streams as pod logs.
"""

import asyncio
import json
import os
import sys

from rich import print_json

from agent import run_workflow


async def main():
    ep_url = os.environ.get("EP_URL") or None
    repo = os.environ.get("REPO_URL")
    base_branch = os.environ.get("BASE_BRANCH")
    jira_ticket = os.environ.get("JIRA_TICKET") or None
    workflow_mode = os.environ.get("WORKFLOW_MODE", "full")

    if not repo or not base_branch:
        print("ERROR: REPO_URL and BASE_BRANCH environment variables are required", file=sys.stderr)
        sys.exit(1)

    if not ep_url and not jira_ticket:
        print("ERROR: at least one of EP_URL or JIRA_TICKET is required", file=sys.stderr)
        sys.exit(1)

    print(f"Starting workflow: ep_url={ep_url} jira_ticket={jira_ticket} repo={repo} mode={workflow_mode}", flush=True)

    result = await run_workflow(
        ep_url, jira_ticket, repo, base_branch,
        workflow_mode=workflow_mode,
        on_message=lambda msg: print_json(data=msg),
    )

    if result.success:
        print(f"WORKFLOW_SUCCESS cost=${result.cost_usd:.4f}", flush=True)
        for pr in result.prs:
            print(f"PR_CREATED: {pr.pr_url}", flush=True)
        sys.exit(0)
    else:
        print(f"WORKFLOW_FAILED: {result.error}", file=sys.stderr, flush=True)
        sys.exit(1)


if __name__ == "__main__":
    asyncio.run(main())
