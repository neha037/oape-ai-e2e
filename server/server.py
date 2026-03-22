"""
FastAPI server that exposes OAPE Claude Code skills via the Claude Agent SDK.

Usage:
    uvicorn server:app --reload

Endpoints:
    GET  /                                    - Homepage with submission form
    POST /submit                              - Submit a workflow job (returns job_id)
    POST /submit-legacy                       - Submit a single-command job (returns job_id)
    GET  /status/{job_id}                     - Poll job status
    GET  /stream/{job_id}                     - SSE stream of agent conversation
    GET  /repos                               - List available repositories
    GET  /api/v1/oape-workflow                - Start full workflow (async)
    GET  /api/v1/oape-api-implement           - Synchronous API-implement endpoint (legacy)
"""

import asyncio
import json
import os
from pathlib import Path
import re
import uuid

from fastapi import FastAPI, HTTPException, Query, Form
from fastapi.responses import HTMLResponse
from sse_starlette.sse import EventSourceResponse

from agent import run_agent, run_workflow, SUPPORTED_COMMANDS, TEAM_REPOS


app = FastAPI(
    title="OAPE Operator Feature Developer",
    description="Orchestrates OAPE Claude Code commands to generate "
    "complete operator implementations from OpenShift enhancement proposals. "
    "Creates 3 PRs: API types, controller implementation, and e2e tests.",
    version="0.2.0",
)

EP_URL_PATTERN = re.compile(
    r"^https://github\.com/openshift/enhancements/pull/\d+/?$"
)

# ---------------------------------------------------------------------------
# In-memory job store
# ---------------------------------------------------------------------------
jobs: dict[str, dict] = {}


def _validate_ep_url(ep_url: str) -> None:
    """Raise HTTPException if ep_url is not a valid enhancement PR URL."""
    if not EP_URL_PATTERN.match(ep_url.rstrip("/")):
        raise HTTPException(
            status_code=400,
            detail="Invalid enhancement PR URL. "
            "Expected format: https://github.com/openshift/enhancements/pull/<number>",
        )


def _resolve_working_dir(cwd: str) -> str:
    """Resolve and validate the working directory."""
    working_dir = cwd if cwd else os.getcwd()
    if not os.path.isdir(working_dir):
        raise HTTPException(
            status_code=400,
            detail=f"The provided cwd is not a valid directory: {working_dir}",
        )
    return working_dir


_HOMEPAGE_PATH = Path(__file__).parent / "homepage.html"
HOMEPAGE_HTML = _HOMEPAGE_PATH.read_text()


@app.get("/", response_class=HTMLResponse)
async def homepage():
    """Serve the submission form."""
    return HOMEPAGE_HTML


@app.get("/repos")
async def list_repos():
    """List available repositories."""
    return {
        "repositories": [
            {
                "short_name": key,
                "url": info["url"],
                "base_branch": info["base_branch"],
                "product": info["product"],
                "role": info["role"],
            }
            for key, info in TEAM_REPOS.items()
        ]
    }


@app.post("/submit")
async def submit_workflow_job(
    ep_url: str = Form(...),
    repo: str = Form(...),
    cwd: str = Form(default=""),
):
    """Validate inputs, create a workflow background job, and return its ID.

    This runs the full 3-PR workflow:
    - PR #1: init → api-generate → api-generate-tests → review → raise PR
    - PR #2: api-implement → review → raise PR
    - PR #3: e2e-generate → review → raise PR
    """
    _validate_ep_url(ep_url)
    working_dir = _resolve_working_dir(cwd)

    job_id = uuid.uuid4().hex[:12]
    jobs[job_id] = {
        "status": "running",
        "mode": "workflow",
        "ep_url": ep_url,
        "repo": repo,
        "cwd": working_dir,
        "conversation": [],
        "message_event": asyncio.Condition(),
        "output": "",
        "cost_usd": 0.0,
        "error": None,
        "prs": [],
    }
    asyncio.create_task(_run_workflow_job(job_id, ep_url, repo, working_dir))
    return {"job_id": job_id}


@app.post("/submit-legacy")
async def submit_legacy_job(
    ep_url: str = Form(...),
    command: str = Form(default="api-implement"),
    cwd: str = Form(default=""),
):
    """Validate inputs, create a single-command background job, and return its ID."""
    _validate_ep_url(ep_url)
    if command not in SUPPORTED_COMMANDS:
        raise HTTPException(
            status_code=400,
            detail=f"Unsupported command: {command}. "
            f"Supported: {', '.join(SUPPORTED_COMMANDS)}",
        )
    working_dir = _resolve_working_dir(cwd)

    job_id = uuid.uuid4().hex[:12]
    jobs[job_id] = {
        "status": "running",
        "mode": "legacy",
        "ep_url": ep_url,
        "command": command,
        "cwd": working_dir,
        "conversation": [],
        "message_event": asyncio.Condition(),
        "output": "",
        "cost_usd": 0.0,
        "error": None,
    }
    asyncio.create_task(_run_legacy_job(job_id, command, ep_url, working_dir))
    return {"job_id": job_id}


@app.get("/status/{job_id}")
async def job_status(job_id: str):
    """Return the current status of a job."""
    if job_id not in jobs:
        raise HTTPException(status_code=404, detail="Job not found")
    job = jobs[job_id]
    response = {
        "status": job["status"],
        "mode": job.get("mode", "legacy"),
        "ep_url": job["ep_url"],
        "cwd": job["cwd"],
        "output": job.get("output", ""),
        "cost_usd": job.get("cost_usd", 0.0),
        "error": job.get("error"),
        "message_count": len(job.get("conversation", [])),
    }
    if job.get("mode") == "workflow":
        response["repo"] = job.get("repo", "")
        response["prs"] = job.get("prs", [])
    return response


@app.get("/stream/{job_id}")
async def stream_job(job_id: str):
    """Stream job conversation messages via Server-Sent Events."""
    if job_id not in jobs:
        raise HTTPException(status_code=404, detail="Job not found")

    async def event_generator():
        cursor = 0
        condition = jobs[job_id]["message_event"]

        while True:
            # Send any new messages since the cursor
            conversation = jobs[job_id]["conversation"]
            while cursor < len(conversation):
                yield {
                    "event": "message",
                    "data": json.dumps(conversation[cursor], default=str),
                }
                cursor += 1

            # Check if the job is complete
            status = jobs[job_id]["status"]
            if status != "running":
                result_data = {
                    "status": status,
                    "output": jobs[job_id].get("output", ""),
                    "cost_usd": jobs[job_id].get("cost_usd", 0.0),
                    "error": jobs[job_id].get("error"),
                }
                if jobs[job_id].get("mode") == "workflow":
                    result_data["prs"] = jobs[job_id].get("prs", [])
                yield {
                    "event": "complete",
                    "data": json.dumps(result_data),
                }
                return

            # Wait for new messages or send keepalive on timeout
            async with condition:
                try:
                    await asyncio.wait_for(condition.wait(), timeout=30.0)
                except asyncio.TimeoutError:
                    yield {"event": "keepalive", "data": ""}

    return EventSourceResponse(event_generator())


async def _run_workflow_job(
    job_id: str, ep_url: str, repo: str, working_dir: str
):
    """Run the full workflow in the background and stream messages to the job store."""
    condition = jobs[job_id]["message_event"]
    loop = asyncio.get_running_loop()

    def on_message(msg: dict) -> None:
        jobs[job_id]["conversation"].append(msg)
        loop.create_task(_notify(condition))

    result = await run_workflow(ep_url, repo, working_dir, on_message=on_message)
    if result.success:
        jobs[job_id]["status"] = "success"
        jobs[job_id]["output"] = result.output
        jobs[job_id]["cost_usd"] = result.cost_usd
        jobs[job_id]["prs"] = [
            {
                "pr_number": pr.pr_number,
                "pr_url": pr.pr_url,
                "branch_name": pr.branch_name,
                "title": pr.title,
            }
            for pr in result.prs
        ]
    else:
        jobs[job_id]["status"] = "failed"
        jobs[job_id]["error"] = result.error

    # Final notification so SSE clients see the status change
    async with condition:
        condition.notify_all()


async def _run_legacy_job(
    job_id: str, command: str, ep_url: str, working_dir: str
):
    """Run a single command in the background and stream messages to the job store."""
    condition = jobs[job_id]["message_event"]
    loop = asyncio.get_running_loop()

    def on_message(msg: dict) -> None:
        jobs[job_id]["conversation"].append(msg)
        loop.create_task(_notify(condition))

    result = await run_agent(command, ep_url, working_dir, on_message=on_message)
    if result.success:
        jobs[job_id]["status"] = "success"
        jobs[job_id]["output"] = result.output
        jobs[job_id]["cost_usd"] = result.cost_usd
    else:
        jobs[job_id]["status"] = "failed"
        jobs[job_id]["error"] = result.error

    # Final notification so SSE clients see the status change
    async with condition:
        condition.notify_all()


async def _notify(condition: asyncio.Condition) -> None:
    """Notify all waiters on the condition."""
    async with condition:
        condition.notify_all()


@app.get("/api/v1/oape-workflow")
async def api_workflow(
    ep_url: str = Query(
        ...,
        description="GitHub PR URL for the OpenShift enhancement proposal "
        "(e.g. https://github.com/openshift/enhancements/pull/1234)",
    ),
    repo: str = Query(
        ...,
        description="Short name of the target repository "
        "(e.g. cert-manager-operator, external-secrets-operator)",
    ),
    cwd: str = Query(
        default="",
        description="Absolute path to the working directory "
        "where repositories will be cloned. Defaults to the current working directory.",
    ),
):
    """Start the full 3-PR workflow (async, returns job_id)."""
    _validate_ep_url(ep_url)
    working_dir = _resolve_working_dir(cwd)

    job_id = uuid.uuid4().hex[:12]
    jobs[job_id] = {
        "status": "running",
        "mode": "workflow",
        "ep_url": ep_url,
        "repo": repo,
        "cwd": working_dir,
        "conversation": [],
        "message_event": asyncio.Condition(),
        "output": "",
        "cost_usd": 0.0,
        "error": None,
        "prs": [],
    }
    asyncio.create_task(_run_workflow_job(job_id, ep_url, repo, working_dir))

    return {
        "job_id": job_id,
        "status_url": f"/status/{job_id}",
        "stream_url": f"/stream/{job_id}",
        "message": "Workflow started. Poll status_url or connect to stream_url for updates.",
    }


@app.get("/api/v1/oape-api-implement")
async def api_implement(
    ep_url: str = Query(
        ...,
        description="GitHub PR URL for the OpenShift enhancement proposal "
        "(e.g. https://github.com/openshift/enhancements/pull/1234)",
    ),
    cwd: str = Query(
        default="",
        description="Absolute path to the operator repository where code "
        "will be generated. Defaults to the current working directory.",
    ),
):
    """Generate controller/reconciler code from an enhancement proposal (synchronous)."""
    _validate_ep_url(ep_url)
    working_dir = _resolve_working_dir(cwd)

    result = await run_agent("api-implement", ep_url, working_dir)
    if not result.success:
        raise HTTPException(
            status_code=500, detail=f"Agent execution failed: {result.error}"
        )

    return {
        "status": "success",
        "ep_url": ep_url,
        "cwd": working_dir,
        "output": result.output,
        "cost_usd": result.cost_usd,
    }
