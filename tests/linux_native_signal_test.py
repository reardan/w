#!/usr/bin/env python3
"""Native executor signal ABI and process-group cleanup regression."""
import json
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time


def child_gone(stat):
    """The child is reaped (no /proc entry) or a zombie. The entry can
    vanish between an exists() check and the read, so read once."""
    try:
        return stat.read_text().split()[2] == 'Z'
    except FileNotFoundError:
        return True


root = Path.cwd()
for signum in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM):
    with tempfile.TemporaryDirectory(prefix='native-signal-', dir=root / 'bin') as tmp:
        fixture = Path(tmp)
        manifest, pidfile, lock = (fixture / name for name in ('manifest.json', 'pid', 'lock'))
        manifest.write_text(json.dumps({'targets': [{'name': 'hang', 'steps': [
            {'cmd': ['sh', '-c', f'echo $$ > {pidfile}; sleep 60']}]}]}))
        env = dict(os.environ, WBUILD_HOST='linux-x64', WEXEC_LOCK_FILE=str(lock))
        env.pop('WEXEC_LOCK_HELD', None)
        process = subprocess.Popen([str(root / 'bin/wexec_native'), '-f', str(manifest), 'hang'],
                                   env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            deadline = time.monotonic() + 5
            while not pidfile.exists() and time.monotonic() < deadline:
                time.sleep(.01)
            assert pidfile.exists(), 'executor did not start its child'
            process.send_signal(signum)
            stdout, stderr = process.communicate(timeout=5)
            assert process.returncode == 128 + signum, (process.returncode, stdout, stderr)
            assert not lock.exists(), 'termination left its lock behind'
            stat = Path('/proc') / pidfile.read_text().strip() / 'stat'
            deadline = time.monotonic() + 5
            while not child_gone(stat) and time.monotonic() < deadline:
                time.sleep(.01)
            assert child_gone(stat), 'child survived termination'
        finally:
            if process.poll() is None:
                process.kill()
                process.wait(timeout=5)
print('native signal ABI and process group cleanup OK')
