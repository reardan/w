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
    invalid = b"unknownDiagram\nA->>B: hello\n"
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
    # A selected Markdown diagram renders independently while round trips and
    # byte-range edits retain every other diagram and Markdown byte.
    markdown = (
        b"# Many diagrams\r\n```mermaid\r\nflowchart LR\r\nA[First]\r\n```\r\n"
        b"Between\n~~~mermaid\nflowchart TD\nB[Second]\n~~~\nAfter\n"
    )
    source.write_bytes(markdown)
    run("check", source)
    run("check", source, "--diagram", 1)
    run("svg", source, svg, "--diagram", 1)
    text = "".join(ET.parse(svg).getroot().itertext())
    assert "Second" in text and "First" not in text
    run("check", source, "--diagram", 2, ok=False)
    run("check", source, "--diagram", "-1", ok=False)
    run("check", source, "--diagram", "oops", ok=False)
    assert run("read", source, "--diagram", 1).stdout == markdown
    replacement.write_text("Edited")
    at = markdown.index(b"Second")
    run("edit", source, at, at + 6, replacement, copy, "--diagram", 1)
    assert copy.read_bytes() == markdown.replace(b"Second", b"Edited")
    run("canonical", copy, source, "--diagram", 1)
    assert b"Edited" in source.read_bytes() and b"First" not in source.read_bytes()
    run("check", source)
    run("canonical", source, copy)
    assert copy.read_bytes() == source.read_bytes()
    source.write_text('pie\n"A": 1\n')
    before = copy.read_bytes()
    run("canonical", source, copy, ok=False)
    assert copy.read_bytes() == before
    # Paths longer than the former native editor's 127-byte field limit.
    deep = root / ("long-directory-" + "x" * 100) / ("nested-" + "y" * 80)
    deep.mkdir(parents=True)
    long_source = deep / "diagram.mmd"
    long_source.write_bytes(markdown)
    run("check", long_source, "--diagram", 1)
    run("write", long_source, deep / "copy.mmd")
    assert (deep / "copy.mmd").read_bytes() == markdown
    for example in Path("examples/mermaid").iterdir():
        if example.suffix not in {".mmd", ".md"}:
            continue
        run("check", example)
        assert run("read", example).stdout == example.read_bytes()
        run("write", example, copy)
        assert copy.read_bytes() == example.read_bytes()
        run("svg", example, svg)
        ET.parse(svg)
        # The same document envelope/theme must survive every family dispatcher.
        raw = example.read_bytes()
        if example.suffix == ".mmd" and not raw.startswith(b"---"):
            title = b"All-family integration"
            source.write_bytes(
                b"---\ntitle: " + title + b"\nconfig:\n  theme: dark\n---\n" + raw
            )
            run("check", source)
            run("svg", source, svg)
            root_svg = ET.parse(svg).getroot()
            visible = root_svg.findall(".//{http://www.w3.org/2000/svg}text")
            assert sum(item.text == title.decode() for item in visible) == 1, example
            assert root_svg.find("{http://www.w3.org/2000/svg}rect").get("fill") == "#0f172a", example
            replacement.write_text("Edited family title")
            at = source.read_bytes().index(title)
            run("edit", source, at, at + len(title), replacement, copy)
            run("check", copy)
            assert copy.read_bytes().endswith(raw), example

print("Mermaid CLI integration passed")
