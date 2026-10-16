"""Optional Memcheck oracle lane; Valgrind is never used by the native checker.

Run after ./wbuild wgrind_native: python3 tests/wgrind_differential.py
The normal suite does not require Valgrind. These fixtures compare executed
precompiled-C accesses and consequential undefined uses, not diagnostic wording.
"""
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]


def run(*args):
    return subprocess.run(args, cwd=ROOT, capture_output=True, text=True, timeout=45)


def main():
    if shutil.which("valgrind") is None:
        raise SystemExit("Valgrind is required for the optional differential lane")
    with tempfile.TemporaryDirectory(prefix="wgrind-oracle-", dir=ROOT / "bin") as tmp:
        folder = Path(tmp)
        library = folder / "library.o"
        result = run("cc", "-c", "-O0", "-fno-stack-protector", "-fno-pie",
                     "tests/wgrind_native/library.c", "-o", str(library))
        assert result.returncode == 0, result.stderr
        # Cross the initial ABI red zone. Memcheck treats the kernel-provided
        # initial stack neighborhood as defined; the native checker starts its
        # red zone undefined. A newly extended frame is comparable in both.
        entry = folder / "entry.S"
        entry.write_text((ROOT / "tests/wgrind_native/entry.S").read_text()
                         .replace("$32, %rsp", "$512, %rsp"))
        cases = (
            ("clean", ["CLEAN"], None, None),
            ("undefined", [], "undefined-value", "UninitCondition"),
            ("masked", ["MASKED"], None, None),
            ("invalid", ["INVALID"], "invalid-read", "InvalidRead"),
        )
        for name, defines, native_kind, oracle_kind in cases:
            binary = folder / name
            result = run("cc", "-nostdlib", "-static", "-no-pie",
                         *("-D" + define for define in defines),
                         str(entry), str(library), "-o", str(binary))
            assert result.returncode == 0, result.stderr
            native = run(str(ROOT / "bin/wgrind_native"), str(binary))
            diagnostics = [json.loads(line) for line in native.stderr.splitlines()]
            assert native.returncode == (99 if native_kind else 0), (name, native)
            assert [d["kind"] for d in diagnostics] == ([native_kind] if native_kind else []), diagnostics
            report = folder / (name + ".xml")
            oracle = run("valgrind", "--tool=memcheck", "--track-origins=yes",
                         "--xml=yes", "--xml-file=" + str(report), str(binary))
            errors = ET.parse(report).getroot().findall("error")
            kinds = [error.findtext("kind") for error in errors]
            if oracle_kind:
                assert oracle_kind in kinds, (name, kinds, oracle.stderr)
                native_site = int(diagnostics[0]["site"], 16)
                frames = [error.find("stack/frame") for error in errors
                          if error.findtext("kind") == oracle_kind]
                assert any(int(frame.findtext("ip"), 16) == native_site for frame in frames), (name, diagnostics, ET.tostring(errors[0]))
            else:
                assert oracle.returncode == 0 and not errors, (name, kinds, oracle.stderr)
    print("wgrind differential checks OK (4 native/Memcheck pairs)")


if __name__ == "__main__":
    main()
