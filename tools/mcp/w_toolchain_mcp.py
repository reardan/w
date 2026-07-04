#!/usr/bin/env python3
"""Minimal stdlib-only MCP server for the W toolchain."""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
MAX_OUTPUT = 64_000
TARGET_RE = re.compile(r"^[a-z0-9_]+$")
DEFAULT_TIMEOUT = 120


TOOLS = [
    ("build", "Run make build", {}),
    ("verify", "Run make verify or verify_x64", {"arch": {"type": "string"}}),
    ("run_tests", "Run validated Makefile test targets", {"targets": {"type": "array", "items": {"type": "string"}}}),
    ("check", "Run w check --json and parse diagnostics", {"file": {"type": "string"}, "arch": {"type": "string"}}),
    ("compile", "Compile a W source file", {"file": {"type": "string"}, "arch": {"type": "string"}, "output": {"type": "string"}}),
    ("run", "Run a compiled binary", {"path": {"type": "string"}, "args": {"type": "array", "items": {"type": "string"}}, "stdin": {"type": "string"}}),
    ("repl_eval", "Evaluate entries in the W REPL", {"entries": {"type": "array", "items": {"type": "string"}}}),
    ("test_changed", "Map changed files to focused test targets", {"files": {"type": "array", "items": {"type": "string"}}}),
]


def read_message() -> dict | None:
    headers: dict[str, str] = {}
    while True:
        line = sys.stdin.buffer.readline()
        if not line:
            return None
        if line in (b"\r\n", b"\n"):
            break
        name, value = line.decode("ascii").split(":", 1)
        headers[name.lower()] = value.strip()
    length = int(headers.get("content-length", "0"))
    if length <= 0:
        return None
    return json.loads(sys.stdin.buffer.read(length).decode("utf-8"))


def write_message(message: dict) -> None:
    data = json.dumps(message, separators=(",", ":")).encode("utf-8")
    sys.stdout.buffer.write(f"Content-Length: {len(data)}\r\n\r\n".encode("ascii"))
    sys.stdout.buffer.write(data)
    sys.stdout.buffer.flush()


def truncate(text: str) -> str:
    if len(text) <= MAX_OUTPUT:
        return text
    return text[:MAX_OUTPUT] + "\n... truncated ...\n"


def run_cmd(cmd: list[str], *, stdin: str | None = None, timeout: int = DEFAULT_TIMEOUT) -> dict:
    (ROOT / "bin").mkdir(exist_ok=True)
    start = time.monotonic()
    try:
        proc = subprocess.run(
            cmd,
            cwd=ROOT,
            input=stdin,
            text=True,
            capture_output=True,
            timeout=timeout,
            check=False,
        )
        return {
            "exit_code": proc.returncode,
            "stdout": truncate(proc.stdout),
            "stderr": truncate(proc.stderr),
            "duration_ms": int((time.monotonic() - start) * 1000),
        }
    except subprocess.TimeoutExpired as exc:
        return {
            "exit_code": 124,
            "stdout": truncate(exc.stdout or ""),
            "stderr": truncate((exc.stderr or "") + f"\ntimeout after {timeout}s"),
            "duration_ms": int((time.monotonic() - start) * 1000),
        }


def ensure_wv2() -> None:
    if not (ROOT / "bin" / "wv2").exists():
        result = run_cmd(["make", "build"], timeout=240)
        if result["exit_code"] != 0:
            raise RuntimeError(json.dumps(result))


def ensure_wtest() -> None:
    if not (ROOT / "bin" / "wtest").exists():
        result = run_cmd(["make", "wtest"], timeout=180)
        if result["exit_code"] != 0:
            raise RuntimeError(json.dumps(result))


def parse_ndjson(text: str) -> list[dict]:
    records = []
    for line in text.splitlines():
        if line.strip():
            records.append(json.loads(line))
    return records


def tool_build(_args: dict) -> dict:
    return run_cmd(["make", "build"], timeout=240)


def tool_verify(args: dict) -> dict:
    target = "verify_x64" if args.get("arch") == "x64" else "verify"
    return run_cmd(["make", target], timeout=240)


def tool_run_tests(args: dict) -> dict:
    targets = args.get("targets") or []
    if not isinstance(targets, list) or not targets:
        raise ValueError("targets must be a non-empty array")
    for target in targets:
        if not isinstance(target, str) or not TARGET_RE.match(target):
            raise ValueError(f"invalid target: {target!r}")
    return run_cmd(["make", *targets], timeout=300)


def tool_check(args: dict) -> dict:
    ensure_wv2()
    file = args.get("file")
    if not isinstance(file, str) or not file:
        raise ValueError("file is required")
    cmd = ["./bin/wv2", "check", "--json"]
    if args.get("arch") == "x64":
        cmd.append("x64")
    cmd.append(file)
    result = run_cmd(cmd)
    result["diagnostics"] = parse_ndjson(result["stdout"])
    return result


def tool_compile(args: dict) -> dict:
    ensure_wv2()
    file = args.get("file")
    if not isinstance(file, str) or not file:
        raise ValueError("file is required")
    output = args.get("output") or "bin/mcp_compile_out"
    cmd = ["./bin/wv2"]
    if args.get("arch") == "x64":
        cmd.append("x64")
    cmd.extend([file, "-o", output])
    return run_cmd(cmd)


def tool_run(args: dict) -> dict:
    path = args.get("path")
    if not isinstance(path, str) or not path:
        raise ValueError("path is required")
    run_args = args.get("args") or []
    if not isinstance(run_args, list):
        raise ValueError("args must be an array")
    return run_cmd([path, *[str(arg) for arg in run_args]], stdin=args.get("stdin"))


def tool_repl_eval(args: dict) -> dict:
    ensure_wv2()
    entries = args.get("entries") or []
    if not isinstance(entries, list):
        raise ValueError("entries must be an array")
    if not (ROOT / "bin" / "repl").exists():
        result = run_cmd(["./bin/wv2", "repl.w", "-o", "./bin/repl"], timeout=180)
        if result["exit_code"] != 0:
            return result
    stdin = "\n".join(str(entry) for entry in entries) + "\n:quit\n"
    return run_cmd(["./bin/repl"], stdin=stdin)


def tool_test_changed(args: dict) -> dict:
    ensure_wtest()
    files = args.get("files") or []
    if not isinstance(files, list):
        raise ValueError("files must be an array")
    result = run_cmd(["./bin/wtest", "changed", *[str(path) for path in files]])
    result["targets"] = [line for line in result["stdout"].splitlines() if line]
    return result


TOOL_HANDLERS = {
    "build": tool_build,
    "verify": tool_verify,
    "run_tests": tool_run_tests,
    "check": tool_check,
    "compile": tool_compile,
    "run": tool_run,
    "repl_eval": tool_repl_eval,
    "test_changed": tool_test_changed,
}


def tool_schemas() -> list[dict]:
    schemas = []
    for name, description, properties in TOOLS:
        schemas.append(
            {
                "name": name,
                "description": description,
                "inputSchema": {
                    "type": "object",
                    "properties": properties,
                    "additionalProperties": True,
                },
            }
        )
    return schemas


def success(request_id: object, result: dict) -> None:
    write_message({"jsonrpc": "2.0", "id": request_id, "result": result})


def error(request_id: object, code: int, message: str) -> None:
    write_message({"jsonrpc": "2.0", "id": request_id, "error": {"code": code, "message": message}})


def handle(request: dict) -> None:
    method = request.get("method")
    request_id = request.get("id")
    if method == "initialize":
        success(
            request_id,
            {
                "protocolVersion": "2024-11-05",
                "capabilities": {"tools": {}},
                "serverInfo": {"name": "w-toolchain", "version": "0.1.0"},
            },
        )
    elif method == "notifications/initialized":
        return
    elif method == "tools/list":
        success(request_id, {"tools": tool_schemas()})
    elif method == "tools/call":
        params = request.get("params") or {}
        name = params.get("name")
        args = params.get("arguments") or {}
        handler = TOOL_HANDLERS.get(name)
        if handler is None:
            error(request_id, -32602, f"unknown tool: {name}")
            return
        try:
            result = handler(args)
            success(request_id, {"content": [{"type": "text", "text": json.dumps(result, sort_keys=True)}], "isError": False})
        except Exception as exc:  # MCP should report tool errors, not crash.
            success(request_id, {"content": [{"type": "text", "text": str(exc)}], "isError": True})
    else:
        error(request_id, -32601, f"method not found: {method}")


def main() -> int:
    os.chdir(ROOT)
    while True:
        request = read_message()
        if request is None:
            return 0
        handle(request)


if __name__ == "__main__":
    raise SystemExit(main())
