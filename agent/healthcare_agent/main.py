"""Healthcare agent — Python + Strands + FastAPI.

A small HTTP server that hosts a Strands agent loop. The clinician's
IBM Verify access token arrives as an ``Authorization: Bearer`` header.
The agent forwards it to the MCP server unchanged. Everything in the
security chain (Token Exchange, RAR, step-up MFA, OBO mint, the Vault
verify-rar plugin, the ephemeral PostgreSQL credential) happens INSIDE
the MCP server. The agent is a transport, not a security boundary.

Run locally:

    uvicorn healthcare_agent.main:app --host 127.0.0.1 --port 8080 --reload

Invoke:

    curl -N -X POST http://127.0.0.1:8080/invoke \\
        -H "Authorization: Bearer $CLINICIAN_TOKEN" \\
        -H "Content-Type: application/json" \\
        -d '{"prompt": "List my patients"}'
"""
from __future__ import annotations

import logging
import os
from typing import AsyncIterator

from dotenv import load_dotenv
from fastapi import FastAPI, Header, HTTPException, Request
from fastapi.responses import JSONResponse, StreamingResponse
from strands import Agent

from .llm import make_model
from .mcp_client import (
    SessionGuardSignal,
    build_mcp_client,
    wrap_tools_with_session_guard,
)
from .prompts import SYSTEM_PROMPT, TOOL_GUIDANCE

load_dotenv()

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(name)s %(message)s",
)
log = logging.getLogger("healthcare-agent")

MCP_URL = os.environ.get("HEALTHCARE_MCP_URL", "http://127.0.0.1:3012/mcp")

app = FastAPI(title="healthcare-agent", version="0.1.0")


def _sse(payload: str) -> bytes:
    """Encode an arbitrary string as one SSE ``data:`` event with proper
    newline handling per the EventSource spec."""
    framed = payload.replace("\n", "\ndata: ")
    return f"data: {framed}\n\n".encode("utf-8")


@app.get("/healthz")
async def healthz() -> JSONResponse:
    return JSONResponse({"status": "ok", "service": "healthcare-agent"})


@app.post("/invoke")
async def invoke(request: Request, authorization: str | None = Header(default=None)) -> StreamingResponse:
    """One agent turn. POST body ``{"prompt": str}``. Streams SSE text events."""
    bearer = ""
    if authorization and authorization.lower().startswith("bearer "):
        bearer = authorization[len("Bearer "):].strip()
    if not bearer:
        raise HTTPException(status_code=401, detail="missing_bearer")

    body = await request.json()
    prompt = body.get("prompt", "")
    log.info("invoke prompt=%r token_present=%s", prompt, bool(bearer))

    async def event_stream() -> AsyncIterator[bytes]:
        # The signal is set by SessionAwareMCPTool when an MCP tool result
        # contains the SSF threshold-reached marker. We check it after every
        # yielded event and break out BEFORE the next LLM turn so the model
        # never gets to "helpfully" retry the tool call.
        signal = SessionGuardSignal()
        with build_mcp_client(MCP_URL, bearer) as mcp_client:
            tools = wrap_tools_with_session_guard(mcp_client.list_tools_sync(), signal)
            agent = Agent(
                model=make_model(),
                tools=tools,
                system_prompt=f"{SYSTEM_PROMPT}\n\n{TOOL_GUIDANCE}",
            )
            stream = agent.stream_async(prompt)
            try:
                async for event in stream:
                    if "data" in event and isinstance(event["data"], str):
                        yield _sse(event["data"])
                    if signal.triggered:
                        # SSF kicked in. Surface the verbatim MCP message and
                        # stop — do not let the agent loop start another turn.
                        log.info("session_revoked_threshold_reached — stopping agent turn")
                        yield _sse(signal.message)
                        break
            finally:
                # Best-effort close so the background event loop unwinds even
                # if we broke out early. Strands' stream_async is an async
                # generator; aclose() is the standard cleanup hook.
                aclose = getattr(stream, "aclose", None)
                if aclose is not None:
                    try:
                        await aclose()
                    except Exception:  # noqa: BLE001 — defensive cleanup
                        pass
            yield b"data: [DONE]\n\n"

    return StreamingResponse(event_stream(), media_type="text/event-stream")
