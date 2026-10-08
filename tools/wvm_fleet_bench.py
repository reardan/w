#!/usr/bin/env python3
"""Measure real concurrent Linux box sessions through an already-running wvmd.

Example: python3 tools/wvm_fleet_bench.py --socket bin/wvmd.sock \
  --kernel /images/bzImage --initrd /images/agent.cpio --count 16 -- /bin/true
Uses no host-execution fallback. All sessions this tool creates are destroyed.
"""
import argparse
import ctypes
import mmap
import os
import json
import socket
import statistics
import struct
from pathlib import Path
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



def descendants(pid):
    found = []
    for child in Path(f"/proc/{pid}/task/{pid}/children").read_text().split():
        child = int(child)
        found.append(child)
        try:
            found.extend(descendants(child))
        except FileNotFoundError:
            pass
    return found


def template_residency(daemon):
    # mincore observes residency without faulting the sealed template into RAM.
    # Report separately: these pages overlap mappings and cannot be added to PSS.
    libc = ctypes.CDLL(None, use_errno=True)
    resident, size, seen = 0, 0, set()
    for path in Path(f"/proc/{daemon}/fd").iterdir():
        try:
            if "/memfd:wvm-linux-ram" not in os.readlink(path):
                continue
            with path.open("rb") as backing:
                stat = os.fstat(backing.fileno())
                key = (stat.st_dev, stat.st_ino)
                if key in seen:
                    continue
                seen.add(key)
                pages = (stat.st_size + mmap.PAGESIZE - 1) // mmap.PAGESIZE
                with mmap.mmap(backing.fileno(), stat.st_size, flags=mmap.MAP_PRIVATE,
                               prot=mmap.PROT_READ | mmap.PROT_WRITE) as mapped:
                    pointer = ctypes.c_char.from_buffer(mapped)
                    vector = (ctypes.c_ubyte * pages)()
                    code = libc.mincore(ctypes.c_void_p(ctypes.addressof(pointer)),
                                        ctypes.c_size_t(stat.st_size), vector)
                    del pointer
                    if code != 0:
                        raise OSError(ctypes.get_errno(), "mincore")
                    resident += sum(value & 1 for value in vector) * mmap.PAGESIZE
                size += stat.st_size
        except FileNotFoundError:
            continue
    return {"resident_kib": resident // 1024, "size_kib": size // 1024,
            "backings": len(seen), "scope": "overlaps QEMU mappings; do not add to PSS"}


def memory_sample(daemon):
    # Whole-process PSS includes QEMU code/libraries. The named CoW RAM subset
    # is separately measurable; anonymous cold RAM has no equivalent label.
    keys = ["Rss", "Pss", "Shared_Clean", "Shared_Dirty", "Private_Clean", "Private_Dirty"]
    total = {key: 0 for key in keys}
    ram = dict(total)
    ram["Anonymous"] = 0
    processes = []
    for pid in descendants(daemon):
        try:
            if not Path(f"/proc/{pid}/exe").readlink().name.startswith("qemu-system-"):
                continue
            rollup = Path(f"/proc/{pid}/smaps_rollup").read_text()
            smaps = Path(f"/proc/{pid}/smaps").read_text()
        except FileNotFoundError:
            continue
        processes.append(pid)
        for line in rollup.splitlines():
            key = line.split(":", 1)[0]
            if key in total:
                total[key] += int(line.split()[1])
        active = False
        for line in smaps.splitlines():
            if "-" in line.split()[0]:
                active = "/memfd:wvm-linux-ram" in line
            elif active:
                key = line.split(":", 1)[0]
                if key in ram:
                    ram[key] += int(line.split()[1])
    templates = template_residency(daemon)
    # Replace mapped RAM PSS with the complete resident sealed backing plus
    # anonymous CoW pages; this includes unaccessed template pages once.
    inclusive = total["Pss"] - ram["Pss"] + templates["resident_kib"] + ram["Anonymous"]
    return {"qemu_processes": len(processes), "qemu_total_kib": total,
            "named_cow_ram_kib": ram, "sealed_templates": templates,
            "template_inclusive_estimate_kib": inclusive,
            "scope": "QEMU non-RAM PSS + complete template residency + anonymous private CoW; shared counts double-count pages; excludes host KVM/kernel overhead"}


def compare(args):
    # An idle owned daemon makes process attribution and cleanup validation
    # meaningful. Width must fit admission capacity; a timeout is a hard error.
    before = rpc(args.socket, "stats")
    if any(before.get(key, 0) for key in ("active", "queued", "template_reserved_mb", "shared_region_bytes")):
        raise RuntimeError("comparison requires an idle daemon without templates or regions")
    with socket.socket(socket.AF_UNIX) as client:
        client.connect(args.socket)
        daemon = struct.unpack("3i", client.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, 12))[0]
    owned, template = set(), None
    deadline = time.monotonic() + args.timeout
    launch = {"kernel": args.kernel, "initrd": args.initrd, "cpus": args.cpus,
              "memory_mb": args.memory_mb, "lease_ms": args.timeout * 1000, "timeout_ms": 30000}

    def wait_ready(session, command=None):
        while time.monotonic() < deadline:
            status = rpc(args.socket, "vm_result" if command else "vm_status",
                         {"session": session, "length": 0})
            if status.get("state") == "failed" or "error" in status:
                raise RuntimeError(str(status))
            if status.get("state") == "ready" and (command is None or status.get("command") == command):
                if command and status.get("status") != 0:
                    raise RuntimeError(str(status))
                return status
            time.sleep(.005)
        raise RuntimeError("comparison deadline; width may exceed daemon capacity")

    def spawn(params):
        session = rpc(args.socket, "vm_spawn", params)["session"]
        owned.add(session)
        return session

    def retire(session):
        rpc(args.socket, "vm_destroy", {"session": session})
        owned.remove(session)

    def wave(params, width, repeats=1):
        pending = [(spawn(params), time.monotonic()) for _ in range(width)]
        launches = []
        for session, start in pending:
            wait_ready(session)
            launches.append((time.monotonic() - start) * 1000)
        executions = []
        for _ in range(repeats):
            commands = []
            for session, _ in pending:
                start = time.monotonic()
                command = rpc(args.socket, "vm_exec", {"session": session, "argv": args.command,
                              "timeout_ms": 30000, "output_limit": 4096})["command"]
                commands.append((session, command, start))
            for session, command, start in commands:
                wait_ready(session, command)
                executions.append((time.monotonic() - start) * 1000)
        memory = memory_sample(daemon)
        if memory["qemu_processes"] != width:
            raise RuntimeError("unexpected QEMU process count in memory sample")
        for session, _ in pending:
            retire(session)
        return {"launch_including_poll_ms": distribution(launches),
                "command_including_poll_ms": distribution(executions), "memory": memory,
                "commands": len(executions)}

    result = {"width": args.width, "rounds": args.count, "stats_before": before}
    try:
        result["cold"] = [wave(launch, args.width) for _ in range(args.count)]
        source = spawn(launch)
        wait_ready(source)
        start = time.monotonic()
        command = rpc(args.socket, "template_create", {"backend": "box", "session": source,
                      "lease_ms": args.timeout * 1000})["command"]
        template = wait_ready(source, command)["template"]
        result["capture_ms"] = (time.monotonic() - start) * 1000
        retire(source)
        clone = {"backend": "box", "template": template, "lease_ms": args.timeout * 1000}
        result["cow"] = [wave(clone, args.width) for _ in range(args.count)]
        result["persistent_cow_reuse"] = wave(clone, args.width, args.count)
    finally:
        for session in list(owned):
            retire(session)
        if template is not None:
            rpc(args.socket, "template_destroy", {"template": template})
    after = rpc(args.socket, "stats")
    result["stats_after_cleanup"] = after
    for key in ("active", "queued", "cpus", "memory_mb", "workspace_reserved_mb",
                "template_reserved_mb", "shared_region_bytes", "cleanup_failures"):
        if after[key] != before[key]:
            raise RuntimeError(f"resource counter did not return to baseline: {key}")
    result["failures"], result["cleanup_errors"] = [], []
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--socket", default="bin/wvmd.sock")
    parser.add_argument("--kernel", required=True)
    parser.add_argument("--initrd", required=True)
    parser.add_argument("--count", type=int, default=16)
    parser.add_argument("--compare", action="store_true", help="cold/CoW/reused fleets; count is rounds")
    parser.add_argument("--width", type=int, default=4, help="concurrent guests in comparison waves")
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
    if not 1 <= args.width <= 64:
        parser.error("width must be 1..64")
    result = compare(args) if args.compare else run(args)
    print(json.dumps(result, sort_keys=True, indent=2))
    return bool(result["failures"] or result["cleanup_errors"])


if __name__ == "__main__":
    raise SystemExit(main())
