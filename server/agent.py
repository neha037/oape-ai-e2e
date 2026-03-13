"""
Core agent execution logic shared between sync and async endpoints.
"""

import json
import logging
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

with open(Path(__file__).resolve().parent / "config.json") as cf:
    CONFIGS = json.loads(cf.read())

# Supported commands and their corresponding plugin skill names.
SUPPORTED_COMMANDS = {
    "api-implement": "oape:api-implement",
    "analyze-rfe": "oape:analyze-rfe",
}


@dataclass
class AgentResult:
    """Result returned after running the Claude agent."""

    output: str
    cost_usd: float
    error: str | None = None
    conversation: list[dict] = field(default_factory=list)

    @property
    def success(self) -> bool:
        return self.error is None


async def run_agent(
    command: str,
    ep_url: str,
    working_dir: str,
    design_doc_url: str = "",
    on_message: Callable[[dict], None] | None = None,
) -> AgentResult:
    """Run the Claude agent and return the result.

    Args:
        command: The command key (e.g. "api-implement").
        ep_url: The enhancement proposal PR URL (optional if design_doc_url provided).
        working_dir: Absolute path to the operator repo.
        design_doc_url: Optional GitHub Gist URL containing design document.
        on_message: Optional callback invoked with each conversation message
            dict as it arrives, enabling real-time streaming.

    Returns:
        An AgentResult with the output or error.
    """
    skill_name = SUPPORTED_COMMANDS.get(command)
    if skill_name is None:
        return AgentResult(
            output="",
            cost_usd=0.0,
            error=f"Unsupported command: {command}. "
            f"Supported: {', '.join(SUPPORTED_COMMANDS)}",
        )

    # Build system prompt based on inputs provided
    input_description = []
    if ep_url:
        input_description.append("enhancement proposal PR URL")
    if design_doc_url:
        input_description.append("design document (gist)")
    inputs_str = " and ".join(input_description) if input_description else "input"

    options = ClaudeAgentOptions(
        system_prompt=(
            "You are an OpenShift operator code generation assistant. "
            f"Execute the {skill_name} plugin with the provided {inputs_str}. "
        ),
        cwd=working_dir,
        permission_mode="bypassPermissions",
        allowed_tools=CONFIGS["claude_allowed_tools"],
        plugins=[{"type": "local", "path": PLUGIN_DIR}],
    )

    # Build the prompt with optional --design-doc argument
    prompt_parts = [f"/{skill_name}"]
    if ep_url:
        prompt_parts.append(ep_url)
    if design_doc_url:
        prompt_parts.append(f"--design-doc {design_doc_url}")
    prompt = " ".join(prompt_parts)

    output_parts: list[str] = []
    conversation: list[dict] = []
    cost_usd = 0.0

    conv_logger.info(
        f"\n{'=' * 60}\n[request] command={command}  ep_url={ep_url}  "
        f"design_doc_url={design_doc_url}  cwd={working_dir}\n{'=' * 60}"
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
                        entry = {"type": "assistant", "block_type": "text",
                                 "content": block.text}
                        _emit(entry)
                        conv_logger.info(f"[assistant] {block.text}")
                    elif isinstance(block, ThinkingBlock):
                        entry = {"type": "assistant", "block_type": "thinking",
                                 "content": block.thinking}
                        _emit(entry)
                        conv_logger.info(
                            f"[assistant:ThinkingBlock] (thinking)")
                    elif isinstance(block, ToolUseBlock):
                        entry = {"type": "assistant", "block_type": "tool_use",
                                 "tool_name": block.name,
                                 "tool_input": block.input}
                        _emit(entry)
                        conv_logger.info(
                            f"[assistant:ToolUseBlock] {block.name}")
                    elif isinstance(block, ToolResultBlock):
                        content = block.content
                        if not isinstance(content, str):
                            content = json.dumps(content, default=str)
                        entry = {"type": "assistant", "block_type": "tool_result",
                                 "tool_use_id": block.tool_use_id,
                                 "content": content,
                                 "is_error": block.is_error or False}
                        _emit(entry)
                        conv_logger.info(
                            f"[assistant:ToolResultBlock] {block.tool_use_id}")
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
                conv_logger.info(
                    f"[result] {message.result}  cost=${cost_usd:.4f}"
                )
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

        conv_logger.info(
            f"[done] cost=${cost_usd:.4f}  parts={len(output_parts)}\n"
        )
        return AgentResult(
            output="\n".join(output_parts),
            cost_usd=cost_usd,
            conversation=conversation,
        )
    except Exception as exc:
        conv_logger.info(f"[error] {traceback.format_exc()}")
        return AgentResult(
            output="",
            cost_usd=cost_usd,
            error=str(exc),
            conversation=conversation,
        )
