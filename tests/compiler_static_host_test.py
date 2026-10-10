"""A static compiler needs neither its archive nor a dynamic loader at runtime."""
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tempfile

source = Path(sys.argv[1])
image = source.read_bytes()
phoff = struct.unpack_from("<Q", image, 32)[0]
phsize, phcount = struct.unpack_from("<HH", image, 54)
for index in range(phcount):
    kind = struct.unpack_from("<I", image, phoff + phsize * index)[0]
    assert kind not in (2, 3), "static compiler carries a dynamic table/interpreter"
with tempfile.TemporaryDirectory(prefix="w-static-compiler-") as directory:
    executable = Path(directory) / "compiler"
    shutil.copy2(source, executable)
    result = subprocess.run(
        [str(executable), "--version"], cwd=directory,
        check=True, capture_output=True, text=True,
    )
    assert result.stdout == "w 0.3.0\n", result.stdout
print("static compiler standalone OK")
