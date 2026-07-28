#!/usr/bin/env python3
"""Drive a command under a real pty from a small expect/send script.

Usage:
  python3 tools/pty_test.py [--timeout SECONDS] SCRIPT [--] CMD [ARG...]

Script format (one directive per line; blank lines and lines whose first
column is '#' are ignored):

  expect TEXT   wait until TEXT appears in the command's pty output,
                consuming through it; fails after the timeout
  send TEXT     write TEXT to the command's pty input

TEXT is everything after the first space (trailing spaces are kept, so
"expect w> " waits for the prompt's trailing space too) and decodes the
escapes \\n \\r \\t \\e \\0 \\\\ and \\xHH, so control bytes -- e.g. \\x12
for Ctrl-R, \\r for a raw-mode Enter -- can be scripted.

Why this exists (docs/projects/ai_tooling_next_steps.md, "script -qc
cannot script a canonical-mode keystroke"): script(1) delivers piped
stdin to the pty in one burst while the slave is still in its default
canonical mode, whose line discipline consumes special characters like
Ctrl-R (VREPRINT) on the spot -- the program never sees the byte, and no
later switch to raw mode un-consumes it. Here every send happens only
after an expected marker has appeared -- e.g. a prompt that is rendered
only after term_raw_mode() has already run -- so keystrokes arrive when
the program is actually in the mode the script assumes.

After the last directive the harness drains output to EOF and waits for
the child, which must exit 0. On success it prints "pty script OK" and
exits 0; on any failure it prints a diagnostic (script line, marker and
the unconsumed output tail) to stderr, kills the child and exits 1.
"""

import os
import pty
import select
import signal
import sys
import time


def decode(text):
    """Decode the script's escape syntax into bytes."""
    out = bytearray()
    i = 0
    while i < len(text):
        ch = text[i]
        if ch == "\\" and i + 1 < len(text):
            nxt = text[i + 1]
            simple = {"n": 10, "r": 13, "t": 9, "e": 27, "0": 0, "\\": 92}
            if nxt in simple:
                out.append(simple[nxt])
                i += 2
                continue
            if nxt == "x" and i + 3 < len(text):
                try:
                    out.append(int(text[i + 2 : i + 4], 16))
                    i += 4
                    continue
                except ValueError:
                    pass
        out.extend(ch.encode("utf-8"))
        i += 1
    return bytes(out)


def parse_script(path):
    steps = []
    with open(path, "r") as f:
        for lineno, raw in enumerate(f, 1):
            line = raw.rstrip("\n")
            if line == "" or line.startswith("#"):
                continue
            if line.startswith("expect "):
                steps.append(("expect", decode(line[len("expect ") :]), lineno))
            elif line.startswith("send "):
                steps.append(("send", decode(line[len("send ") :]), lineno))
            else:
                raise SystemExit("%s:%d: unknown directive: %r" % (path, lineno, line))
    return steps


class PtyChild:
    def __init__(self, argv):
        pid, fd = pty.fork()
        if pid == 0:  # child: exec on the slave side of the pty
            try:
                os.execvp(argv[0], argv)
            except OSError as e:
                os.write(2, ("exec %s failed: %s\n" % (argv[0], e)).encode())
            os._exit(127)
        self.pid = pid
        self.fd = fd
        self.received = b""  # everything read from the master so far
        self.consumed = 0  # expects match only past this offset
        self.eof = False

    def pump(self, seconds):
        """Read whatever arrives within `seconds`; sets self.eof at EOF."""
        if self.eof:
            return
        ready, _, _ = select.select([self.fd], [], [], max(seconds, 0))
        if self.fd not in ready:
            return
        try:
            chunk = os.read(self.fd, 65536)
        except OSError:  # EIO: the slave side closed
            chunk = b""
        if chunk == b"":
            self.eof = True
        else:
            self.received += chunk

    def tail(self):
        return repr(self.received[self.consumed :][-500:])

    def kill(self):
        try:
            os.kill(self.pid, signal.SIGKILL)
        except OSError:
            pass
        try:
            os.waitpid(self.pid, 0)
        except OSError:
            pass


def fail(child, message):
    sys.stderr.write("pty_test: %s\n" % message)
    sys.stderr.write("pty_test: unconsumed output tail: %s\n" % child.tail())
    child.kill()
    raise SystemExit(1)


def run(script_path, argv, timeout):
    steps = parse_script(script_path)
    child = PtyChild(argv)
    for kind, data, lineno in steps:
        deadline = time.monotonic() + timeout
        if kind == "send":
            try:
                os.write(child.fd, data)
            except OSError as e:
                fail(child, "%s:%d: send failed: %s" % (script_path, lineno, e))
            continue
        while child.received.find(data, child.consumed) < 0:
            remaining = deadline - time.monotonic()
            if child.eof:
                fail(child, "%s:%d: EOF before expected %r" % (script_path, lineno, data))
            if remaining <= 0:
                fail(child, "%s:%d: timeout (%gs) waiting for %r" % (script_path, lineno, timeout, data))
            child.pump(min(remaining, 0.25))
        child.consumed = child.received.find(data, child.consumed) + len(data)

    # Script done: drain to EOF, then the child must exit 0.
    deadline = time.monotonic() + timeout
    while not child.eof:
        if time.monotonic() >= deadline:
            fail(child, "timeout (%gs) waiting for the command to exit" % timeout)
        child.pump(0.25)
    while True:
        try:
            pid, status = os.waitpid(child.pid, os.WNOHANG)
        except OSError:
            pid, status = child.pid, 0
        if pid != 0:
            break
        if time.monotonic() >= deadline:
            fail(child, "timeout (%gs) waiting for the command to exit" % timeout)
        time.sleep(0.05)
    os.close(child.fd)
    if os.WIFEXITED(status) and os.WEXITSTATUS(status) == 0:
        print("pty script OK")
        return
    if os.WIFSIGNALED(status):
        sys.stderr.write("pty_test: command killed by signal %d\n" % os.WTERMSIG(status))
    else:
        sys.stderr.write("pty_test: command exited %d\n" % os.WEXITSTATUS(status))
    sys.stderr.write("pty_test: unconsumed output tail: %s\n" % child.tail())
    raise SystemExit(1)


def main():
    args = sys.argv[1:]
    timeout = 30.0
    if args and args[0] == "--timeout":
        if len(args) < 2:
            raise SystemExit("pty_test: --timeout needs a value")
        timeout = float(args[1])
        args = args[2:]
    if args and args[0] == "--":
        args = args[1:]
    if len(args) < 2:
        raise SystemExit(__doc__.strip().split("\n")[2].strip())
    script_path = args[0]
    argv = args[1:]
    if argv and argv[0] == "--":
        argv = argv[1:]
    if not argv:
        raise SystemExit("pty_test: no command given")
    run(script_path, argv, timeout)


if __name__ == "__main__":
    main()
