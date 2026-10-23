"""Demo support agent: an OpenAI-compatible client that may only talk to the
LiteLLM gateway (with its own virtual key) and to the support MCP server.

    python agent.py ask "What should I do about ticket TCK-1003?"
    python agent.py idle      # container main process; asks run via kubectl exec

Every model call goes through the gateway, so it is budgeted, rate-limited and
traced there; the agent tags its calls so the traces say who asked.
"""

import asyncio
import json
import os
import re
import sys
import time

from mcp.client.client import Client
from openai import OpenAI

GATEWAY = os.environ.get("LITELLM_BASE_URL", "http://litellm.ai-gateway.svc.cluster.local:4000/v1")
MCP_URL = os.environ.get("MCP_URL", "http://mcp-server.ai-agents.svc.cluster.local:8000/mcp")
MODEL = os.environ.get("AGENT_MODEL", "local")
MAX_STEPS = 4

SYSTEM = (
    "You are a support assistant. Use the tools to look up tickets and runbooks "
    "before answering. Answer in at most four short sentences."
)


def openai_tools(mcp_tools) -> list[dict]:
    """MCP tool descriptions → OpenAI function-calling schema."""
    return [
        {"type": "function",
         "function": {"name": t.name, "description": t.description or "",
                      "parameters": t.input_schema if hasattr(t, "input_schema") else t.inputSchema}}
        for t in mcp_tools
    ]


async def tool(mcp, name: str, args: dict) -> str:
    print(f"[tool] {name}({args})", file=sys.stderr)
    result = await mcp.call_tool(name, args)
    return "\n".join(c.text for c in result.content if hasattr(c, "text"))


async def prefetch(mcp, question: str) -> str:
    """Look up every ticket ID in the question (and its runbook) up front.

    A 1.5B local model often *describes* a tool call instead of emitting one, so
    the agent doesn't rely on it for the basics; larger models still get the
    tools and can call them themselves.
    """
    notes = []
    for ticket_id in dict.fromkeys(re.findall(r"TCK-\d+", question.upper())):
        ticket = await tool(mcp, "lookup_ticket", {"ticket_id": ticket_id})
        notes.append(f"lookup_ticket({ticket_id}) -> {ticket}")
        runbook = json.loads(ticket).get("runbook") if ticket.startswith("{") else None
        if runbook:
            notes.append(f"get_runbook({runbook}) -> {await tool(mcp, 'get_runbook', {'runbook_id': runbook})}")
    return "\n".join(notes)


async def ask(question: str) -> str:
    llm = OpenAI(base_url=GATEWAY, api_key=os.environ["AGENT_KEY"], timeout=180)
    async with Client(MCP_URL) as mcp:
        tools = openai_tools((await mcp.list_tools()).tools)
        messages = [{"role": "system", "content": SYSTEM}]
        if context := await prefetch(mcp, question):
            messages.append({"role": "system", "content": f"Tool results so far:\n{context}"})
        messages.append({"role": "user", "content": question})
        for _ in range(MAX_STEPS):
            resp = llm.chat.completions.create(
                model=MODEL, messages=messages, tools=tools, max_tokens=300,
                user="demo-agent",
                # Shows up on the gateway's spend logs and Phoenix traces.
                extra_body={"metadata": {"agent": "demo-agent", "tags": ["demo-agent"]}},
            )
            msg = resp.choices[0].message
            if not msg.tool_calls:
                return msg.content or ""
            messages.append(msg.model_dump(exclude_none=True))
            for call in msg.tool_calls:
                text = await tool(mcp, call.function.name, json.loads(call.function.arguments or "{}"))
                messages.append({"role": "tool", "tool_call_id": call.id, "content": text})
        return "(stopped after too many tool calls)"


def main() -> None:
    if len(sys.argv) >= 3 and sys.argv[1] == "ask":
        print(asyncio.run(ask(" ".join(sys.argv[2:]))))
    elif len(sys.argv) == 2 and sys.argv[1] == "idle":
        print("demo-agent ready: kubectl exec ... -- python agent.py ask '<question>'", flush=True)
        while True:
            time.sleep(3600)
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
