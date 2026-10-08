"""An optional isolated PostgreSQL cluster: never uses an existing database."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

candidates = sorted(Path("/usr/lib/postgresql").glob("*/bin/initdb"), reverse=True)
initdb = shutil.which("initdb") or (str(candidates[0]) if candidates else None)
if not initdb or os.geteuid() == 0:
    print("sql PostgreSQL local: SKIP (initdb unavailable or running as root)")
    sys.exit(0)
pg_ctl = str(Path(initdb).with_name("pg_ctl"))
with tempfile.TemporaryDirectory(prefix="w-sql-pg-") as tmp:
    data = str(Path(tmp) / "data")
    subprocess.run([initdb, "-D", data, "-A", "trust", "-U", "postgres",
                    "--no-locale", "--encoding=UTF8"], check=True,
                   stdout=subprocess.DEVNULL, timeout=30)
    started = False
    try:
        subprocess.run([pg_ctl, "-D", data, "-l", str(Path(tmp) / "server.log"),
                        "-o", f"-k {tmp} -h '' -p 5432", "-w", "-t", "15", "start"],
                       check=True, stdout=subprocess.DEVNULL, timeout=20)
        started = True
        env = dict(os.environ, W_SQL_POSTGRES=f"host={tmp} port=5432 user=postgres dbname=postgres connect_timeout=2")
        subprocess.run([sys.argv[1]], env=env, check=True, timeout=30)
    finally:
        if started or (Path(data) / "postmaster.pid").exists():
            subprocess.run([pg_ctl, "-D", data, "-m", "immediate", "-w", "stop"],
                           check=True, stdout=subprocess.DEVNULL, timeout=20)
