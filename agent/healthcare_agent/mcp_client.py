"""Per-request MCP client.

Strands' MCPClient takes a static header dict per instance; per-call dynamic
headers are an open SDK feature request. So we build a FRESH MCPClient per
agent invocation, carrying that request's user Bearer token.

The token is the RFC 8693 ``subject_token`` from the perspective of the MCP
server — it uses the token to do Token Exchange against IBM Verify. The
agent itself never inspects the token or makes any authorization decision.

This module also exposes ``wrap_tools_with_session_guard``: a thin Strands
``AgentTool`` wrapper that watches every MCP tool result for the
``session_revoked_threshold_reached`` marker. When the MCP server fires the
SSF kill (3 consecutive MFA denials on a VIP read), it throws an error
inside the registered tool callback; the MCP TS SDK then returns a
``CallToolResult`` with ``isError=true`` and the message as text content
(HTTP stays 200). The wrapper records that signal on a shared object so the
FastAPI handler can stop the agent turn and surface the message verbatim,
WITHOUT feeding it back to the LLM as a normal tool failure (which would
trigger a retry loop).
"""
from __future__ import annotations

from dataclasses import dataclass
from typing import TYPE_CHECKING, Any, Sequence

from mcp.client.streamable_http import streamablehttp_client
from strands.tools.mcp.mcp_agent_tool import MCPAgentTool
from strands.tools.mcp.mcp_client import MCPClient
from strands.types._events import ToolResultEvent

from .errors import SESSION_REVOKED_MARKER

if TYPE_CHECKING:
    from strands.types.tools import AgentTool, ToolGenerator, ToolUse


def _bearer_headers(user_token: str) -> dict[str, str]:
    if not user_token:
        return {}
    return {"authorization": f"Bearer {user_token}"}


def build_mcp_client(mcp_url: str, user_token: str) -> MCPClient:
    """Build (do not enter) an MCPClient for ``mcp_url`` carrying ``user_token``.

    Caller uses it as a context manager:

        with build_mcp_client(url, tok) as client:
            tools = client.list_tools_sync()
    """
    headers = _bearer_headers(user_token)
    return MCPClient(
        lambda: streamablehttp_client(
            mcp_url,
            headers=headers,
            timeout=120,
            terminate_on_close=False,
        )
    )


@dataclass
class SessionGuardSignal:
    """Mutable container the wrapped tools write to when SSF kills the session.

    The FastAPI handler holds a reference to this and checks it after each
    yielded agent event. When ``triggered`` is True the agent turn must stop
    cleanly and surface ``message`` to the user. No further LLM call may
    happen — that's the whole point of the sentinel.
    """

    triggered: bool = False
    message: str = ""


def _result_contains_session_revoked(tool_result: Any) -> str | None:
    """Return the verbatim message text if the tool result text contains the
    SSF threshold marker, otherwise None.

    Strands shapes the tool result as ``{"status": "error" | "success",
    "content": [{"text": "..."}], "isError": True | None, ...}``. We scan
    every text content item for the stable marker phrase.
    """
    if not isinstance(tool_result, dict):
        return None
    content = tool_result.get("content")
    if not isinstance(content, list):
        return None
    for item in content:
        if not isinstance(item, dict):
            continue
        text = item.get("text")
        if isinstance(text, str) and SESSION_REVOKED_MARKER in text:
            # MCP TS SDK prefixes the wrapped error message with "Tool execution
            # failed: " in some paths. Strip nothing — surface verbatim; the
            # human-readable phrase from dispatch-wrapper.ts is already exactly
            # what we want to show the user.
            return text
    return None


class SessionAwareMCPTool(MCPAgentTool):
    """MCPAgentTool subclass that records the SSF threshold-reached signal.

    Behavior:
      - Run the parent MCPAgentTool stream normally (one tool call to MCP).
      - Inspect each yielded ``ToolResultEvent``. If its tool_result text
        contains the SSF marker, set the shared signal so the FastAPI
        handler can abort the agent turn.
      - In all cases yield the event unchanged so Strands' internal
        bookkeeping stays consistent. The handler is responsible for
        breaking the outer loop BEFORE the next LLM turn fires.
    """

    def __init__(self, inner: MCPAgentTool, signal: SessionGuardSignal) -> None:
        # Reuse the inner tool's MCP wiring rather than re-discovering it.
        super().__init__(
            mcp_tool=inner.mcp_tool,
            mcp_client=inner.mcp_client,
            name_override=inner.tool_name,
            timeout=inner.timeout,
        )
        self._signal = signal

    async def stream(  # type: ignore[override]
        self,
        tool_use: "ToolUse",
        invocation_state: dict[str, Any],
        **kwargs: Any,
    ) -> "ToolGenerator":
        async for event in super().stream(tool_use, invocation_state, **kwargs):
            if isinstance(event, ToolResultEvent):
                msg = _result_contains_session_revoked(event.tool_result)
                if msg:
                    self._signal.triggered = True
                    self._signal.message = msg
            yield event


def wrap_tools_with_session_guard(
    tools: Sequence["AgentTool"],
    signal: SessionGuardSignal,
) -> list["AgentTool"]:
    """Wrap every MCP-backed tool so its results are watched for the SSF
    threshold marker. Non-MCP tools (none today, but futureproof) pass through.
    """
    wrapped: list[AgentTool] = []
    for tool in tools:
        if isinstance(tool, MCPAgentTool):
            wrapped.append(SessionAwareMCPTool(tool, signal))
        else:
            wrapped.append(tool)
    return wrapped
