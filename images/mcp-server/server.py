"""Tiny MCP server for the demo agent: support tickets and runbooks (fake data).

Streamable HTTP on :8000/mcp, stateless JSON responses. Read-only tools on
in-memory data — the point is the cage around it, not the tools.
"""

import os

import uvicorn
from mcp.server.mcpserver import MCPServer

TICKETS = {
    "TCK-1001": {"title": "Card payment declined at checkout", "status": "open",
                 "team": "payments", "runbook": "payments-declines"},
    "TCK-1002": {"title": "Password reset email never arrives", "status": "in progress",
                 "team": "support", "runbook": "email-delivery"},
    "TCK-1003": {"title": "Refund stuck in pending for 5 days", "status": "open",
                 "team": "payments", "runbook": "refunds-pending"},
}

RUNBOOKS = {
    "payments-declines": "1. Check the PSP status page. 2. Look up the decline code. "
                         "3. Codes 05/51: ask the customer to contact their bank.",
    "email-delivery": "1. Check the bounce list. 2. Verify SPF/DKIM for the domain. "
                      "3. Resend from the admin console.",
    "refunds-pending": "1. Refunds settle in 5-10 business days. 2. Past 10 days, "
                       "open a PSP case with the refund ID.",
}

server = MCPServer(
    name="support-tools",
    instructions="Look up support tickets and the runbook that resolves them.",
)


@server.tool()
def lookup_ticket(ticket_id: str) -> dict:
    """Return a support ticket (title, status, owning team, runbook id) by its ID, e.g. TCK-1001."""
    ticket = TICKETS.get(ticket_id.strip().upper())
    return {"ticket_id": ticket_id, **ticket} if ticket else {"error": f"no ticket {ticket_id}"}


@server.tool()
def get_runbook(runbook_id: str) -> str:
    """Return the steps of a runbook by its id, e.g. payments-declines."""
    return RUNBOOKS.get(runbook_id.strip(), f"no runbook {runbook_id}")


app = server.streamable_http_app(stateless_http=True, json_response=True, host="0.0.0.0")

if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=int(os.environ.get("PORT", "8000")), log_level="info")
