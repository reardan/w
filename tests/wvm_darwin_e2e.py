#!/usr/bin/env python3
"""Required native CLI/RPC lifecycle assertions; invoked by run_vm_tests.sh."""
import json
import math
import os
from pathlib import Path
import socket
import signal
import subprocess
import sys
import tempfile
import time

OUT = Path(sys.argv[1]).resolve()
WVM = OUT / "wvm_darwin"
WVMD = OUT / "wvmd_darwin"
GUEST = OUT / "wvm_darwin_fixture"
measurements = []


def cli(mode, status, text=None, options=(), arguments=(), stdin=None):
    started = time.monotonic()
    result = subprocess.run([str(WVM), "run", *options, str(GUEST), mode, *arguments],
                            input=stdin if stdin is not None else b"", stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            timeout=10, env={**os.environ, "W_VM_HOST_SECRET": "must-not-leak"})
    measurements.append({"kind": "cli-process-create-and-command", "mode": mode,
                         "milliseconds": (time.monotonic() - started) * 1000})
    assert result.returncode == status, (mode, result.returncode, result.stdout[:512], result.stderr[:512])
    if text is not None:
        assert text in result.stdout, (mode, result.stdout[:512], result.stderr[:512])
    assert len(result.stdout) <= 4194304, (mode, "unbounded output")
    print(f"PASS CLI {mode}: status {status}", flush=True)
    return result


def rpc(path, method, params=None):
    body = json.dumps({"jsonrpc": "2.0", "id": 31, "method": method, "params": params or {}}).encode()
    with socket.socket(socket.AF_UNIX) as channel:
        channel.settimeout(5)
        channel.connect(str(path))
        channel.sendall(f"Content-Length: {len(body)}\r\n\r\n".encode() + body)
        response = b""
        while b"\r\n\r\n" not in response:
            part = channel.recv(4096)
            assert part, "daemon closed before response"
            response += part
            assert len(response) < 32768, "unbounded response"
        header, response = response.split(b"\r\n\r\n", 1)
        assert header.startswith(b"Content-Length: ")
        length = int(header[16:])
        assert 0 < length <= 16384
        while len(response) < length:
            part = channel.recv(length - len(response))
            assert part, "daemon truncated response"
            response += part
        envelope = json.loads(response[:length])
        assert envelope["jsonrpc"] == "2.0" and envelope["id"] == 31
        return envelope["result"]


def wait_state(path, session, allowed, timeout=8):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        state = rpc(path, "vm_status", {"session": session})
        if state.get("state") in allowed:
            return state
        assert "error" not in state, state
        time.sleep(0.01)
    raise AssertionError(("timed out", session, allowed, state))


def main():
    capabilities = json.loads(subprocess.check_output([WVM, "capabilities"], timeout=5))
    assert capabilities["host_backend"] == "hypervisor.framework"
    assert capabilities["guest_arch"] == "arm64"
    for rejected in ("host_quotas", "live_checkpoints", "debugger", "shared_regions", "boxes", "filesystem", "network"):
        assert capabilities[rejected] is False, (rejected, capabilities)
    cli("hello", 7, b"hello from an ARM64 cell")
    cli("argv", 0, b"cell argv OK", arguments=("payload",))
    cli("alloc", 0, b"cell allocator containers FP OK")
    cli("deny", 0, b"cell denials OK")
    cli("memory", 0, b"cell memory OK")
    cli("exit", 37)
    cli("spin", 124, options=("--timeout-ms", "30"))
    for mode in ("monitor", "readonly", "unmapped", "nx", "hvc"):
        cli(mode, 139)
    cli("output", 125)
    # The CLI receives bounded stdin data, and an EOF never waits on a host fd.
    cli("input", 0, b"bounded input\n", stdin=b"bounded input\n")
    for option in (("--fs-root", "/tmp"), ("--net-allow", "127.0.0.1:1"), ("--max-threads", "2")):
        result = subprocess.run([WVM, "run", *option, GUEST, "hello"], capture_output=True, timeout=5)
        assert result.returncode != 0 and b"unsupported" in result.stderr, (option, result)
    daemon_tests()
    summaries = {}
    for kind in {value["kind"] for value in measurements}:
        samples = sorted(value["milliseconds"] for value in measurements if value["kind"] == kind)
        summaries[kind] = {"samples": len(samples), **{
            "p" + str(percentile): samples[min(len(samples) - 1, math.ceil(len(samples) * percentile / 100) - 1)]
            for percentile in (50, 95, 99)}}
    report = {"units": "milliseconds", "guest_ram_bytes": 268435456,
              "image_bytes": GUEST.stat().st_size,
              "conditions": "local sequential functional-gate samples; mixed modes, not a throughput benchmark",
              "samples": measurements, "summaries": summaries}
    (OUT / "lifecycle-measurements.json").write_text(json.dumps(report, indent=2) + "\n")
    print("PASS native CLI and daemon lifecycle", flush=True)


def daemon_tests():
    with tempfile.TemporaryDirectory(prefix="wvm-darwin-", dir="/tmp") as temporary:
        path = Path(temporary) / "daemon.sock"
        log = open(OUT / "daemon.log", "wb")
        daemon = subprocess.Popen([WVMD, "serve", "--socket", path, "--worker", WVM,
                                   "--max-active", "2", "--max-pending", "2", "--memory-mb", "2048"],
                                  stdout=log, stderr=log)
        try:
            deadline = time.monotonic() + 5
            while not path.exists():
                assert daemon.poll() is None, ("daemon exited during startup", daemon.returncode)
                assert time.monotonic() < deadline, "daemon socket startup timeout"
                time.sleep(0.01)
            assert path.stat().st_mode & 0o777 == 0o600, "socket permissions"
            client = json.loads(subprocess.check_output([WVMD, "call", path, "capabilities"], timeout=5))
            assert client["result"]["host_backend"] == "hypervisor.framework", client
            template_start = time.monotonic()
            created = rpc(path, "template_create", {"backend": "cell", "image": str(GUEST), "lease_ms": 60000})
            template = created["template"]
            measurements.append({"kind": "template-create", "milliseconds": (time.monotonic() - template_start) * 1000})

            def spawn(**extra):
                result = rpc(path, "vm_spawn", {"backend": "cell", "template": template,
                                                "cpus": 1, "memory_mb": 256, "lease_ms": 60000, **extra})
                assert "error" not in result, result
                return result["session"]

            def execute(session, mode, status=0, text=b"", timeout=1000, **options):
                start = time.monotonic()
                result = rpc(path, "vm_exec", {"session": session, "argv": ["cell", mode],
                                               "timeout_ms": timeout, "output_limit": 65536, **options})
                assert "command" in result, result
                state = wait_state(path, session, {"ready", "failed"})
                assert state["state"] == "ready", state
                answer = rpc(path, "vm_result", {"session": session, "offset": 0, "length": 2048})
                assert answer["status"] == status, answer
                assert text in bytes.fromhex(answer["stdout_hex"]), answer
                measurements.append({"kind": "ready-worker-command", "mode": mode,
                                     "milliseconds": (time.monotonic() - start) * 1000})
                return answer

            first = spawn()
            second = spawn()
            wait_state(path, first, {"ready"})
            wait_state(path, second, {"ready"})
            queued = spawn()
            assert rpc(path, "vm_status", {"session": queued})["state"] == "queued"
            assert "error" not in rpc(path, "vm_cancel", {"session": queued})
            for option, value in (("backend", "box"), ("cpus", 2), ("network", False),
                                  ("host_cpu_percent", 10), ("shared_regions", [])):
                bad = rpc(path, "vm_spawn", {"backend": "cell", "template": template, option: value})
                assert "error" in bad, (option, bad)
            for method in ("vm_snapshot", "debug", "region_create"):
                assert "error" in rpc(path, method, {"session": first})
            # Clone handles remain independent of the template registry entry.
            assert "error" not in rpc(path, "template_destroy", {"template": template})
            for _ in range(3):
                execute(first, "alloc", text=b"cell allocator containers FP OK")
                execute(second, "hello", 7, b"hello from an ARM64 cell")
            reset = rpc(path, "vm_restore", {"session": first})
            assert "error" not in reset, reset
            wait_state(path, first, {"ready"})
            execute(first, "alloc", text=b"cell allocator containers FP OK")
            execute(first, "spin", 124, timeout=30)
            execute(first, "hello", 7, b"hello from an ARM64 cell")
            echoed = execute(first, "input", text=b"binary\0input", stdin_hex=b"binary\0input".hex())
            assert bytes.fromhex(echoed["stdout_hex"]) == b"binary\0input"
            empty = execute(first, "input")
            assert bytes.fromhex(empty["stdout_hex"]) == b"", "stdin leaked across reset"
            assert "error" in rpc(path, "vm_exec", {"session": first, "argv": ["cell", "input"], "stdin_hex": "zz"})
            # Busy cancellation kills/reaps the worker and releases admission.
            started = rpc(path, "vm_exec", {"session": second, "argv": ["cell", "spin"], "timeout_ms": 600000})
            assert "command" in started, started
            assert "error" not in rpc(path, "vm_cancel", {"session": second})
            assert "error" in rpc(path, "vm_status", {"session": second})
            replacement = rpc(path, "vm_spawn", {"backend": "cell", "image": str(GUEST), "lease_ms": 60000})["session"]
            wait_state(path, replacement, {"ready"})
            execute(replacement, "hello", 7, b"hello from an ARM64 cell")
            assert "error" not in rpc(path, "vm_destroy", {"session": replacement})
            assert "error" not in rpc(path, "vm_destroy", {"session": first})
            leased = rpc(path, "vm_spawn", {"backend": "cell", "image": str(GUEST), "lease_ms": 100})["session"]
            deadline = time.monotonic() + 3
            while "error" not in rpc(path, "vm_status", {"session": leased}):
                assert time.monotonic() < deadline, "expired lease retained"
                time.sleep(0.02)
            # A crashed worker is reaped, marked failed and replaceable.
            crash = rpc(path, "vm_spawn", {"backend": "cell", "image": str(GUEST), "lease_ms": 60000})["session"]
            wait_state(path, crash, {"ready"})
            children = subprocess.check_output(["pgrep", "-P", str(daemon.pid)], text=True).split()
            assert len(children) == 1, children
            os.kill(int(children[0]), signal.SIGKILL)
            wait_state(path, crash, {"failed"})
            assert "error" not in rpc(path, "vm_destroy", {"session": crash})
            recovered = rpc(path, "vm_spawn", {"backend": "cell", "image": str(GUEST), "lease_ms": 60000})["session"]
            wait_state(path, recovered, {"ready"})
            execute(recovered, "hello", 7, b"hello from an ARM64 cell")
            assert "error" not in rpc(path, "vm_destroy", {"session": recovered})
            stats = rpc(path, "stats")
            assert stats["active"] == 0 and stats["queued"] == 0, stats
            assert "error" not in rpc(path, "stop")
            assert daemon.wait(timeout=5) == 0
            assert not path.exists(), "normal shutdown retained socket"
            daemon = subprocess.Popen([WVMD, "serve", "--socket", path, "--worker", WVM,
                                       "--max-active", "2", "--max-pending", "2", "--memory-mb", "2048"],
                                      stdout=log, stderr=log)
            deadline = time.monotonic() + 5
            while not path.exists():
                assert daemon.poll() is None and time.monotonic() < deadline
                time.sleep(0.01)
            # Abrupt daemon death during a CPU-only guest is detected by its
            # watchdog; the pipe breaks and the orphan exits after quiescing HV.
            orphan = rpc(path, "vm_spawn", {"backend": "cell", "image": str(GUEST), "lease_ms": 60000})["session"]
            wait_state(path, orphan, {"ready"})
            assert "command" in rpc(path, "vm_exec", {"session": orphan, "argv": ["cell", "spin"], "timeout_ms": 600000})
            children = subprocess.check_output(["pgrep", "-P", str(daemon.pid)], text=True).split()
            assert len(children) == 1, children
            worker = int(children[0])
            daemon.kill()
            assert daemon.wait(timeout=5) == -signal.SIGKILL
            deadline = time.monotonic() + 5
            while subprocess.run(["ps", "-p", str(worker)], stdout=subprocess.DEVNULL).returncode == 0:
                assert time.monotonic() < deadline, "orphan guest survived daemon death"
                time.sleep(0.02)
            print("PASS RPC templates, clones, queue, reset, timeout, cancel, replacement, leases, client", flush=True)
        finally:
            if daemon.poll() is None:
                daemon.terminate()
                try:
                    daemon.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    daemon.kill()
                    daemon.wait(timeout=5)
            log.close()


if __name__ == "__main__":
    main()
