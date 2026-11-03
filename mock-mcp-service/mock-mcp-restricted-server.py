#!/usr/bin/env python3
"""Mock restricted MCP server for the Access Control demo.

It has one destructive tool, delete_customer_record. The gateway's Access
Control Forbid rule should block it before it reaches this server. If the
tool runs, the response says the policy was not applied.

Standalone on purpose: it is deployed as a single file from its own ConfigMap.
"""
import argparse
import json
import os
from http.server import BaseHTTPRequestHandler, HTTPServer

DEFAULT_PORT = int(os.environ.get("MCP_RESTRICTED_SERVER_PORT", 8200))
PROTOCOL_VERSION = "2025-06-18"
SERVER_NAME = "mock-mcp-restricted-server"
SERVER_VERSION = "0.1.0"

TOOLS = [
    {
        "name": "delete_customer_record",
        "description": "Permanently delete a customer record from the CRM. Destructive, irreversible.",
        "inputSchema": {
            "type": "object",
            "properties": {"customer_id": {"type": "string"}},
            "required": ["customer_id"],
        },
    }
]


def call_tool(name, args):
    if name == "delete_customer_record":
        cid = args.get("customer_id", "unknown")
        return {"content": [{"type": "text",
                             "text": f"(mock) deleted customer record {cid} -- this should have been blocked by policy!"}]}
    return {"content": [{"type": "text", "text": f"Unknown tool: {name}"}], "isError": True}


class RestrictedHandler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        print("[mock-mcp-restricted] " + (fmt % args))

    def _send_json(self, code, payload):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _send_empty(self, code):
        self.send_response(code)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_GET(self):
        if self.path.rstrip("/") == "/health":
            self._send_json(200, {"status": "ok"})
            return
        self._send_json(405, {"error": "use POST for MCP JSON-RPC"})

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(length) if length else b"{}"
        try:
            req = json.loads(raw or b"{}")
        except json.JSONDecodeError:
            self._send_json(400, {"jsonrpc": "2.0", "id": None,
                                  "error": {"code": -32700, "message": "parse error"}})
            return

        method = req.get("method", "")
        req_id = req.get("id")

        if method == "initialize":
            self._send_json(200, {
                "jsonrpc": "2.0", "id": req_id,
                "result": {
                    "protocolVersion": PROTOCOL_VERSION,
                    "capabilities": {"tools": {}},
                    "serverInfo": {"name": SERVER_NAME, "version": SERVER_VERSION},
                },
            })
            return

        if method.startswith("notifications/") or req_id is None:
            self._send_empty(202)
            return

        if method == "tools/list":
            self._send_json(200, {"jsonrpc": "2.0", "id": req_id, "result": {"tools": TOOLS}})
            return

        if method == "tools/call":
            params = req.get("params", {})
            result = call_tool(params.get("name"), params.get("arguments", {}))
            self._send_json(200, {"jsonrpc": "2.0", "id": req_id, "result": result})
            return

        self._send_json(200, {"jsonrpc": "2.0", "id": req_id,
                              "error": {"code": -32601, "message": f"method not found: {method}"}})


def make_server(port):
    return HTTPServer(("0.0.0.0", port), RestrictedHandler)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Mock restricted MCP server")
    parser.add_argument("--port", type=int, default=DEFAULT_PORT,
                        help="port to listen on (default: $MCP_RESTRICTED_SERVER_PORT or 8200)")
    port = parser.parse_args().port
    print(f"[mock-mcp-restricted] listening on :{port}")
    make_server(port).serve_forever()
