"""Exercise the public executable, file preservation and SVG output."""
from pathlib import Path
import subprocess
import tempfile
import xml.etree.ElementTree as ET


def run(*args, ok=True):
    result = subprocess.run(
        ["bin/wmermaid", *map(str, args)], capture_output=True, timeout=20
    )
    assert (result.returncode == 0) == ok, (args, result.stderr.decode())
    return result


with tempfile.TemporaryDirectory(prefix="mermaid-", dir="bin") as temp:
    root = Path(temp)
    source = root / "source.mmd"
    copy = root / "copy.mmd"
    svg = root / "diagram.svg"
    replacement = root / "replacement.txt"
    original = b'%% retained\r\nerDiagram\r\nA ||--o{ B : owns\r\n'
    source.write_bytes(original)
    run("check", source)
    assert run("read", source).stdout == original
    run("write", source, copy)
    assert copy.read_bytes() == original
    run("svg", source, svg)
    tree = ET.parse(svg)
    assert tree.getroot().tag == "{http://www.w3.org/2000/svg}svg"
    assert "owns" in "".join(tree.getroot().itertext())
    at = original.index(b"owns")
    replacement.write_text("contains")
    run("edit", source, at, at + 4, replacement, copy)
    assert copy.read_bytes() == original.replace(b"owns", b"contains")
    assert source.read_bytes() == original
    run("edit", source, "1oops", at, replacement, copy, ok=False)
    run("edit", source, 999999, 999999, replacement, copy, ok=False)
    run("write", source, root / "missing" / "output.mmd", ok=False)
    assert source.read_bytes() == original
    run("write", source, source)
    assert source.read_bytes() == original
    invalid = b"sequenceDiagram\nA->>B: hello\n"
    source.write_bytes(invalid)
    assert b"unsupported diagram type" in run("check", source, ok=False).stderr
    run("write", source, copy)
    assert copy.read_bytes() == invalid
    before = svg.read_bytes()
    run("svg", source, svg, ok=False)
    assert svg.read_bytes() == before
    source.write_bytes(b"erDiagram\nA\x00B")
    run("check", source, ok=False)
    assert run("read", source).stdout == source.read_bytes()
    run("check", root / "missing.mmd", ok=False)
    run("nonsense", source, ok=False)
    for example in Path("examples/mermaid").glob("*.mmd"):
        run("check", example)
        run("svg", example, svg)
        ET.parse(svg)

print("Mermaid CLI integration passed")
