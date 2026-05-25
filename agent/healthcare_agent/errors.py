"""Sentinel control-flow errors for the healthcare agent.

These are NOT normal tool failures — they signal that the current agent turn
must stop cleanly and surface a specific message to the user. They must never
be fed back into the LLM as tool errors (which would trigger a retry loop).
"""
from __future__ import annotations


class SessionRevokedError(Exception):
    """The MCP server signalled ``session_revoked_threshold_reached``.

    This means the user crossed the configured threshold of consecutive MFA
    denials on VIP reads, the MCP server fired a CAEP session-revocation event
    to Antenna, and the user's IBM Verify session has been killed across every
    app federated to the tenant.

    The agent loop must STOP. The handler should:

    - NOT retry the tool call (retrying produces another denial, more noise,
      and no progress — the session is already gone)
    - NOT feed the message back to the LLM as a tool error (the LLM will try
      to be helpful and call the tool again — same problem)
    - Surface the message verbatim to the user as the final response
    - Let the user re-authenticate via the UI's existing /signin flow
    """

    def __init__(self, message: str) -> None:
        super().__init__(message)
        self.message = message


# Stable substring contained in the MCP server's threshold-reached error message.
# Source of truth: ``mcp-server/src/ssf/dispatch-wrapper.ts`` — the error text is:
#   "<N> denials reached. Your session has been revoked across all apps federated
#    to this IBM Verify tenant. Please sign in again."
# The MCP TS SDK wraps the thrown error as an MCP CallToolResult with
# ``isError=true`` and the message as a text content item — so the HTTP status
# is 200, the JSON-RPC layer is fine, and the threshold signal lives inside the
# tool result content text. We match on a stable, unique phrase from that text.
SESSION_REVOKED_MARKER = (
    "session has been revoked across all apps federated to this IBM Verify tenant"
)
