"""
Core agent execution logic for multi-PR operator feature development workflow.

Uses the Claude Agent SDK to orchestrate a sequence of OAPE skills that:
1. PR #1: init → api-generate → api-generate-tests → review-and-fix → raise PR
2. PR #2: api-implement → review-and-fix → raise PR
3. PR #3: e2e-generate → review-and-fix → raise PR
"""

import csv
import json
import logging
import tempfile
import traceback
from collections.abc import Callable
from dataclasses import dataclass, field
from pathlib import Path

from claude_agent_sdk import (
    query,
    ClaudeAgentOptions,
    AssistantMessage,
    ResultMessage,
    TextBlock,
    ThinkingBlock,
    ToolUseBlock,
    ToolResultBlock,
)

# Resolve the plugin directory (repo root) relative to this file.
PLUGIN_DIR = str(Path(__file__).resolve().parent.parent / "plugins" / "oape")

CONVERSATION_LOG = Path("/tmp/conversation.log")

conv_logger = logging.getLogger("conversation")
conv_logger.setLevel(logging.INFO)
_handler = logging.FileHandler(CONVERSATION_LOG)
_handler.setFormatter(logging.Formatter("%(message)s"))
conv_logger.addHandler(_handler)

with open(Path(__file__).resolve().parent.parent / "config" / "config.json") as cf:
    CONFIGS = json.loads(cf.read())

@dataclass
class PRResult:
    """Result of a single PR creation."""

    pr_number: int
    pr_url: str
    branch_name: str
    title: str


@dataclass
class WorkflowResult:
    """Result returned after running the full workflow."""

    output: str
    cost_usd: float
    error: str | None = None
    conversation: list[dict] = field(default_factory=list)
    prs: list[PRResult] = field(default_factory=list)

    @property
    def success(self) -> bool:
        return self.error is None


def _build_workflow_prompt(
    ep_url: str | None,
    jira_ticket: str | None,
    repo_info: dict,
    workflow_mode: str = "full",
) -> str:
    """Build the system prompt for the full workflow.

    Supports three input modes (EP-only, Jira-only, EP+Jira) and three
    workflow modes (full=3 PRs, feature=2 PRs, bugfix=1 PR).
    """

    if ep_url and jira_ticket:
        return _prompt_ep_plus_jira(ep_url, jira_ticket, repo_info, workflow_mode)
    if jira_ticket:
        return _prompt_jira_only(jira_ticket, repo_info, workflow_mode)
    return _prompt_ep_only(ep_url, repo_info, workflow_mode)


# ---------------------------------------------------------------------------
# Shared helpers for composable prompt sections
# ---------------------------------------------------------------------------

def _review_ticket(jira_ticket: str | None) -> str:
    return jira_ticket if jira_ticket else "OCPBUGS-0"


def _branch_id(ep_url: str | None, jira_ticket: str | None) -> str:
    if ep_url:
        return "<ep-number>"
    return jira_ticket.lower() if jira_ticket else "unknown"


def _commit_prefix(jira_ticket: str | None) -> str:
    if jira_ticket:
        return f"feat({jira_ticket})"
    return "feat"


def _pr_sections_full(
    ep_url: str | None,
    jira_ticket: str | None,
    repo_info: dict,
    api_generate_cmd: str,
    api_implement_cmd: str,
) -> str:
    """Generate the 3-PR workflow section."""
    bid = _branch_id(ep_url, jira_ticket)
    ticket = _review_ticket(jira_ticket)
    base = repo_info["base_branch"]

    return f"""You will create THREE separate Pull Requests, each building on the previous one:

### PR #1: API Type Definitions
Branch: `feature/api-types-{bid}`
1. Run `/oape:init {repo_info['url']} {base}` to clone the repository and checkout the base branch
2. Create and checkout a new branch from `{base}`
3. Run `{api_generate_cmd}` to generate API type definitions
4. Run `/oape:api-generate-tests <path-to-generated-types>` to generate integration tests
5. Run `make generate && make manifests` to regenerate code
6. Run `/oape:review {ticket} {base}` to review and auto-fix issues
7. Commit all changes with a descriptive message
8. Push the branch and create a PR against `{base}`

### PR #2: Controller Implementation
Branch: `feature/controller-impl-{bid}`
1. Create and checkout a new branch from `{base}` (or from PR #1's branch if needed)
2. Run `{api_implement_cmd}` to generate controller/reconciler code
3. Run `make generate && make build` to verify the build
4. Run `/oape:review {ticket} {base}` to review and auto-fix issues
5. Commit all changes with a descriptive message
6. Push the branch and create a PR against `{base}`

### PR #3: E2E Tests
Branch: `feature/e2e-tests-{bid}`
1. Create and checkout a new branch from `{base}` (or from PR #2's branch if needed)
2. Run `/oape:e2e-generate {base}` to generate e2e test artifacts
3. Run `/oape:review {ticket} {base}` to review and auto-fix issues
4. Commit all changes with a descriptive message
5. Push the branch and create a PR against `{base}`"""


def _pr_sections_feature(
    ep_url: str | None,
    jira_ticket: str | None,
    repo_info: dict,
    api_generate_cmd: str,
    api_implement_cmd: str,
) -> str:
    """Generate the 2-PR workflow section."""
    bid = _branch_id(ep_url, jira_ticket)
    ticket = _review_ticket(jira_ticket)
    base = repo_info["base_branch"]

    return f"""You will create TWO Pull Requests:

### PR #1: API Type Definitions + Integration Tests
Branch: `feature/api-types-{bid}`
1. Run `/oape:init {repo_info['url']} {base}` to clone the repository and checkout the base branch
2. Create and checkout a new branch from `{base}`
3. Run `{api_generate_cmd}` to generate API type definitions
4. Run `/oape:api-generate-tests <path-to-generated-types>` to generate integration tests
5. Run `make generate && make manifests` to regenerate code
6. Run `/oape:review {ticket} {base}` to review and auto-fix issues
7. Commit all changes with a descriptive message
8. Push the branch and create a PR against `{base}`

### PR #2: Controller Implementation + E2E Tests
Branch: `feature/impl-{bid}`
1. Create and checkout a new branch from `{base}` (or from PR #1's branch if needed)
2. Run `{api_implement_cmd}` to generate controller/reconciler code
3. Run `make generate && make build` to verify the build
4. Run `/oape:e2e-generate {base}` to generate e2e test artifacts
5. Run `/oape:review {ticket} {base}` to review and auto-fix issues
6. Commit all changes with a descriptive message
7. Push the branch and create a PR against `{base}`"""


def _pr_sections_bugfix(
    ep_url: str | None,
    jira_ticket: str | None,
    repo_info: dict,
    api_generate_cmd: str,
    api_implement_cmd: str,
) -> str:
    """Generate the 1-PR bugfix workflow section."""
    bid = _branch_id(ep_url, jira_ticket)
    ticket = _review_ticket(jira_ticket)
    base = repo_info["base_branch"]

    return f"""You will create ONE Pull Request containing the complete fix:

### PR #1: Bug Fix + E2E Tests
Branch: `fix/{bid}`
1. Run `/oape:init {repo_info['url']} {base}` to clone the repository and checkout the base branch
2. Create and checkout a new branch from `{base}`
3. Analyze the issue and implement the fix directly (modify API types, controller logic, or other code as needed)
4. If API types were modified, run `make generate && make manifests`
5. Run `make build` to verify the build
6. Run `/oape:e2e-generate {base}` to generate/update e2e test artifacts
7. Run `/oape:review {ticket} {base}` to review and auto-fix issues
8. Commit all changes with a descriptive message
9. Push the branch and create a PR against `{base}`"""


def _pr_sections(
    workflow_mode: str,
    ep_url: str | None,
    jira_ticket: str | None,
    repo_info: dict,
    api_generate_cmd: str,
    api_implement_cmd: str,
) -> str:
    """Dispatch to the right PR section builder based on workflow mode."""
    if workflow_mode == "bugfix":
        return _pr_sections_bugfix(ep_url, jira_ticket, repo_info, api_generate_cmd, api_implement_cmd)
    if workflow_mode == "feature":
        return _pr_sections_feature(ep_url, jira_ticket, repo_info, api_generate_cmd, api_implement_cmd)
    return _pr_sections_full(ep_url, jira_ticket, repo_info, api_generate_cmd, api_implement_cmd)


def _execution_instructions(workflow_mode: str, jira_ticket: str | None, has_phase0: bool = False) -> str:
    """Shared execution instructions and autonomy block."""
    ticket = _review_ticket(jira_ticket)

    mode_labels = {"full": "ALL THREE PRs", "feature": "BOTH PRs", "bugfix": "the PR"}
    pr_label = mode_labels.get(workflow_mode, "ALL PRs")

    phase0_line = "1. Complete Phase 0 (analyze + design doc) first\n" if has_phase0 else ""
    review_note = (
        f"the `/oape:review` command validates code against the Jira ticket {ticket}'s acceptance criteria"
        if jira_ticket
        else "the `/oape:review` command will automatically apply fixes"
    )

    return f"""## Execution Instructions

{phase0_line}1. Execute each PR workflow in sequence
2. After each step, verify it completed successfully before proceeding
3. If any step fails, stop and report the error clearly
4. For the review step, {review_note}
5. When creating PRs, use `gh pr create` with descriptive titles and bodies
6. Report the PR URL after each PR is created

## CRITICAL: Fully Autonomous Execution

You MUST execute {pr_label} in a single uninterrupted run. Do NOT ask the user for confirmation, approval, or permission between steps. Do NOT pause to ask "should I proceed?" or "shall I continue?". This is a fully automated pipeline — complete everything in one go.
"""


# ---------------------------------------------------------------------------
# Input-mode prompt builders
# ---------------------------------------------------------------------------

def _prompt_ep_only(ep_url: str, repo_info: dict, workflow_mode: str = "full") -> str:
    """EP-driven workflow prompt."""

    api_gen = f"/oape:api-generate {ep_url}"
    api_impl = f"/oape:api-implement {ep_url}"

    pr_sections = _pr_sections(workflow_mode, ep_url, None, repo_info, api_gen, api_impl)
    exec_block = _execution_instructions(workflow_mode, None)

    return f"""You are an OpenShift operator feature developer assistant. Your task is to take an Enhancement Proposal (EP) and generate a complete implementation.

## Input Information

- **Enhancement Proposal URL**: {ep_url}
- **Repository URL**: {repo_info['url']}
- **Base Branch**: {repo_info["base_branch"]}

## Workflow Overview

{pr_sections}

{exec_block}

## Important Notes

- Extract the EP number from the URL (e.g., 1234 from .../pull/1234) for branch naming
- Use conventional commit messages (e.g., "feat: add API types for <feature>")
- The review command uses OCPBUGS-0 as a placeholder ticket ID since we're generating new code
- If the repository is already cloned, the init command will use the existing directory
- Ensure each PR has a clear description of what was generated

Begin now. Execute autonomously without stopping or asking for user input.
"""


def _prompt_jira_only(jira_ticket: str, repo_info: dict, workflow_mode: str = "full") -> str:
    """Jira-driven workflow: analyze the ticket, synthesize a design doc, then generate code."""

    api_gen = "/oape:api-generate --design-doc <GIST_URL>"
    api_impl = "/oape:api-implement --design-doc <GIST_URL>"

    pr_sections = _pr_sections(workflow_mode, None, jira_ticket, repo_info, api_gen, api_impl)
    exec_block = _execution_instructions(workflow_mode, jira_ticket, has_phase0=True)

    return f"""You are an OpenShift operator feature developer assistant. Your task is to take a Jira ticket, analyze its requirements, synthesize a design document, and generate a complete implementation.

## Input Information

- **Jira Ticket**: {jira_ticket}
- **Repository URL**: {repo_info['url']}
- **Base Branch**: {repo_info["base_branch"]}

## Phase 0: Analyze Jira Ticket and Create Design Document

Before generating any code you MUST complete these steps:

1. Run `/oape:analyze-rfe {jira_ticket}` to deeply analyze the Jira ticket.
   This produces a comprehensive breakdown of the feature including epics, user stories,
   acceptance criteria, affected components, and technical analysis.

2. Based on the analysis output, **synthesize a design document** in markdown that follows this structure:

   ```markdown
   # Design Document: <Feature Name from Jira>

   ## Source
   Jira Ticket: {jira_ticket}

   ## API Specification
   - Group: <api-group>
   - Version: <version>
   - Kind: <kind>
   - Scope: Cluster or Namespaced

   ## Spec Fields
   - `fieldName` (type): Description
     - Validation: required, enum values, min/max, pattern
     - Default: default value if any

   ## Status Fields
   - `conditions`: Standard OpenShift conditions
   - `observedGeneration`: int64

   ## Reconciliation Workflow
   1. Validate spec
   2. Create/update dependent resources
   3. Update status

   ## Dependent Resources
   - ConfigMap: purpose
   - Deployment: purpose
   ```

   Derive every field, type, validation rule, and reconciliation step from the Jira ticket
   description and acceptance criteria. If the ticket lacks API-level detail, make reasonable
   design decisions that align with OpenShift conventions and document your assumptions.

3. Save the design document to a temporary file and create a GitHub Gist:
   ```bash
   gh gist create --public -f design-doc.md /tmp/design-doc-{jira_ticket}.md
   ```
   Capture the resulting gist URL — you will use it in subsequent commands.

## Workflow Overview

After creating the design document gist:

{pr_sections}

{exec_block}

## Important Notes

- Use `{jira_ticket}` for branch naming (lowercased)
- Use conventional commit messages referencing the Jira ticket (e.g., "{_commit_prefix(jira_ticket)}: add API types for <feature>")
- The `/oape:review` command will validate code against the actual Jira ticket's acceptance criteria
- If the repository is already cloned, the init command will use the existing directory
- Ensure each PR references {jira_ticket} in its title and description

Begin now. Execute Phase 0, then all PRs — without stopping or asking for user input.
"""


def _prompt_ep_plus_jira(ep_url: str, jira_ticket: str, repo_info: dict, workflow_mode: str = "full") -> str:
    """EP + Jira workflow: uses EP for code generation, Jira ticket for review validation."""

    api_gen = f"/oape:api-generate {ep_url}"
    api_impl = f"/oape:api-implement {ep_url}"

    pr_sections = _pr_sections(workflow_mode, ep_url, jira_ticket, repo_info, api_gen, api_impl)
    exec_block = _execution_instructions(workflow_mode, jira_ticket)

    return f"""You are an OpenShift operator feature developer assistant. Your task is to take an Enhancement Proposal (EP) and generate a complete implementation, validating against a Jira ticket.

## Input Information

- **Enhancement Proposal URL**: {ep_url}
- **Jira Ticket**: {jira_ticket}
- **Repository URL**: {repo_info['url']}
- **Base Branch**: {repo_info["base_branch"]}

## Workflow Overview

{pr_sections}

{exec_block}

## Important Notes

- Extract the EP number from the URL (e.g., 1234 from .../pull/1234) for branch naming
- Use conventional commit messages referencing the Jira ticket (e.g., "{_commit_prefix(jira_ticket)}: add API types for <feature>")
- The `/oape:review` command validates code against the actual Jira ticket {jira_ticket}'s acceptance criteria
- If the repository is already cloned, the init command will use the existing directory
- Ensure each PR references {jira_ticket} in its title and description

Begin now. Execute autonomously without stopping or asking for user input.
"""


async def run_workflow(
    ep_url: str | None,
    jira_ticket: str | None,
    repo_url: str,
    base_branch: str,
    workflow_mode: str = "full",
    on_message: Callable[[dict], None] | None = None,
) -> WorkflowResult:
    """Run the full operator feature development workflow.

    Args:
        ep_url: The enhancement proposal PR URL (optional if jira_ticket provided).
        jira_ticket: Jira ticket key such as OCPBUGS-12345 (optional if ep_url provided).
        repo_url: URL for git repository.
        base_branch: The base branch to create feature branches from.
        workflow_mode: PR split strategy — "full" (3 PRs), "feature" (2 PRs),
            or "bugfix" (1 PR). Defaults to "full".
        on_message: Optional callback invoked with each conversation message
            dict as it arrives, enabling real-time streaming.

    Returns:
        A WorkflowResult with the output, PRs created, or error.
    """
    prompt = _build_workflow_prompt(ep_url, jira_ticket, {
        'url': repo_url,
        'base_branch': base_branch
    }, workflow_mode=workflow_mode)

    working_dir = tempfile.mkdtemp(prefix="oape-")

    options = ClaudeAgentOptions(
        system_prompt=(
            "You are an OpenShift operator code generation assistant. "
            "Follow the workflow instructions precisely and execute each step. "
            "Use the OAPE plugins to generate code, tests, and reviews. "
            "Create git branches, commits, and pull requests as instructed. "
            "IMPORTANT: This is a fully automated pipeline. Execute ALL steps "
            "and ALL PRs without pausing, asking for confirmation, or waiting "
            "for user input. Never ask 'should I proceed?' or 'shall I continue?'. "
            "Complete the entire workflow autonomously in one run."
        ),
        cwd=working_dir,
        permission_mode="bypassPermissions",
        allowed_tools=CONFIGS["claude_allowed_tools"],
        plugins=[{"type": "local", "path": PLUGIN_DIR}],
    )

    output_parts: list[str] = []
    conversation: list[dict] = []
    cost_usd = 0.0

    conv_logger.info(
        f"\n{'=' * 60}\n[workflow] ep_url={ep_url}  jira={jira_ticket}  "
        f"repo={repo_url}  mode={workflow_mode}  cwd={working_dir}\n{'=' * 60}"
    )

    def _emit(entry: dict) -> None:
        """Append to conversation and invoke on_message callback if set."""
        conversation.append(entry)
        if on_message is not None:
            on_message(entry)

    try:
        async for message in query(
            prompt=prompt,
            options=options,
        ):
            if isinstance(message, AssistantMessage):
                for block in message.content:
                    if isinstance(block, TextBlock):
                        output_parts.append(block.text)
                        entry = {
                            "type": "assistant",
                            "block_type": "text",
                            "content": block.text,
                        }
                        _emit(entry)
                        conv_logger.info(f"[assistant] {block.text}")
                    elif isinstance(block, ThinkingBlock):
                        entry = {
                            "type": "assistant",
                            "block_type": "thinking",
                            "content": block.thinking,
                        }
                        _emit(entry)
                        conv_logger.info("[assistant:ThinkingBlock] (thinking)")
                    elif isinstance(block, ToolUseBlock):
                        entry = {
                            "type": "assistant",
                            "block_type": "tool_use",
                            "tool_name": block.name,
                            "tool_input": block.input,
                        }
                        _emit(entry)
                        conv_logger.info(f"[assistant:ToolUseBlock] {block.name}")
                    elif isinstance(block, ToolResultBlock):
                        content = block.content
                        if not isinstance(content, str):
                            content = json.dumps(content, default=str)
                        entry = {
                            "type": "assistant",
                            "block_type": "tool_result",
                            "tool_use_id": block.tool_use_id,
                            "content": content,
                            "is_error": block.is_error or False,
                        }
                        _emit(entry)
                        conv_logger.info(
                            f"[assistant:ToolResultBlock] {block.tool_use_id}"
                        )
                    else:
                        detail = json.dumps(
                            getattr(block, "__dict__", str(block)),
                            default=str,
                        )
                        entry = {
                            "type": "assistant",
                            "block_type": type(block).__name__,
                            "content": detail,
                        }
                        _emit(entry)
                        conv_logger.info(
                            f"[assistant:{type(block).__name__}] {detail}"
                        )
            elif isinstance(message, ResultMessage):
                cost_usd = message.total_cost_usd
                if message.result:
                    output_parts.append(message.result)
                entry = {
                    "type": "result",
                    "content": message.result,
                    "cost_usd": cost_usd,
                }
                _emit(entry)
                conv_logger.info(f"[result] {message.result}  cost=${cost_usd:.4f}")
            else:
                detail = json.dumps(
                    getattr(message, "__dict__", str(message)), default=str
                )
                entry = {
                    "type": type(message).__name__,
                    "content": detail,
                }
                _emit(entry)
                conv_logger.info(f"[{type(message).__name__}] {detail}")

        conv_logger.info(f"[done] cost=${cost_usd:.4f}  parts={len(output_parts)}\n")
        return WorkflowResult(
            output="\n".join(output_parts),
            cost_usd=cost_usd,
            conversation=conversation,
        )
    except Exception as exc:
        conv_logger.info(f"[error] {traceback.format_exc()}")
        return WorkflowResult(
            output="",
            cost_usd=cost_usd,
            error=str(exc),
            conversation=conversation,
        )
