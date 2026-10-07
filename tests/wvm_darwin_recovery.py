#!/usr/bin/env python3
"""Native failure-injection gate. Requires signed real W Darwin executables."""
import argparse
import fcntl
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import tempfile
import time


def rpc(path, method, params=None):
    body = json.dumps({"jsonrpc": "2.0", "id": 77, "method": method,
                       "params": params or {}}, separators=(",", ":")).encode()
    with socket.socket(socket.AF_UNIX) as channel:
        channel.settimeout(5)
        channel.connect(str(path))
        channel.sendall(f"Content-Length: {len(body)}\r\n\r\n".encode() + body)
        response = bytearray()
        while b"\r\n\r\n" not in response:
            part = channel.recv(4096)
            assert part, "closed before response header"
            response += part
            assert len(response) < 16384, "unbounded response header"
        header, response = bytes(response).split(b"\r\n\r\n", 1)
        assert header.startswith(b"Content-Length: ")
        size = int(header[16:])
        assert 0 < size <= 16384, size
        while len(response) < size:
            part = channel.recv(size - len(response))
            assert part, "truncated response"
            response += part
        result = json.loads(response)
        assert result["id"] == 77 and result["jsonrpc"] == "2.0"
        return result["result"]


def processes():
    rows = subprocess.check_output(["ps", "-axo", "pid=,ppid=,stat=,command="], text=True)
    result = {}
    for row in rows.splitlines():
        fields = row.strip().split(None, 3)
        if len(fields) == 4:
            result[int(fields[0])] = (int(fields[1]), fields[2], fields[3])
    return result


def children(parent):
    return {pid for pid, (ppid, _, _) in processes().items() if ppid == parent}


def wait_until(predicate, description, timeout=5):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        result = predicate()
        if result:
            return result
        time.sleep(0.02)
    raise AssertionError(f"timed out: {description}")


class Harness:
    def __init__(self, args, directory, name, inherited=()):
        self.path = directory / f"{name}.sock"
        self.guest = str(args.guest)
        self.log = open(directory / f"{name}.log", "wb")
        self.process = subprocess.Popen([str(args.daemon), "serve", "--socket", str(self.path),
                                         "--worker", str(args.worker), "--max-active", "1",
                                         "--max-pending", "2", "--memory-mb", "2048"],
                                        stdin=subprocess.DEVNULL, stdout=self.log, stderr=self.log, pass_fds=inherited)
        def started():
            assert self.process.poll() is None, "daemon startup failed"
            return self.path.exists()
        wait_until(started, "daemon socket")
        self.template = rpc(self.path, "template_create", {"backend": "cell", "image": self.guest})["template"]
        self.workers = set()

    def spawn(self):
        result = rpc(self.path, "vm_spawn", {"backend": "cell", "template": self.template,
                                             "lease_ms": 60000})
        assert "session" in result, result
        session = result["session"]
        self.state(session, "ready")
        running = children(self.process.pid)
        assert len(running) == 1, running
        self.workers.update(running)
        return session, running.pop()

    def state(self, session, target):
        def check():
            status = rpc(self.path, "vm_status", {"session": session})
            assert "error" not in status, status
            return status if status["state"] == target else None
        return wait_until(check, f"session {session} {target}")

    def execute(self, session, mode="hello", timeout=1000):
        result = rpc(self.path, "vm_exec", {"session": session, "argv": ["cell", mode],
                                            "timeout_ms": timeout})
        assert "command" in result, result

    def hello(self, session):
        self.execute(session)
        self.state(session, "ready")
        result = rpc(self.path, "vm_result", {"session": session})
        assert result["status"] == 7, result
        assert bytes.fromhex(result["stdout_hex"]) == b"hello from an ARM64 cell\n", result

    def close(self):
        if self.process.poll() is None:
            try:
                rpc(self.path, "stop")
                self.process.wait(timeout=5)
            except (OSError, AssertionError, subprocess.TimeoutExpired):
                self.process.kill()
                self.process.wait(timeout=5)
        for pid in self.workers:
            if pid in processes():
                try:
                    os.kill(pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
        self.log.close()


def malformed_channels(harness):
    samples = [b"Content-Length: 999999999999999999999999\r\n\r\n",
               b"Content-Length: -1\r\n\r\n", b"X" * 128,
               b"Content-Length: 2\r\n\r\n{]",
               b'Content-Length: 8\r\n\r\n"\\u0000"']
    for data in samples:
        with socket.socket(socket.AF_UNIX) as channel:
            channel.settimeout(2)
            channel.connect(str(harness.path))
            channel.sendall(data)
            assert channel.recv(64) == b"", ("malformed channel not closed", data)
        assert rpc(harness.path, "stats")["active"] == 0
    # A partial client disconnect cannot poison the next accepted connection.
    with socket.socket(socket.AF_UNIX) as channel:
        channel.connect(str(harness.path))
        channel.sendall(b"Content-Length: 8192\r\n\r\n{")
    assert rpc(harness.path, "stats")["active"] == 0
    print("PASS bounded malformed/truncated channel recovery", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--worker", type=Path, required=True)
    parser.add_argument("--daemon", type=Path, required=True)
    parser.add_argument("--guest", type=Path, required=True)
    parser.add_argument("--compiler", type=Path)
    args = parser.parse_args()
    for name in ("worker", "daemon", "guest"):
        setattr(args, name, getattr(args, name).resolve(strict=True))
    with tempfile.TemporaryDirectory(prefix="wvm-recovery-", dir="/tmp") as temporary:
        directory = Path(temporary)
        fifo = directory / "image.fifo"
        os.mkfifo(fifo)
        result = subprocess.run([str(args.worker), "run", str(fifo)], stdin=subprocess.DEVNULL,
                                capture_output=True, timeout=2)
        assert result.returncode == 125 and b"regular file" in result.stderr, result
        # Fill a pipe and leave its reader idle. Even diagnostic output after
        # an error must respect a deadline rather than hanging in write_all.
        read_end, write_end = os.pipe()
        try:
            os.set_blocking(write_end, False)
            while True:
                try:
                    os.write(write_end, b"x" * 4096)
                except BlockingIOError:
                    break
            os.set_blocking(write_end, True)
            failed = subprocess.run([str(args.worker), "run", str(fifo)], stdin=subprocess.DEVNULL,
                                    stdout=subprocess.DEVNULL, stderr=write_end, timeout=2)
            assert failed.returncode == 125, failed.returncode
        finally:
            os.close(read_end)
            os.close(write_end)
        print("PASS full stderr cannot block CLI diagnostics", flush=True)
        compiler = args.compiler or args.worker.parent / "wv4_darwin"
        compiler = compiler.resolve(strict=True)
        source = directory / "source.w"
        source.write_text('import lib.lib\nint main():\n\tprintln(c"isolated source output")\n\treturn 9\n')
        sentinel = directory / "source-output-sentinel"
        sentinel.write_bytes(b"must remain untouched")
        def predict_old_output():
            os.symlink(sentinel, Path("bin") / f"wvm-darwin-source-{os.getpid()}")
        source_process = subprocess.Popen([str(args.worker), "run", str(source)],
                                          stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                          stderr=subprocess.PIPE, preexec_fn=predict_old_output,
                                          env={**os.environ, "W_DARWIN_COMPILER": str(compiler)})
        old_output = Path("bin") / f"wvm-darwin-source-{source_process.pid}"
        try:
            stdout, stderr = source_process.communicate(timeout=10)
            assert source_process.returncode == 9, (source_process.returncode, stdout, stderr)
            assert stdout == b"isolated source output\n", stdout
            assert sentinel.read_bytes() == b"must remain untouched", "source compile followed predictable symlink"
        finally:
            if source_process.poll() is None:
                source_process.kill()
                source_process.wait(timeout=5)
            old_output.unlink(missing_ok=True)
        print("PASS source compilation isolates output from predictable-path symlinks", flush=True)
        marker = directory / "must-not-reach-worker"
        marker.write_text("host-secret-descriptor")
        with marker.open("rb") as retained:
            inherited = fcntl.fcntl(retained.fileno(), fcntl.F_DUPFD, 200)
        harness = Harness(args, directory, "recovery", (inherited,))
        os.close(inherited)
        inherited_listing = subprocess.run(["/usr/sbin/lsof", "-a", "-p", str(harness.process.pid),
                                            "-d", str(inherited), "-Fn"],
                                           capture_output=True, text=True, timeout=5)
        assert str(marker) in inherited_listing.stdout, "FD fixture not inherited by daemon"
        try:
            rejected = rpc(harness.path, "vm_spawn", {"backend": "cell", "image": str(fifo)})
            assert "error" in rejected, rejected
            assert rpc(harness.path, "stats")["sessions"] == 0
            print("PASS FIFO image rejected without blocking CLI/daemon", flush=True)
            malformed_channels(harness)
            # A stopped worker cannot defeat cancellation/reaping.
            session, worker = harness.spawn()
            listing = subprocess.run(["/usr/sbin/lsof", "-a", "-p", str(worker), "-Fn"],
                                     capture_output=True, text=True, timeout=5)
            assert listing.returncode == 0, listing.stderr
            assert str(marker) not in listing.stdout, "inherited host descriptor leaked to worker"
            print("PASS high-number host FD excluded by worker allowlist", flush=True)
            harness.execute(session, "spin", 600000)
            os.kill(worker, signal.SIGSTOP)
            assert "error" not in rpc(harness.path, "vm_cancel", {"session": session})
            wait_until(lambda: worker not in processes(), "stopped worker canceled/reaped")
            assert rpc(harness.path, "stats")["active"] == 0
            session, _ = harness.spawn()
            harness.hello(session)
            rpc(harness.path, "vm_destroy", {"session": session})
            print("PASS SIGSTOP worker cancellation and admission recovery", flush=True)
            # Stop the daemon before it can drain a 2MiB hex result. The
            # worker's bounded send must finish even while its parent lives.
            session, worker = harness.spawn()
            result = rpc(harness.path, "vm_exec", {"session": session, "argv": ["cell", "burst"],
                                                   "timeout_ms": 1000, "output_limit": 1048576})
            assert "command" in result, result
            os.kill(harness.process.pid, signal.SIGSTOP)
            try:
                def worker_exited():
                    row = processes().get(worker)
                    return row is None or row[1].startswith("Z")
                wait_until(worker_exited, "bounded result send to stopped daemon", timeout=7)
            finally:
                os.kill(harness.process.pid, signal.SIGCONT)
            harness.state(session, "failed")
            wait_until(lambda: worker not in processes(), "blocked-output worker reaped")
            rpc(harness.path, "vm_destroy", {"session": session})
            session, _ = harness.spawn()
            harness.hello(session)
            rpc(harness.path, "vm_destroy", {"session": session})
            print("PASS stopped daemon cannot block worker result indefinitely; replacement succeeds", flush=True)
        finally:
            harness.close()
        # Reopening the service after injected failures must execute real cells.
        harness = Harness(args, directory, "replacement-daemon")
        try:
            session, _ = harness.spawn()
            harness.hello(session)
        finally:
            harness.close()
        print("PASS fresh daemon after injected failures; no retained worker processes", flush=True)


if __name__ == "__main__":
    main()
