#!/usr/bin/env python3
"""Vendor the pinned upstream Mermaid conformance corpus (issue #821).

Fetches the Markdown syntax documentation of one tagged Mermaid release from
raw.githubusercontent.com, extracts every ```mermaid / ```mermaid-example /
```mermaid-nocode fenced block and writes one corpus file per block:

    tests/mermaid_corpus/<family>/<doc>_<nnn>.mmd

plus tests/mermaid_corpus/index.txt (one line per example: path, upstream
doc, 1-based fence line) and tests/mermaid_corpus/LICENSE.mermaid (the
upstream MIT license text). Classifications live in manifest.txt next to
them; that file is written by the W side (`./wbuild mermaid_corpus_update`),
never by this script.

Usage (from the repository root; needs network):

    python3 -I tools/mermaid_corpus_extract.py [--tag mermaid@12.2.0]
    python3 -I tools/mermaid_corpus_extract.py --from-dir DIR   # offline

`--from-dir` reads <DIR>/<doc>.md and <DIR>/LICENSE instead of fetching, for
reviewing a locally checked-out upstream tree. Running it removes every
previously extracted *.mmd under tests/mermaid_corpus/ first, so a version
bump that drops or renumbers examples leaves no stale files behind.
"""

import argparse
import os
import re
import sys
import urllib.parse
import urllib.request

DEFAULT_TAG = "mermaid@12.2.0"
RAW = "https://raw.githubusercontent.com/mermaid-js/mermaid/{tag}/{path}"
SYNTAX_DIR = "packages/mermaid/src/docs/syntax"

# Every page in the release's docs sidebar (packages/mermaid/src/docs/
# .vitepress/config.ts) plus railroad.md, which ships in the syntax
# directory without a sidebar entry. Value: the family a block falls back to
# when its header is not recognized.
DOCS = {
    "agentflow": "agentflow",
    "architecture": "architecture",
    "block": "block",
    "c4": "c4",
    "classDiagram": "class",
    "cynefin": "cynefin",
    "entityRelationshipDiagram": "er",
    "eventmodeling": "eventmodeling",
    "examples": "other",
    "flowchart": "flowchart",
    "gantt": "gantt",
    "gitgraph": "gitgraph",
    "ishikawa": "ishikawa",
    "kanban": "kanban",
    "mindmap": "mindmap",
    "packet": "packet",
    "pie": "pie",
    "quadrantChart": "quadrant",
    "radar": "radar",
    "railroad": "railroad",
    "requirementDiagram": "requirement",
    "sankey": "sankey",
    "sequenceDiagram": "sequence",
    "stateDiagram": "state",
    "swimlanes": "swimlane",
    "timeline": "timeline",
    "treeView": "treeview",
    "treemap": "treemap",
    "usecase": "usecase",
    "userJourney": "journey",
    "venn": "venn",
    "wardley": "wardley",
    "xyChart": "xychart",
    "zenuml": "zenuml",
}

HEADERS = {
    "flowchart": "flowchart", "flowchart-elk": "flowchart", "graph": "flowchart",
    "sequencediagram": "sequence",
    "classdiagram": "class", "classdiagram-v2": "class",
    "statediagram": "state", "statediagram-v2": "state",
    "erdiagram": "er",
    "journey": "journey",
    "gantt": "gantt",
    "pie": "pie",
    "quadrantchart": "quadrant",
    "requirementdiagram": "requirement", "requirement": "requirement",
    "gitgraph": "gitgraph",
    "c4context": "c4", "c4container": "c4", "c4component": "c4",
    "c4dynamic": "c4", "c4deployment": "c4",
    "mindmap": "mindmap",
    "timeline": "timeline",
    "zenuml": "zenuml",
    "sankey": "sankey", "sankey-beta": "sankey",
    "xychart": "xychart", "xychart-beta": "xychart",
    "block": "block", "block-beta": "block",
    "packet": "packet", "packet-beta": "packet",
    "kanban": "kanban",
    "architecture": "architecture", "architecture-beta": "architecture",
    "radar": "radar", "radar-beta": "radar",
    "treemap": "treemap", "treemap-beta": "treemap",
    "venn": "venn", "venn-beta": "venn",
    "ishikawa": "ishikawa", "ishikawa-beta": "ishikawa",
    "cynefin": "cynefin", "cynefin-beta": "cynefin",
    "wardley": "wardley", "wardley-beta": "wardley",
    "treeview": "treeview", "treeview-beta": "treeview",
    "usecase": "usecase", "usecase-beta": "usecase",
    "swimlane": "swimlane", "swimlane-beta": "swimlane",
    "eventmodeling": "eventmodeling", "eventmodeling-beta": "eventmodeling",
    "railroad": "railroad", "railroad-beta": "railroad",
    "railroad-ebnf-beta": "railroad", "railroad-abnf-beta": "railroad",
    "railroad-peg-beta": "railroad",
    "agentflow": "agentflow", "agentflow-beta": "agentflow",
}

FENCE = re.compile(r"^([ \t]*)(`{3,}|~{3,})[ \t]*(mermaid(?:-example|-nocode)?)[ \t]*$")


def fetch(tag, path):
    url = RAW.format(tag=urllib.parse.quote(tag, safe=""), path=path)
    with urllib.request.urlopen(url, timeout=60) as response:
        return response.read().decode("utf-8")


def header_family(text):
    lines = text.split("\n")
    i = 0
    if lines and lines[0].strip() == "---":
        i = 1
        while i < len(lines) and lines[i].strip() != "---":
            i += 1
        i += 1
    while i < len(lines):
        line = lines[i].strip()
        i += 1
        if not line or line.startswith("%%"):
            continue
        word = re.split(r"[\s:{;]", line, maxsplit=1)[0].lower()
        return HEADERS.get(word)
    return None


def extract_blocks(markdown):
    """Yields (fence line, body) for every Mermaid fenced block."""
    lines = markdown.split("\n")
    i = 0
    while i < len(lines):
        m = FENCE.match(lines[i])
        if not m:
            # Skip other fenced blocks whole so their contents never match.
            other = re.match(r"^[ \t]*(`{3,}|~{3,})", lines[i])
            if other:
                close = other.group(1)
                i += 1
                while i < len(lines) and not lines[i].strip().startswith(close):
                    i += 1
            i += 1
            continue
        indent, close = m.group(1), m.group(2)
        start = i + 1
        body = []
        i += 1
        while i < len(lines):
            stripped = lines[i].strip()
            if stripped.startswith(close[0] * len(close)) and set(stripped) == {close[0]}:
                break
            line = lines[i]
            if indent and line.startswith(indent):
                line = line[len(indent):]
            body.append(line)
            i += 1
        i += 1
        text = "\n".join(body).rstrip() + "\n"
        yield start, text


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--tag", default=DEFAULT_TAG)
    parser.add_argument("--from-dir")
    parser.add_argument("--out", default="tests/mermaid_corpus")
    args = parser.parse_args()

    for root, _dirs, files in os.walk(args.out):
        for name in files:
            if name.endswith(".mmd"):
                os.remove(os.path.join(root, name))

    def read(name, path):
        if args.from_dir:
            with open(os.path.join(args.from_dir, name), encoding="utf-8") as f:
                return f.read()
        return fetch(args.tag, path)

    index = []
    counts = {}
    for doc in sorted(DOCS, key=str.lower):
        markdown = read(doc + ".md", SYNTAX_DIR + "/" + doc + ".md")
        for n, (line, text) in enumerate(extract_blocks(markdown), 1):
            family = header_family(text) or DOCS[doc]
            rel = "%s/%s_%03d.mmd" % (family, doc, n)
            path = os.path.join(args.out, rel)
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "w", encoding="utf-8", newline="\n") as f:
                f.write(text)
            index.append("%s\t%s.md\t%d" % (rel, doc, line))
            counts[family] = counts.get(family, 0) + 1

    with open(os.path.join(args.out, "index.txt"), "w", encoding="utf-8", newline="\n") as f:
        f.write("# Generated by tools/mermaid_corpus_extract.py from %s; do not edit.\n" % args.tag)
        f.write("# path<TAB>upstream doc (%s/)<TAB>fence line\n" % SYNTAX_DIR)
        for row in index:
            f.write(row + "\n")
    license_text = read("LICENSE", "LICENSE")
    with open(os.path.join(args.out, "LICENSE.mermaid"), "w", encoding="utf-8", newline="\n") as f:
        f.write(license_text)
    total = sum(counts.values())
    print("extracted %d examples from %d docs (%s)" % (total, len(DOCS), args.tag))
    for family in sorted(counts):
        print("  %-14s %d" % (family, counts[family]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
