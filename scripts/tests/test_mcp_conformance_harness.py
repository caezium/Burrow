import importlib.util
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[2]
HARNESS = ROOT / "macos" / "scripts" / "mcp-conformance.py"

# Respond just far enough to reach each failure site. Every server records EOF,
# allowing the test to distinguish completed cleanup from an abandoned child.
SERVER = r'''
import json
import os
import sys
import time

mode = os.environ["BURROW_FAKE_MCP_MODE"]
pid = os.getpid()
with open(os.environ["BURROW_FAKE_MCP_PIDS"], "a") as log:
    log.write(str(pid) + "\n")

def text(value):
    return {"content": [{"type": "text", "text": json.dumps(value)}]}

for line in sys.stdin:
    request = json.loads(line)
    method = request["method"]
    params = request.get("params", {})
    version = params.get("_meta", {}).get("io.modelcontextprotocol/protocolVersion")
    result = {"resultType": "complete"}
    error = None
    if mode == "silent":
        continue
    if mode == "partial_reply":
        sys.stdout.write('{"jsonrpc":"2.0"')
        sys.stdout.flush()
        continue
    if mode == "malformed_discovery" and method == "server/discover":
        print("not json", flush=True)
        continue
    if (mode == "discovery_error" and method == "server/discover") or (mode == "tools_error" and method == "tools/list"):
        error = {"code": -32603, "message": "fixture error"}
    elif method == "initialize":
        print("not json from the legacy client", flush=True)
        continue
    elif version == "1999-01-01":
        error = {"code": -32022, "data": {"supported": ["2026-07-28"]}}
    elif method == "server/discover":
        result.update({"supportedVersions": ["2026-07-28", "2024-11-05"], "ttlMs": 1,
                       "cacheScope": "private", "capabilities": {"tools": {}, "extensions": {}},
                       "instructions": "fixture instructions " * 4})
    elif method == "tools/list":
        result["tools"] = [{"name": "burrow_clean"}, {"name": "burrow_report"}]
    elif method == "tools/call":
        name = params["name"]
        payload = {"entries": [], "window_minutes": 5} if name == "burrow_agent_audit" else {"findings": [], "basis": "24h"}
        result.update(text(payload))
        if name != "burrow_report":
            result["structuredContent"] = payload
    elif method == "resources/list":
        result["resources"] = [{"uri": "burrow://doctor"}]
    elif method == "resources/templates/list":
        result["resourceTemplates"] = []
    elif method == "resources/read":
        uri = params["uri"]
        if uri in ("burrow://nope", "burrow://history/notanumber"):
            error = {"code": -32602}
        else:
            result["contents"] = [{"uri": uri, "mimeType": "application/json", "text": json.dumps({"checks": [], "count": 1})}]
    elif method == "prompts/list":
        result["prompts"] = []
    elif method == "prompts/get":
        if params["name"] == "investigate_process":
            error = {"code": -32602}
        else:
            result["messages"] = [{"role": "user", "content": {"text": "120"}}]
    elif method == "completion/complete":
        result["completion"] = {"values": ["peak_cpu", "peak_mem"]}
    response = {"jsonrpc": "2.0", "id": request["id"]}
    response["error" if error else "result"] = error or result
    print(json.dumps(response), flush=True)

with open(os.environ["BURROW_FAKE_MCP_EXITS"], "a") as log:
    log.write(str(pid) + "\n")
if mode == "ignore_eof":
    while True:
        time.sleep(1)
'''


class MCPConformanceHarnessTests(unittest.TestCase):
    @unittest.skipUnless(os.name == "posix", "the macOS harness polls POSIX pipes")
    def test_silent_and_partial_replies_timeout_with_a_verdict_and_reaped_child(self):
        # Run the actual harness with a short request deadline, bounded by an
        # outer process timeout so a regression cannot hang this test runner.
        driver = '''import importlib.util, sys
spec = importlib.util.spec_from_file_location("conformance", sys.argv[1])
harness = importlib.util.module_from_spec(spec)
spec.loader.exec_module(harness)
harness.REQUEST_TIMEOUT = 0.2
sys.exit(harness.main([sys.argv[2]]))
'''
        for mode in ["silent", "partial_reply"]:
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                server = root / "fake-server"
                server.write_text(f"#!{sys.executable}\n" + SERVER, encoding="utf-8")
                server.chmod(0o700)
                pids = root / "pids"
                exits = root / "exits"
                result = subprocess.run(
                    [sys.executable, "-c", driver, str(HARNESS), str(server)],
                    env={**os.environ, "BURROW_FAKE_MCP_MODE": mode,
                         "BURROW_FAKE_MCP_PIDS": str(pids), "BURROW_FAKE_MCP_EXITS": str(exits)},
                    capture_output=True, text=True, timeout=5,
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("server/discover timed out waiting for a reply", result.stdout)
                self.assertIn("FAILURES: 1", result.stdout)
                self.assertNotIn("Traceback", result.stderr)
                self.assertEqual(exits.read_text().splitlines(), pids.read_text().splitlines())
                for value in pids.read_text().splitlines():
                    with self.assertRaises(ProcessLookupError):
                        os.kill(int(value), 0)

    @unittest.skipUnless(os.name == "posix", "executable fixture and PID probing use POSIX")
    def test_protocol_failures_print_verdict_and_reap_every_spawned_server(self):
        for mode, client_count in [
            ("malformed_discovery", 1),
            ("discovery_error", 1),
            ("tools_error", 1),
            ("legacy_error", 3),
        ]:
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                server = root / "fake-server"
                server.write_text(f"#!{sys.executable}\n" + SERVER, encoding="utf-8")
                server.chmod(0o700)
                pids = root / "pids"
                exits = root / "exits"
                result = subprocess.run(
                    [sys.executable, str(HARNESS), str(server)],
                    env={**os.environ, "BURROW_FAKE_MCP_MODE": mode,
                         "BURROW_FAKE_MCP_PIDS": str(pids), "BURROW_FAKE_MCP_EXITS": str(exits)},
                    capture_output=True, text=True, timeout=20,
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("FAIL harness completed:", result.stdout)
                self.assertIn("FAILURES:", result.stdout)
                self.assertNotIn("Traceback", result.stderr)
                spawned = [int(value) for value in pids.read_text().splitlines()]
                self.assertEqual(len(spawned), client_count, result.stdout)
                self.assertEqual(set(exits.read_text().splitlines()), {str(pid) for pid in spawned})
                for pid in spawned:
                    with self.assertRaises(ProcessLookupError, msg=f"server {pid} must be reaped"):
                        os.kill(pid, 0)

    def test_launch_failure_also_prints_a_failure_verdict(self):
        with tempfile.TemporaryDirectory() as directory:
            result = subprocess.run(
                [sys.executable, str(HARNESS), str(Path(directory) / "missing")],
                capture_output=True, text=True, timeout=5,
            )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("FileNotFoundError", result.stdout)
        self.assertIn("FAILURES: 1", result.stdout)

    @unittest.skipUnless(os.name == "posix", "executable fixture and PID probing use POSIX")
    def test_close_kills_then_reaps_and_is_idempotent(self):
        spec = importlib.util.spec_from_file_location("burrow_mcp_conformance", HARNESS)
        harness = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(harness)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            server = root / "fake-server"
            server.write_text(f"#!{sys.executable}\n" + SERVER, encoding="utf-8")
            server.chmod(0o700)
            harness.BIN = str(server)
            with mock.patch.dict(os.environ, {
                "BURROW_FAKE_MCP_MODE": "ignore_eof", "BURROW_FAKE_MCP_PIDS": str(root / "pids"),
                "BURROW_FAKE_MCP_EXITS": str(root / "exits"),
            }):
                client = harness.Client()
                try:
                    client.result("server/discover")
                    client.close(grace_period=0.1)
                    client.close(grace_period=0.1)
                    self.assertLess(client.proc.returncode, 0, "the server ignores EOF and requires a kill")
                    self.assertTrue(client.proc.stdin.closed)
                    self.assertTrue(client.proc.stdout.closed)
                    with self.assertRaises(ProcessLookupError):
                        os.kill(client.proc.pid, 0)
                finally:
                    if client.proc.poll() is None:
                        client.proc.kill()
                        client.proc.wait()


if __name__ == "__main__":
    unittest.main()
