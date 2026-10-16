"""Real native execution of standalone ELF and separately compiled C code."""
import json
from pathlib import Path
import subprocess
import struct
import tempfile

ROOT = Path(__file__).resolve().parents[1]
RUNNER = ROOT / "bin/wgrind_native"


def run(*args, **kwargs):
    return subprocess.run(args, cwd=ROOT, capture_output=True, text=True,
                          timeout=45, **kwargs)


with tempfile.TemporaryDirectory(prefix="wgrind-native-", dir=ROOT / "bin") as tmp:
    folder = Path(tmp)
    library = folder / "library.o"
    result = run("cc", "-c", "-O0", "-fno-stack-protector", "-fno-pie",
                 "tests/wgrind_native/library.c", "-o", str(library))
    assert result.returncode == 0, result.stderr
    cases = {
        "clean": (["CLEAN"], 0, None),
        "undefined": ([], 99, "undefined-value"),
        "masked": (["MASKED"], 0, None),
        "invalid": (["INVALID"], 99, "invalid-read"),
        "unsupported": (["CLEAN", "UNSUPPORTED"], 100, "incomplete"),
    }
    for name, (defines, status, kind) in cases.items():
        executable = folder / name
        result = run("cc", "-nostdlib", "-static", "-no-pie",
                     *("-D" + define for define in defines),
                     "tests/wgrind_native/entry.S", str(library),
                     "-o", str(executable))
        assert result.returncode == 0, result.stderr
        result = run(str(RUNNER), str(executable))
        assert result.returncode == status, (name, result.returncode, result.stderr)
        launcher = run(str(ROOT / "bin/wgrind"), "--native-exec", str(executable))
        assert launcher.returncode == status, (name, launcher.returncode, launcher.stderr)
        diagnostics = [json.loads(line) for line in result.stderr.splitlines()]
        if kind:
            assert diagnostics[0]["kind"] == kind, (name, diagnostics)
            assert int(diagnostics[0]["site"], 16) != 0, diagnostics
            if kind == "undefined-value":
                assert int(diagnostics[0]["origin"], 16) != 0, diagnostics
        else:
            assert not diagnostics, (name, diagnostics)
    allocator = folder / "allocator.o"
    result = run("cc", "-c", "tests/wgrind_native/allocator.S", "-o", str(allocator))
    assert result.returncode == 0, result.stderr
    for name, kind in (("HEAP_CLEAN", None), ("HEAP_UNDEFINED", "undefined-value"),
                       ("HEAP_OVERFLOW", "invalid-write"), ("HEAP_UAF", "invalid-write"),
                       ("HEAP_DOUBLE", "double-free")):
        executable = folder / name
        result = run("cc", "-nostdlib", "-static", "-no-pie", "-D" + name,
                     "tests/wgrind_native/heap_entry.S", str(allocator), "-o", str(executable))
        assert result.returncode == 0, result.stderr
        result = run(str(RUNNER), str(executable))
        assert result.returncode == (99 if kind else 0), (name, result.returncode, result.stderr)
        diagnostics = [json.loads(line) for line in result.stderr.splitlines()]
        if kind:
            assert diagnostics[0]["kind"] == kind, (name, diagnostics)
            if name == "HEAP_OVERFLOW":
                assert diagnostics[0]["offset"] == 8, diagnostics
        else:
            assert not diagnostics, diagnostics
    for name, kind, status in (("LEAK_DIRECT", "definitely-lost", 99),
                               ("LEAK_REACHABLE", "still-reachable", 0),
                               ("LEAK_POSSIBLE", "possibly-lost", 99)):
        executable = folder / name
        result = run("cc", "-nostdlib", "-static", "-no-pie", "-D" + name,
                     "tests/wgrind_native/leak_entry.S", str(allocator), "-o", str(executable))
        assert result.returncode == 0, result.stderr
        result = run(str(RUNNER), str(executable))
        assert result.returncode == status, (name, result.returncode, result.stderr)
        diagnostics = [json.loads(line) for line in result.stderr.splitlines()]
        assert diagnostics[0][kind] == {"blocks": 1, "bytes": 8}, diagnostics
    shared = folder / "library.so"
    result = run("cc", "-shared", "-nostdlib", "-fPIC", "-O0", "-fno-stack-protector",
                 "tests/wgrind_native/library.c", "-o", str(shared))
    assert result.returncode == 0, result.stderr
    result = run("nm", "-D", str(shared))
    assert result.returncode == 0, result.stderr
    symbol = next(line.split()[0] for line in result.stdout.splitlines()
                  if line.endswith(" wgrind_precompiled_load"))
    for clean in (True, False):
        executable = folder / ("shared_clean" if clean else "shared_undefined")
        result = run("cc", "-nostdlib", "-static", "-no-pie", "-DSYMBOL=0x" + symbol,
                     *( ["-DCLEAN"] if clean else []),
                     "tests/wgrind_native/shared_entry.S", "-o", str(executable))
        assert result.returncode == 0, result.stderr
        result = run(str(RUNNER), str(executable), str(shared))
        assert result.returncode == (0 if clean else 99), (clean, result.returncode, result.stderr)
        if not clean:
            assert json.loads(result.stderr.splitlines()[0])["kind"] == "undefined-value", result.stderr
    edge = folder / "page_edge"
    result = run("cc", "-nostdlib", "-static", "-no-pie",
                 "tests/wgrind_native/page_edge.S", "-o", str(edge))
    assert result.returncode == 0, result.stderr
    result = run(str(RUNNER), str(edge))
    assert result.returncode == 0, result.stderr
    truncated = folder / "page_truncated"
    result = run("cc", "-nostdlib", "-static", "-no-pie", "-DTRUNCATED",
                 "tests/wgrind_native/page_edge.S", "-o", str(truncated))
    assert result.returncode == 0, result.stderr
    result = run(str(RUNNER), str(truncated))
    assert result.returncode == 100, result.stderr
    assert json.loads(result.stderr.splitlines()[0])["kind"] == "incomplete", result.stderr
    # A standard allocator symbol permits modeling only its own body;
    # invoking arbitrary user callbacks must fail before the call runs.
    callback = folder / "callback"
    result = run("cc", "-nostdlib", "-static", "-no-pie", "-DCALLBACK", "-DHEAP_CLEAN",
                 "tests/wgrind_native/heap_entry.S", "tests/wgrind_native/allocator.S",
                 "-o", str(callback))
    assert result.returncode == 0, result.stderr
    result = run(str(RUNNER), str(callback))
    assert result.returncode == 100, result.stderr
    assert json.loads(result.stderr.splitlines()[0])["kind"] == "incomplete", result.stderr
    for clean in (True, False):
        executable = folder / ("flags_clean" if clean else "flags_undefined")
        result = run("cc", "-nostdlib", "-static", "-no-pie",
                     *( ["-DCLEAN"] if clean else []),
                     "tests/wgrind_native/syscall_flags.S", "-o", str(executable))
        assert result.returncode == 0, result.stderr
        result = run(str(RUNNER), str(executable))
        assert result.returncode == (0 if clean else 99), (clean, result.returncode, result.stderr)
        if not clean:
            assert json.loads(result.stderr.splitlines()[0])["kind"] == "undefined-value", result.stderr
    for name in ("thread_clean", "thread_undefined", "thread_clear_tid", "thread_leader_exit",
                 "thread_clone3", "thread_tls"):
        executable = folder / name
        result = run("cc", "-nostdlib", "-static", "-no-pie",
                     "tests/wgrind_native/" + name + ".S", "-o", str(executable))
        assert result.returncode == 0, result.stderr
        result = run(str(RUNNER), str(executable))
        assert result.returncode == (99 if name == "thread_undefined" else 0), (name, result.returncode, result.stderr)
        if name == "thread_undefined":
            assert json.loads(result.stderr.splitlines()[0])["kind"] == "undefined-value", result.stderr
    for define, kind in (("UNDEFINED", "undefined-value"), ("INVALID", "invalid-read")):
        tls_bad = folder / ("tls_" + define)
        result = run("cc", "-nostdlib", "-static", "-no-pie", "-D" + define,
                     "tests/wgrind_native/thread_tls.S", "-o", str(tls_bad))
        assert result.returncode == 0, result.stderr
        result = run(str(RUNNER), str(tls_bad))
        assert result.returncode == 99, result.stderr
        assert json.loads(result.stderr.splitlines()[0])["kind"] == kind, result.stderr
    for fixture, cases in (("readv_entry", ((None, 0, None), ("TAIL", 99, "undefined-value"), ("FAILED", 99, "undefined-value"))),
                           ("protect_entry", (("CLEAN", 0, None), (None, 99, "undefined-value"), ("NOACCESS", 99, "invalid-read")))):
        for define, expected, kind in cases:
            executable = folder / (fixture + (define or "default"))
            result = run("cc", "-nostdlib", "-static", "-no-pie",
                         *( ["-D" + define] if define else []),
                         "tests/wgrind_native/" + fixture + ".S", "-o", str(executable))
            assert result.returncode == 0, result.stderr
            result = run(str(RUNNER), str(executable), input="abc")
            assert result.returncode == expected, (fixture, define, result.returncode, result.stderr)
            if kind:
                assert json.loads(result.stderr.splitlines()[0])["kind"] == kind, result.stderr
    stripped = folder / "stripped"
    result = run("strip", "--strip-all", "-o", str(stripped), str(folder / "clean"))
    assert result.returncode == 0, result.stderr
    result = run(str(RUNNER), str(stripped))
    assert result.returncode == 100, result.stderr
    ignored = folder / "syscall_ignored"
    result = run("cc", "-nostdlib", "-static", "-no-pie",
                 "tests/wgrind_native/syscall_ignored.S", "-o", str(ignored))
    assert result.returncode == 0, result.stderr
    result = run(str(RUNNER), str(ignored), str(ignored))
    assert result.returncode == 0, result.stderr
    # Both objects are reachable through a register/stack in another TID,
    # even when its mmap stack VMA merges with a preceding heap mapping.
    for define in (None, "LOST", "REDZONE"):
        lost = define == "LOST"
        thread_leaks = folder / ("thread_" + (define or "reachable"))
        result = run("cc", "-nostdlib", "-static", "-no-pie",
                     *(["-D" + define] if define else []),
                     "tests/wgrind_native/thread_leaks.S", str(allocator), "-o", str(thread_leaks))
        assert result.returncode == 0, result.stderr
        result = run(str(RUNNER), str(thread_leaks))
        assert result.returncode == (99 if lost else 0), result.stderr
        summary = json.loads(result.stderr.splitlines()[0])
        category = "definitely-lost" if lost else "still-reachable"
        assert summary[category] == {"blocks": 1, "bytes": 8}, summary
    heap_stack = folder / "heap_stack"
    result = run("cc", "-nostdlib", "-static", "-no-pie",
                 "tests/wgrind_native/heap_stack.S", "-o", str(heap_stack))
    assert result.returncode == 0, result.stderr
    result = run(str(RUNNER), str(heap_stack))
    assert result.returncode == 0, result.stderr
    summary = json.loads(result.stderr.splitlines()[0])
    assert summary["still-reachable"] == {"blocks": 2, "bytes": 4104}, summary
    assert summary["possibly-lost"]["blocks"] == 0, summary
    for defines in ([], ["GS"], ["CWD"], ["GS", "CWD"]):
        executable = folder / ("prefix_convert_" + "_".join(defines))
        result = run("cc", "-nostdlib", "-static", "-no-pie",
                     *("-D" + define for define in defines),
                     "tests/wgrind_native/prefix_convert.S", "-o", str(executable))
        assert result.returncode == 0, result.stderr
        result = run(str(RUNNER), str(executable))
        assert result.returncode == 100, (defines, result.returncode, result.stderr)
        assert json.loads(result.stderr.splitlines()[0])["kind"] == "incomplete", result.stderr
    for protect in (False, True):
        executable = folder / ("execute_only_protect" if protect else "execute_only_map")
        result = run("cc", "-nostdlib", "-static", "-no-pie",
                     *(["-DPROTECT"] if protect else []),
                     "tests/wgrind_native/execute_only.S", "-o", str(executable))
        assert result.returncode == 0, result.stderr
        # Prove the operation is valid on the actual CPU before checking
        # that our narrower permission model reports its limitation.
        result = run(str(executable))
        assert result.returncode == 0, result.stderr
        result = run(str(RUNNER), str(executable))
        assert result.returncode == 100, result.stderr
        assert json.loads(result.stderr.splitlines()[0])["kind"] == "incomplete", result.stderr
    initial_execute_only = folder / "initial_execute_only"
    contents = bytearray((folder / "clean").read_bytes())
    phoff = struct.unpack_from("<Q", contents, 32)[0]
    phentsize, phnum = struct.unpack_from("<HH", contents, 54)
    for index in range(phnum):
        at = phoff + index * phentsize
        kind, flags = struct.unpack_from("<II", contents, at)
        if kind == 1 and flags & 1:
            struct.pack_into("<I", contents, at + 4, 1)
    initial_execute_only.write_bytes(contents)
    initial_execute_only.chmod(0o755)
    result = run(str(initial_execute_only))
    assert result.returncode == 0, result.stderr
    result = run(str(RUNNER), str(initial_execute_only))
    assert result.returncode == 100, result.stderr
    assert json.loads(result.stderr.splitlines()[0])["kind"] == "incomplete", result.stderr
    # Incompatible and truncated files must be rejected before any process
    # executes; especially avoid unchecked reads of an ELF header's fields.
    for content in (b"", b"\x7fELF", b"#!/bin/sh\nexit 0\n"):
        bad = folder / "bad"
        bad.write_bytes(content)
        bad.chmod(0o755)
        result = run(str(RUNNER), str(bad))
        assert result.returncode == 100, (content, result.returncode, result.stderr)
print("wgrind native executable checks OK")
