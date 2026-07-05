#!/usr/bin/env python3
"""Smoke-test the stdio MCP server without third-party dependencies."""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


def write_message(proc: subprocess.Popen[bytes], message: dict) -> None:
    data = json.dumps(message, separators=(",", ":")).encode("utf-8")
    proc.stdin.write(f"Content-Length: {len(data)}\r\n\r\n".encode("ascii"))
    proc.stdin.write(data)
    proc.stdin.flush()


def read_message(proc: subprocess.Popen[bytes]) -> dict:
    headers: dict[str, str] = {}
    while True:
        line = proc.stdout.readline()
        if not line:
            raise RuntimeError("server closed stdout")
        if line in (b"\r\n", b"\n"):
            break
        name, value = line.decode("ascii").split(":", 1)
        headers[name.lower()] = value.strip()
    length = int(headers["content-length"])
    return json.loads(proc.stdout.read(length).decode("utf-8"))


def request(proc: subprocess.Popen[bytes], request_id: int, method: str, params: dict | None = None) -> dict:
    message = {"jsonrpc": "2.0", "id": request_id, "method": method}
    if params is not None:
        message["params"] = params
    write_message(proc, message)
    response = read_message(proc)
    if "error" in response:
        raise AssertionError(response["error"])
    return response["result"]


def tool_result(proc: subprocess.Popen[bytes], request_id: int, name: str, arguments: dict) -> dict:
    result = request(proc, request_id, "tools/call", {"name": name, "arguments": arguments})
    assert result["isError"] is False, result
    return json.loads(result["content"][0]["text"])


def main() -> int:
    proc = subprocess.Popen(
        [sys.executable, "tools/mcp/w_toolchain_mcp.py"],
        cwd=ROOT,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    assert proc.stdin is not None and proc.stdout is not None
    try:
        init = request(proc, 1, "initialize", {"protocolVersion": "2024-11-05", "capabilities": {}, "clientInfo": {"name": "mcp_test", "version": "0"}})
        assert init["serverInfo"]["name"] == "w-toolchain"
        write_message(proc, {"jsonrpc": "2.0", "method": "notifications/initialized", "params": {}})
        listed = request(proc, 2, "tools/list")
        names = {tool["name"] for tool in listed["tools"]}
        for expected in {"build", "verify", "run_tests", "check", "compile", "run", "repl_eval", "test_changed"}:
            assert expected in names
        changed = tool_result(proc, 3, "test_changed", {"files": ["structures/json.w"]})
        assert changed["targets"] == ["json_test", "json_rpc_test"], changed
        checked = tool_result(proc, 4, "check", {"file": "tests/hello.w"})
        assert checked["exit_code"] == 0, checked
        assert checked["diagnostics"] == [], checked
    finally:
        proc.kill()
        proc.wait()
    print("mcp test OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
