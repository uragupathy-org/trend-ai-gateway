"""Tests for the mock MCP servers. Run from the repo root:

    python3 -m unittest discover -s mock-mcp-service/tests -v
"""
import importlib.util
import json
import pathlib
import threading
import unittest
import urllib.error
import urllib.request

HERE = pathlib.Path(__file__).resolve().parent.parent


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, HERE / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


MCP = load("mock_mcp_server", "mock-mcp-server.py")
RESTRICTED = load("mock_mcp_restricted_server", "mock-mcp-restricted-server.py")


class ServerCase(unittest.TestCase):
    module = None

    def setUp(self):
        self.server = self.module.make_server(0)
        self.port = self.server.server_address[1]
        self.url = f"http://127.0.0.1:{self.port}/"
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()

    def rpc(self, payload):
        req = urllib.request.Request(
            self.url, data=json.dumps(payload).encode(),
            headers={"Content-Type": "application/json",
                     "Accept": "application/json, text/event-stream"},
            method="POST",
        )
        try:
            with urllib.request.urlopen(req, timeout=5) as resp:
                body = resp.read().decode()
                return resp.status, (json.loads(body) if body else None)
        except urllib.error.HTTPError as e:
            return e.code, None


class MockMcpTests(ServerCase):
    module = MCP

    def test_health(self):
        with urllib.request.urlopen(self.url + "health", timeout=5) as resp:
            self.assertEqual(resp.status, 200)

    def test_get_other_path_is_405(self):
        with self.assertRaises(urllib.error.HTTPError) as ctx:
            urllib.request.urlopen(self.url + "nope", timeout=5)
        self.assertEqual(ctx.exception.code, 405)

    def test_initialize_handshake(self):
        status, body = self.rpc({"jsonrpc": "2.0", "id": 0, "method": "initialize",
                                 "params": {"protocolVersion": "2025-06-18", "capabilities": {},
                                            "clientInfo": {"name": "test", "version": "1"}}})
        self.assertEqual(status, 200)
        self.assertEqual(body["result"]["protocolVersion"], "2025-06-18")
        self.assertIn("tools", body["result"]["capabilities"])

    def test_notification_returns_202_with_empty_body(self):
        req = urllib.request.Request(
            self.url, data=json.dumps({"jsonrpc": "2.0", "method": "notifications/initialized"}).encode(),
            headers={"Content-Type": "application/json"}, method="POST")
        with urllib.request.urlopen(req, timeout=5) as resp:
            self.assertEqual(resp.status, 202)
            self.assertEqual(resp.read(), b"")

    def test_tools_list(self):
        _, body = self.rpc({"jsonrpc": "2.0", "id": 1, "method": "tools/list"})
        names = [t["name"] for t in body["result"]["tools"]]
        self.assertEqual(names, ["add_numbers", "get_server_time"])

    def test_add_numbers(self):
        _, body = self.rpc({"jsonrpc": "2.0", "id": 2, "method": "tools/call",
                            "params": {"name": "add_numbers", "arguments": {"a": 3, "b": 4}}})
        self.assertEqual(body["result"]["content"][0]["text"], "3 + 4 = 7")

    def test_add_numbers_rejects_non_numeric(self):
        _, body = self.rpc({"jsonrpc": "2.0", "id": 3, "method": "tools/call",
                            "params": {"name": "add_numbers", "arguments": {"a": "x", "b": 1}}})
        self.assertTrue(body["result"]["isError"])

    def test_get_server_time(self):
        _, body = self.rpc({"jsonrpc": "2.0", "id": 4, "method": "tools/call",
                            "params": {"name": "get_server_time", "arguments": {}}})
        self.assertIn("Mock MCP server time:", body["result"]["content"][0]["text"])

    def test_unknown_method_is_jsonrpc_error_in_200_body(self):
        status, body = self.rpc({"jsonrpc": "2.0", "id": 5, "method": "bogus"})
        self.assertEqual(status, 200)
        self.assertEqual(body["error"]["code"], -32601)

    def test_bad_json_is_400(self):
        req = urllib.request.Request(self.url, data=b"{not json",
                                     headers={"Content-Type": "application/json"}, method="POST")
        with self.assertRaises(urllib.error.HTTPError) as ctx:
            urllib.request.urlopen(req, timeout=5)
        self.assertEqual(ctx.exception.code, 400)


class RestrictedMcpTests(ServerCase):
    module = RESTRICTED

    def test_only_destructive_tool_listed(self):
        _, body = self.rpc({"jsonrpc": "2.0", "id": 1, "method": "tools/list"})
        self.assertEqual([t["name"] for t in body["result"]["tools"]], ["delete_customer_record"])

    def test_tool_runs_only_if_policy_missed_it(self):
        _, body = self.rpc({"jsonrpc": "2.0", "id": 2, "method": "tools/call",
                            "params": {"name": "delete_customer_record",
                                       "arguments": {"customer_id": "CUST-10492"}}})
        self.assertIn("should have been blocked by policy", body["result"]["content"][0]["text"])


if __name__ == "__main__":
    unittest.main()
