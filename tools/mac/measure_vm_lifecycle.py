#!/usr/bin/env python3
"""Measure homogeneous native Darwin VM lifecycle operations over real RPC."""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import signal
import socket
import statistics
import subprocess
import tempfile
import time
from vm_source_identity import source_identity


def command(*args):
    return subprocess.check_output(args, text=True).strip()


def rpc(path, method, params=None):
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params or {}},
                      separators=(",", ":")).encode()
    with socket.socket(socket.AF_UNIX) as channel:
        channel.settimeout(10)
        channel.connect(str(path))
        channel.sendall(f"Content-Length: {len(body)}\r\n\r\n".encode() + body)
        data = b""
        while b"\r\n\r\n" not in data:
            part = channel.recv(4096)
            assert part, "closed response header"
            data += part
            assert len(data) <= 32768, "oversized response"
        header, data = data.split(b"\r\n\r\n", 1)
        assert header.startswith(b"Content-Length: ")
        length = int(header[16:])
        assert 0 < length <= 16384
        while len(data) < length:
            part = channel.recv(length - len(data))
            assert part, "truncated response"
            data += part
        result = json.loads(data)
        assert result["jsonrpc"] == "2.0" and result["id"] == 1, result
        value = result["result"]
        assert "error" not in value, value
        return value


def ready(path, session):
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        result = rpc(path, "vm_status", {"session": session})
        if result["state"] == "ready":
            return result
        assert result["state"] != "failed", result
        time.sleep(0.001)
    raise RuntimeError("session did not become ready")


def execute(path, session, mode):
    rpc(path, "vm_exec", {"session": session, "argv": ["cell", mode],
                          "timeout_ms": 5000, "output_limit": 65536})
    ready(path, session)
    value = rpc(path, "vm_result", {"session": session, "length": 2048})
    expected = 7 if mode == "hello" else 0
    assert value["status"] == expected, value
    text = b"hello from an ARM64 cell" if mode == "hello" else b"cell allocator containers FP OK"
    assert text in bytes.fromhex(value["stdout_hex"]), value


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--worker", type=Path, required=True)
    parser.add_argument("--daemon", type=Path, required=True)
    parser.add_argument("--guest", type=Path, required=True)
    parser.add_argument("--samples", type=int, default=5)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if not 5 <= args.samples <= 100:
        parser.error("--samples must be 5..100")
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        raise RuntimeError("native Apple Silicon required; measurements cannot be skipped")
    worker, daemon, guest = (path.resolve() for path in (args.worker, args.daemon, args.guest))
    records = []
    semantics = {
        "daemon_process_start": "Popen through first successful capabilities RPC; no VM/template allocated",
        "cold_image_spawn_ready": "vm_spawn(image) through ready, including image validation, full template capture, fresh worker exec, create/destroy availability probe and private snapshot mapping; vCPU setup excluded until first command; first session of fresh daemon",
        "template_capture": "template_create(image) RPC through returned immutable backing handle; no running VM",
        "template_clone_spawn_ready": "vm_spawn(template) through ready, including fresh worker exec, create/destroy availability probe and private clone mapping; vCPU setup excluded until first command",
        "clone_first_command": "first hello vm_exec through ready and checked vm_result; includes worker's restore before command",
        "restore_after_dirty_ready": "vm_restore after allocator/container/FP workload through ready; worker replacement and private remapping included",
        "restored_first_command": "first hello after explicit restore through ready and checked vm_result; includes per-command restore",
    }
    with tempfile.TemporaryDirectory(prefix="wvm-latency-", dir="/tmp") as temporary:
        for sample in range(args.samples):
            path = Path(temporary) / f"sample-{sample}.sock"
            log_path = args.output.parent / f"lifecycle-daemon-{sample}.log"
            log_path.parent.mkdir(parents=True, exist_ok=True)
            with log_path.open("wb") as log:
                started = time.monotonic_ns()
                process = subprocess.Popen([daemon, "serve", "--socket", path, "--worker", worker,
                                            "--max-active", "1", "--max-pending", "1", "--memory-mb", "2048"],
                                           stdin=subprocess.DEVNULL, stdout=log, stderr=log,
                                           start_new_session=True)
                def record(name, begin):
                    records.append({"sample": sample, "operation": name,
                                    "milliseconds": (time.monotonic_ns() - begin) / 1e6})
                try:
                    deadline = time.monotonic() + 10
                    while not path.exists():
                        assert process.poll() is None, "daemon startup failure"
                        assert time.monotonic() < deadline, "daemon startup timeout"
                        time.sleep(0.001)
                    capabilities = rpc(path, "capabilities")
                    assert capabilities["host_backend"] == "hypervisor.framework"
                    record("daemon_process_start", started)
                    started = time.monotonic_ns()
                    cold = rpc(path, "vm_spawn", {"backend": "cell", "image": str(guest), "lease_ms": 60000})["session"]
                    ready(path, cold)
                    record("cold_image_spawn_ready", started)
                    execute(path, cold, "hello")
                    rpc(path, "vm_destroy", {"session": cold})
                    started = time.monotonic_ns()
                    template = rpc(path, "template_create", {"backend": "cell", "image": str(guest), "lease_ms": 60000})["template"]
                    record("template_capture", started)
                    started = time.monotonic_ns()
                    clone = rpc(path, "vm_spawn", {"backend": "cell", "template": template, "lease_ms": 60000})["session"]
                    ready(path, clone)
                    record("template_clone_spawn_ready", started)
                    started = time.monotonic_ns()
                    execute(path, clone, "hello")
                    record("clone_first_command", started)
                    execute(path, clone, "alloc")
                    started = time.monotonic_ns()
                    rpc(path, "vm_restore", {"session": clone})
                    ready(path, clone)
                    record("restore_after_dirty_ready", started)
                    started = time.monotonic_ns()
                    execute(path, clone, "hello")
                    record("restored_first_command", started)
                    rpc(path, "vm_destroy", {"session": clone})
                    rpc(path, "template_destroy", {"template": template})
                    stats = rpc(path, "stats")
                    assert stats["sessions"] == 0 and stats["templates"] == 0 and stats["active"] == 0, stats
                    rpc(path, "stop")
                    assert process.wait(timeout=5) == 0
                    print(f"PASS native lifecycle measurement sample {sample + 1}/{args.samples}", flush=True)
                finally:
                    if process.poll() is None:
                        os.killpg(process.pid, signal.SIGKILL)
                        process.wait(timeout=5)
    summary = {}
    for name in semantics:
        samples = sorted(record["milliseconds"] for record in records if record["operation"] == name)
        assert len(samples) == args.samples
        summary[name] = {"samples": len(samples), "min_ms": samples[0], "max_ms": samples[-1],
                         "p50_ms": statistics.median(samples),
                         **{f"p{p}_ms": samples[math.ceil(len(samples) * p / 100) - 1] for p in (95, 99)}}
    report = {
        "schema": "wvm-darwin-lifecycle-v1", "units": "milliseconds",
        "source_revision": command("git", "rev-parse", "HEAD"),
        "source_identity": source_identity(),
        "worktree_status": command("git", "status", "--short"),
        "host": {"os": command("sw_vers"), "model": command("sysctl", "-n", "hw.model"),
                 "chip": command("sysctl", "-n", "machdep.cpu.brand_string"),
                 "ram_bytes": int(command("sysctl", "-n", "hw.memsize"))},
        "guest": {"ram_bytes": 268435456, "image_bytes": guest.stat().st_size,
                  "sha256": hashlib.sha256(guest.read_bytes()).hexdigest()},
        "worker_sha256": hashlib.sha256(worker.read_bytes()).hexdigest(),
        "daemon_sha256": hashlib.sha256(daemon.read_bytes()).hexdigest(),
        "conditions": {
            "samples_per_operation": args.samples, "daemon": "fresh exec per sample; one active worker",
            "cold": "fresh worker/process state only; filesystem caches are not evicted",
            "backing": "new populated 256MiB template per capture; clone backing warm from capture",
            "timer": "Python time.monotonic_ns, end-to-end RPC; ready status polled every 1ms",
            "scheduler": "daemon's 10ms poll interval and scheduling latency are included",
            "signing": "worker/daemon signed before measurement; signing excluded",
            "quantiles": "p50 median; p95/p99 nearest rank; five samples cannot estimate tail latency reliably",
            "pool": "no pool measurements here; separately measured by ready-cell pool fixture",
        },
        "semantics": semantics, "runs": records, "summary": summary,
    }
    args.output.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(summary, indent=2), flush=True)
    print(f"Lifecycle evidence: {args.output}", flush=True)


if __name__ == "__main__":
    main()
