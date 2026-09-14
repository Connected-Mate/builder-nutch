#!/usr/bin/env python3
"""Real-process stdio tests using the exact production server and isolated storage."""
import json
import os
from pathlib import Path
import select
import stat
import subprocess
import tempfile
import threading

ROOT = Path(__file__).resolve().parents[1]

with tempfile.TemporaryDirectory(prefix="builder-nutch-mcp-test-") as temp:
    temporary = Path(temp)
    harness = temporary / "Harness.swift"
    harness.write_text('''import Foundation
import Darwin
@main struct Harness {
    static func main() {
        let repository = CustomAssistantRepository(root: URL(fileURLWithPath: CommandLine.arguments[1]))
        exit(CustomAssistantMCPServer.run(repository: repository))
    }
}
''')
    binary = temporary / "mcp-test"
    subprocess.run(["swiftc", str(ROOT / "Sources/Assistants/CustomAssistantConfiguration.swift"),
                    str(ROOT / "Sources/Assistants/CustomAssistantUsage.swift"),
                    str(ROOT / "Sources/Assistants/CustomAssistantMCPServer.swift"),
                    str(harness), "-o", str(binary)], check=True, timeout=120)
    catalog = temporary / "catalog"
    class Client:
        def __init__(self, root=catalog):
            self.process = subprocess.Popen([str(binary), str(root)], stdin=subprocess.PIPE,
                                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            self.counter = 0
        def request(self, method, params=None):
            self.counter += 1
            message = {"jsonrpc": "2.0", "id": self.counter, "method": method}
            if params is not None:
                message["params"] = params
            return self.raw(json.dumps(message).encode() + b"\n")
        def raw(self, message):
            self.process.stdin.write(message)
            self.process.stdin.flush()
            assert select.select([self.process.stdout], [], [], 8)[0], "MCP response timed out"
            line = self.process.stdout.readline()
            assert line, self.process.stderr.read().decode()
            return json.loads(line)
        def initialize(self, version="2025-11-25"):
            response = self.request("initialize", {"protocolVersion": version,
                "capabilities": {}, "clientInfo": {"name": "roundtrip-test", "version": "1"}})
            assert response["result"]["protocolVersion"] in [version, "2025-11-25"]
            self.process.stdin.write(b'{"jsonrpc":"2.0","method":"notifications/initialized"}\n')
            self.process.stdin.flush()
        def tool(self, name, arguments):
            return self.request("tools/call", {"name": name, "arguments": arguments})["result"]
        def close(self):
            self.process.stdin.close()
            assert self.process.wait(timeout=5) == 0
            assert not self.process.stderr.read()

    def value(result):
        assert not result["isError"], result
        return json.loads(result["content"][0]["text"])

    client = Client()
    assert client.request("tools/list")["error"]["code"] == -32002
    assert client.raw(b'{broken}\n')["error"]["code"] == -32700
    client.initialize()
    names = {tool["name"] for tool in client.request("tools/list")["result"]["tools"]}
    assert names == {"configure_assistant", "list_assistants", "report_usage"}
    profile = value(client.tool("configure_assistant", {"name": "Research helper", "website": "https://example.com/assistant",
        "instructions": "Be concise. Réponds en français.", "usageNote": "Observed usage only"}))
    identity = profile["id"]
    assert profile["instructions"].endswith("français.")
    assert value(client.tool("list_assistants", {}))[0]["id"] == identity
    for invalid in ["file:///tmp/test", "javascript:alert(1)", "http://example.com", "https://example.com?token=secret",
                    "https://user:pass@example.com", "https://127.0.0.1", "https://host.local", "https://example.com:22"]:
        assert client.tool("configure_assistant", {"name": "Invalid", "website": invalid})["isError"]
    assert client.tool("configure_assistant", {"name": "Invalid", "website": "https://example.com", "apiKey": "not-a-real-key"})["isError"]
    assert client.tool("configure_assistant", {"name": "Invalid", "website": "https://example.com", "id": "bad"})["isError"]
    assert client.tool("list_assistants", {"path": "/tmp"})["isError"]
    from datetime import datetime, timezone, timedelta
    now = datetime.now(timezone.utc).replace(microsecond=0)
    observed = now.isoformat().replace("+00:00", "Z")
    reading = {"id": identity, "limits": [{"label": "Session", "usedPercent": 42.5}],
               "observedAt": observed, "source": "Account subscription page"}
    result = value(client.tool("report_usage", reading))
    assert result["usage"]["limits"][0]["usedPercent"] == 42.5
    for invalid_percent in [-1, 101, True, "42"]:
        invalid = dict(reading, limits=[{"label": "Session", "usedPercent": invalid_percent}])
        assert client.tool("report_usage", invalid)["isError"]
    assert client.tool("report_usage", dict(reading, observedAt=(now + timedelta(days=1)).isoformat()))["isError"]
    assert client.tool("report_usage", dict(reading, observedAt=(now - timedelta(days=1)).isoformat()))["isError"]
    assert client.tool("report_usage", dict(reading, limits=[]))["isError"]
    renamed = value(client.tool("configure_assistant", {"id": identity, "name": "Research renamed", "website": "https://example.com"}))
    assert renamed["usage"]["limits"][0]["usedPercent"] == 42.5
    assert renamed["instructions"] == profile["instructions"]
    assert renamed["usageNote"] == profile["usageNote"]
    assert value(client.tool("configure_assistant", {"name": "research RENAMED", "website": "https://example.com"}))["id"] == identity
    assert stat.S_IMODE(catalog.stat().st_mode) == 0o700
    assert stat.S_IMODE((catalog / "assistants.json").stat().st_mode) == 0o600
    client.close()

    # Independent processes serialize writes without dropping either profile.
    clients = [Client(), Client()]
    for connection in clients: connection.initialize("2025-03-26")
    failures = []
    def create(index):
        try:
            value(clients[index].tool("configure_assistant", {"name": f"Parallel {index}", "website": "https://example.com"}))
        except BaseException as error:
            failures.append(error)
    threads = [threading.Thread(target=create, args=(index,)) for index in range(2)]
    for thread in threads: thread.start()
    for thread in threads: thread.join(10)
    assert not failures, failures
    assert len(value(clients[0].tool("list_assistants", {}))) == 3
    for connection in clients: connection.close()

    # A malformed catalog is preserved, and symlink targets are never touched.
    original = b'{"damaged":true}'
    (catalog / "assistants.json").write_bytes(original)
    client = Client(); client.initialize()
    assert client.tool("configure_assistant", {"name": "Preserve", "website": "https://example.com"})["isError"]
    assert (catalog / "assistants.json").read_bytes() == original
    client.close()
    outside = temporary / "outside.json"
    outside.write_text("[]")
    (catalog / "assistants.json").unlink()
    (catalog / "assistants.json").symlink_to(outside)
    client = Client(); client.initialize()
    assert client.tool("configure_assistant", {"name": "Symlink", "website": "https://example.com"})["isError"]
    assert outside.read_text() == "[]"
    client.close()
    alias = temporary / "catalog-alias"
    alias.symlink_to(catalog, target_is_directory=True)
    client = Client(alias); client.initialize()
    assert client.tool("list_assistants", {})["isError"]
    client.close()

print("PASS: real stdio lifecycle, configure/list/report/update, validation, concurrent processes, persistence, private permissions, corrupt-file preservation, symlink protection")
