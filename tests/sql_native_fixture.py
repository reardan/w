"""Exercise the native ABI without proprietary clients or external servers."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

cc = shutil.which("cc")
if not cc:
    print("sql native ABI fixtures: SKIP (cc unavailable)")
    sys.exit(0)
with tempfile.TemporaryDirectory(prefix="w-sql-native-") as tmp:
    library = Path(tmp) / "fixture.so"
    subprocess.run([cc, "-std=c99", "-Wall", "-Wextra", "-Werror",
                    "-Wno-unused-parameter", "-shared", "-fPIC",
                    "tests/sql_native_fixture.c", "-o", str(library)], check=True)
    for name in ["libmysqlclient.so.21", "libsybdb.so.5", "libclntsh.so"]:
        (Path(tmp) / name).symlink_to(library)
    env = dict(os.environ, LD_LIBRARY_PATH=tmp)
    subprocess.run([sys.argv[1], "fixture"], env=env, check=True, timeout=30)

with tempfile.TemporaryDirectory(prefix="w-sql-missing-") as tmp:
    library = Path(tmp) / "missing.so"
    subprocess.run([cc, "-shared", "-fPIC", "-x", "c", "-", "-o", str(library)],
                   input="int unrelated_symbol;\n", text=True, check=True)
    for name in ["libsqlite3.so.0", "libpq.so.5", "libmysqlclient.so.21", "libsybdb.so.5", "libclntsh.so"]:
        (Path(tmp) / name).symlink_to(library)
    subprocess.run([sys.argv[1], "fixture", "missing"],
                   env=dict(os.environ, LD_LIBRARY_PATH=tmp), check=True, timeout=30)
