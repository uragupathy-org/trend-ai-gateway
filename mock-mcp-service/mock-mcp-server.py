#!/usr/bin/env python3
"""Mock MCP server (Streamable HTTP, JSON-RPC) for AI Gateway demos.

Tools: add_numbers, get_server_time. Standard library only, so it runs in
python:3.12-slim with the script mounted from a ConfigMap.
"""
import argparse
import datetime
import json
import os
from http.server import BaseHTTPRequestHandler, HTTPServer

DEFAULT_PORT = int(os.environ.get("MCP_SERVER_PORT", 8100))
PROTOCOL_VERSION = "2025-06-18"
SERVER_NAME = "mock-mcp-server"
SERVER_VERSION = "0.1.0"

TOOLS = [
    {
        "name": "add_numbers",
        "description": "Add two numbers together and return the sum.",
        "inputSchema": {
            "type": "object",
            "properties": {"a": {"type": "number"}, "b": {"type": "number"}},
            "required": ["a", "b"],
        },
    },
    {
        "name": "get_server_time",
        "description": "Get the current time on the mock MCP server.",
        "inputSchema": {"type": "object", "properties": {}},
    },
]


def text_result(text, is_error=False):
    result = {"content": [{"type": "text", "text": text}]}
    if is_error:
        result["isError"] = True
    return result


def call_tool(name, args):
    if name == "add_numbers":
        try:
            a = float(args.get("a", 0))
            b = float(args.get("b", 0))
        except (TypeError, ValueError):
            return text_result("add_numbers needs numeric 'a' and 'b'", is_error=True)
        total = int(a + b) if (a + b).is_integer() else a + b
        return text_result(f"{a:g} + {b:g} = {total}")
    if name == "get_server_time":
        now = datetime.datetime.now(datetime.timezone.utc).isoformat()
        return text_result(f"Mock MCP server time: {now}")
    return text_result(f"Unknown tool: {name}", is_error=True)


class MCPHandler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        print("[mock-mcp] " + (fmt % args))

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

        # Notifications carry no id and get no JSON-RPC response.
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

        # Unknown methods get a JSON-RPC error in a 200 body, as the gateway expects.
        self._send_json(200, {"jsonrpc": "2.0", "id": req_id,
                              "error": {"code": -32601, "message": f"method not found: {method}"}})


def make_server(port):
    return HTTPServer(("0.0.0.0", port), MCPHandler)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Mock MCP server (JSON-RPC over HTTP)")
    parser.add_argument("--port", type=int, default=DEFAULT_PORT,
                        help="port to listen on (default: $MCP_SERVER_PORT or 8100)")
    port = parser.parse_args().port
    server = make_server(port)
    print(f"[mock-mcp] listening on :{port}")
    server.serve_forever()
