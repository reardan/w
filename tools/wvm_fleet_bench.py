#!/usr/bin/env python3
"""Measure real concurrent Linux box sessions through an already-running wvmd.

Example: python3 tools/wvm_fleet_bench.py --socket bin/wvmd.sock \
  --kernel /images/bzImage --initrd /images/agent.cpio --count 16 -- /bin/true
Uses no host-execution fallback. All sessions this tool creates are destroyed.
"""
import argparse
import json
import socket
import statistics
import time


def rpc(path, method, params=None):
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method,
                       "params": params or {}}, separators=(",", ":")).encode()
    with socket.socket(socket.AF_UNIX) as client:
        client.settimeout(15)
        client.connect(path)
        client.sendall(f"Content-Length: {len(body)}\r\n\r\n".encode() + body)
        header = bytearray()
        while not header.endswith(b"\r\n\r\n"):
            piece = client.recv(1)
            if not piece or len(header) > 128:
                raise RuntimeError("invalid daemon reply header")
            header.extend(piece)
        prefix = b"Content-Length: "
        if not header.startswith(prefix):
            raise RuntimeError("invalid daemon framing")
        length = int(header[len(prefix):-4])
        if not 0 <= length <= 65536:
            raise RuntimeError("oversized daemon reply")
        reply = bytearray()
        while len(reply) < length:
            piece = client.recv(length - len(reply))
            if not piece:
                raise RuntimeError("daemon disconnected")
            reply.extend(piece)
    result = json.loads(reply)
    if "error" in result:
        raise RuntimeError(str(result["error"]))
    return result["result"]


def distribution(values):
    if not values:
        return {"p50": None, "p95": None, "max": None}
    ordered = sorted(values)
    return {"p50": statistics.median(ordered),
            "p95": ordered[min(len(ordered) - 1, (len(ordered) * 95 + 99) // 100 - 1)],
            "max": max(ordered)}


def run(args):
    started = time.monotonic()
    sessions, pending, commands = set(), {}, {}
    launches, executions, failures, cleanup_errors = [], [], [], []
    before = rpc(args.socket, "stats")
    try:
        for _ in range(args.count):
            submitted = time.monotonic()
            response = rpc(args.socket, "vm_spawn", {
                "kernel": args.kernel, "initrd": args.initrd,
                "cpus": args.cpus, "memory_mb": args.memory_mb,
                "lease_ms": args.timeout * 1000, "timeout_ms": 30000})
            if "error" in response:
                failures.append(response["error"])
                continue
            session = response["session"]
            sessions.add(session)
            pending[session] = submitted
        while pending or commands:
            if time.monotonic() - started >= args.timeout:
                failures.append(f"benchmark deadline: {len(pending) + len(commands)} unfinished")
                break
            for session, submitted in list(pending.items()):
                status = rpc(args.socket, "vm_status", {"session": session})
                if status.get("state") == "ready":
                    launches.append((time.monotonic() - submitted) * 1000)
                    command_started = time.monotonic()
                    response = rpc(args.socket, "vm_exec", {
                        "session": session, "argv": args.command,
                        "timeout_ms": 30000, "output_limit": 4096})
                    if "error" in response:
                        failures.append(response["error"])
                        rpc(args.socket, "vm_destroy", {"session": session})
                        sessions.remove(session)
                    else:
                        commands[session] = command_started
                    del pending[session]
                elif status.get("state") == "failed" or "error" in status:
                    failures.append(status)
                    rpc(args.socket, "vm_destroy", {"session": session})
                    sessions.remove(session)
                    del pending[session]
            for session, command_started in list(commands.items()):
                result = rpc(args.socket, "vm_result", {"session": session, "length": 0})
                if result.get("state") in ("ready", "failed") or "error" in result:
                    executions.append((time.monotonic() - command_started) * 1000)
                    if result.get("status") != 0:
                        failures.append(result)
                    rpc(args.socket, "vm_destroy", {"session": session})
                    sessions.remove(session)
                    del commands[session]
            if pending or commands:
                time.sleep(0.01)
    finally:
        for session in sessions:
            try:
                rpc(args.socket, "vm_destroy", {"session": session})
            except (OSError, RuntimeError, ValueError) as error:
                cleanup_errors.append(str(error))
    elapsed = time.monotonic() - started
    return {"requested": args.count, "commands_completed": len(executions),
            "elapsed_seconds": elapsed, "commands_per_second": len(executions) / elapsed,
            "launch_including_queue_ms": distribution(launches),
            "command_including_poll_ms": distribution(executions),
            "failures": failures, "cleanup_errors": cleanup_errors,
            "stats_before": before, "stats_after_cleanup": rpc(args.socket, "stats")}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--socket", default="bin/wvmd.sock")
    parser.add_argument("--kernel", required=True)
    parser.add_argument("--initrd", required=True)
    parser.add_argument("--count", type=int, default=16)
    parser.add_argument("--cpus", type=int, default=1)
    parser.add_argument("--memory-mb", type=int, default=256)
    parser.add_argument("--timeout", type=int, default=120)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if args.command and args.command[0] == "--":
        args.command.pop(0)
    if not args.command:
        args.command = ["/bin/true"]
    if not 1 <= args.count <= 128 or not 1 <= args.timeout <= 3600:
        parser.error("count must be 1..128 and timeout 1..3600 seconds")
    result = run(args)
    print(json.dumps(result, sort_keys=True, indent=2))
    return bool(result["failures"] or result["cleanup_errors"])


if __name__ == "__main__":
    raise SystemExit(main())
