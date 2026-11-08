#!/usr/bin/env python3
"""Generate libs/extras/javascript/regexp_property.w from tools/unicode/12.1.0.

RegExp property escapes (ECMA-262 2020 sec-runtime-semantics-unicodematchproperty-p)
are validated and matched against one Unicode version, 12.1 (the ES2020 data
set; see docs/projects/javascript.md). This script reads the vendored 12.1 UCD
files and emits:

- General_Category as a partition of the code space (start, category) with a
  bit mask per value, so group values (L, LC, M, ...) are one AND;
- Script as a partition (start, script) and Script_Extensions as the ranges
  whose extension set differs from {Script}, with their sets;
- every ES2020 binary property as sorted (first, last) ranges XORed with the
  cheapest earlier property (Any, ASCII and Assigned are computed; ID_Start and
  ID_Continue reuse the identifier tables in unicode.w).

The name -> id tables follow the word order of the validation tables in
regexp_syntax.w, and the script fails if those tables do not hold exactly the
12.1 PropertyValueAliases names (so validation and matching cannot drift).
Usage: tools/javascript_regexp_property.py [--check | --verify DUMP_BINARY]
"""
from __future__ import annotations

import hashlib
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
UCD = ROOT / "tools/unicode/12.1.0"
SYNTAX = ROOT / "libs/extras/javascript/regexp_syntax.w"
OUTPUT = ROOT / "libs/extras/javascript/regexp_property.w"
MAX = 0x10FFFF

# ES2020 table 54 (binary Unicode property aliases), canonical name -> source.
# "computed" properties have no UCD file.
BINARY = [
    ("ASCII", "computed"), ("ASCII_Hex_Digit", "PropList"), ("Alphabetic", "DerivedCoreProperties"),
    ("Any", "computed"), ("Assigned", "computed"), ("Bidi_Control", "PropList"),
    ("Bidi_Mirrored", "DerivedBinaryProperties"), ("Case_Ignorable", "DerivedCoreProperties"),
    ("Cased", "DerivedCoreProperties"), ("Changes_When_Casefolded", "DerivedCoreProperties"),
    ("Changes_When_Casemapped", "DerivedCoreProperties"), ("Changes_When_Lowercased", "DerivedCoreProperties"),
    ("Changes_When_NFKC_Casefolded", "DerivedNormalizationProps"),
    ("Changes_When_Titlecased", "DerivedCoreProperties"), ("Changes_When_Uppercased", "DerivedCoreProperties"),
    ("Dash", "PropList"), ("Default_Ignorable_Code_Point", "DerivedCoreProperties"), ("Deprecated", "PropList"),
    ("Diacritic", "PropList"), ("Emoji", "emoji-data"), ("Emoji_Component", "emoji-data"),
    ("Emoji_Modifier", "emoji-data"), ("Emoji_Modifier_Base", "emoji-data"), ("Emoji_Presentation", "emoji-data"),
    ("Extended_Pictographic", "emoji-data"), ("Extender", "PropList"), ("Grapheme_Base", "DerivedCoreProperties"),
    ("Grapheme_Extend", "DerivedCoreProperties"), ("Hex_Digit", "PropList"), ("IDS_Binary_Operator", "PropList"),
    ("IDS_Trinary_Operator", "PropList"), ("ID_Continue", "DerivedCoreProperties"),
    ("ID_Start", "DerivedCoreProperties"), ("Ideographic", "PropList"), ("Join_Control", "PropList"),
    ("Logical_Order_Exception", "PropList"), ("Lowercase", "DerivedCoreProperties"), ("Math", "DerivedCoreProperties"),
    ("Noncharacter_Code_Point", "PropList"), ("Pattern_Syntax", "PropList"), ("Pattern_White_Space", "PropList"),
    ("Quotation_Mark", "PropList"), ("Radical", "PropList"), ("Regional_Indicator", "PropList"),
    ("Sentence_Terminal", "PropList"), ("Soft_Dotted", "PropList"), ("Terminal_Punctuation", "PropList"),
    ("Unified_Ideograph", "PropList"), ("Uppercase", "DerivedCoreProperties"), ("Variation_Selector", "PropList"),
    ("White_Space", "PropList"), ("XID_Continue", "DerivedCoreProperties"), ("XID_Start", "DerivedCoreProperties"),
]
# ES2020 table 54 short aliases (PropertyAliases.txt 12.1).
BINARY_ALIASES = {
    "ASCII_Hex_Digit": "AHex", "Alphabetic": "Alpha", "Bidi_Control": "Bidi_C", "Bidi_Mirrored": "Bidi_M",
    "Case_Ignorable": "CI", "Changes_When_Casefolded": "CWCF", "Changes_When_Casemapped": "CWCM",
    "Changes_When_Lowercased": "CWL", "Changes_When_NFKC_Casefolded": "CWKCF", "Changes_When_Titlecased": "CWT",
    "Changes_When_Uppercased": "CWU", "Default_Ignorable_Code_Point": "DI", "Deprecated": "Dep",
    "Diacritic": "Dia", "Extender": "Ext", "Grapheme_Base": "Gr_Base", "Grapheme_Extend": "Gr_Ext",
    "Hex_Digit": "Hex", "IDS_Binary_Operator": "IDSB", "IDS_Trinary_Operator": "IDST", "ID_Continue": "IDC",
    "ID_Start": "IDS", "Ideographic": "Ideo", "Join_Control": "Join_C", "Logical_Order_Exception": "LOE",
    "Lowercase": "Lower", "Noncharacter_Code_Point": "NChar", "Pattern_Syntax": "Pat_Syn",
    "Pattern_White_Space": "Pat_WS", "Quotation_Mark": "QMark", "Regional_Indicator": "RI",
    "Sentence_Terminal": "STerm", "Soft_Dotted": "SD", "Terminal_Punctuation": "Term",
    "Unified_Ideograph": "UIdeo", "Uppercase": "Upper", "Variation_Selector": "VS", "White_Space": "space",
    "XID_Continue": "XIDC", "XID_Start": "XIDS",
}


def lines(name: str):
    for line in (UCD / name).read_text().splitlines():
        line = line.split("#")[0].strip()
        if line:
            yield [part.strip() for part in line.split(";")]


def span(text: str) -> tuple[int, int]:
    first, _, last = text.partition("..")
    return int(first, 16), int(last or first, 16)


def version(name: str) -> str:
    text = (UCD / name).read_text()
    match = re.search(r"^# Version: ([0-9.]+)$", text, re.M)
    if match:
        return match.group(1)
    return text.splitlines()[0].split("-")[-1].removesuffix(".txt")


def aliases(prop: str) -> list[list[str]]:
    """PropertyValueAliases rows for prop: [short, long, extra aliases...]."""
    return [fields[1:] for fields in lines("PropertyValueAliases.txt") if fields[0] == prop]


def gc_values():
    rows = aliases("gc")
    leaves = [row[0] for row in rows if len(row[0]) == 2 and row[0] != "LC"]
    groups = {"C": "Cc Cf Cn Co Cs", "L": "Ll Lm Lo Lt Lu", "LC": "Ll Lt Lu", "M": "Mc Me Mn",
              "N": "Nd Nl No", "P": "Pc Pd Pe Pf Pi Po Ps", "S": "Sc Sk Sm So", "Z": "Zl Zp Zs"}
    masks = {}
    names = {}
    for row in rows:
        members = groups.get(row[0], row[0]).split()
        masks[row[0]] = sum(1 << leaves.index(member) for member in members)
        for name in row:
            names[name] = row[0]
    return leaves, masks, names


def script_values():
    rows = aliases("sc")
    codes = [row[0] for row in rows]
    names = {name: row[0] for row in rows for name in row}
    return codes, names


def partition(assign: dict[int, int], default: int) -> list[tuple[int, int]]:
    """Run starts of a total function on 0..MAX given sparse assignments."""
    out = []
    previous = None
    for cp in range(MAX + 1):
        value = assign.get(cp, default)
        if value != previous:
            out.append((cp, value))
            previous = value
    return out


def ranges(points: set[int]) -> list[tuple[int, int]]:
    out: list[list[int]] = []
    for cp in sorted(points):
        if out and out[-1][1] + 1 == cp:
            out[-1][1] = cp
        else:
            out.append([cp, cp])
    return [(a, b) for a, b in out]


def u24(value: int) -> bytes:
    return bytes([value & 255, (value >> 8) & 255, (value >> 16) & 255])


def literal(data: bytes) -> str:
    return "".join(f"\\x{byte:02x}" for byte in data)


def syntax_table(function: str) -> list[str]:
    text = SYNTAX.read_text()
    match = re.search(r"char\* " + function + r"\(\):\n\treturn c\"([^\"]*)\"", text)
    if match is None:
        raise SystemExit(f"{SYNTAX}: cannot find {function}")
    return match.group(1).split()


def binary_points(source: str, wanted: set[str]) -> dict[str, set[int]]:
    files = {"PropList": "PropList.txt", "DerivedCoreProperties": "DerivedCoreProperties.txt",
             "DerivedNormalizationProps": "DerivedNormalizationProps.txt",
             "DerivedBinaryProperties": "DerivedBinaryProperties.txt", "emoji-data": "emoji-data.txt"}
    out: dict[str, set[int]] = {name: set() for name in wanted}
    for fields in lines(files[source]):
        if len(fields) == 2 and fields[1] in wanted:
            first, last = span(fields[0])
            out[fields[1]].update(range(first, last + 1))
    return out


def identifier_ranges() -> dict[str, set[int]]:
    out: dict[str, set[int]] = {"ID_Start": set(), "ID_Continue": set()}
    for line in (ROOT / "libs/extras/javascript/unicode_12_1.ranges").read_text().splitlines():
        if line and not line.startswith("#"):
            first, name = line.split(";")
            low, high = span(first)
            out[name].update(range(low, high + 1))
    return out


MODEL: dict = {}


def verify_pins() -> None:
    """Inputs must match the SHA-256 list in tools/unicode/12.1.0/PROVENANCE.txt."""
    pins = re.findall(r"^  ([0-9a-f]{64})  (\S+)$", (UCD / "PROVENANCE.txt").read_text(), re.M)
    if not pins:
        raise SystemExit(f"{UCD}/PROVENANCE.txt lists no pins")
    for digest, name in pins:
        if hashlib.sha256((UCD / name).read_bytes()).hexdigest() != digest:
            raise SystemExit(f"{UCD / name} does not match its PROVENANCE.txt SHA-256")


def render() -> str:
    verify_pins()
    leaves, masks, gc_names = gc_values()
    script_codes, script_names = script_values()
    gc_of: dict[int, int] = {}
    for fields in lines("DerivedGeneralCategory.txt"):
        first, last = span(fields[0])
        for cp in range(first, last + 1):
            gc_of[cp] = leaves.index(fields[1])
    sc_of: dict[int, int] = {}
    long_to_code = {name: code for name, code in script_names.items()}
    for fields in lines("Scripts.txt"):
        first, last = span(fields[0])
        for cp in range(first, last + 1):
            sc_of[cp] = script_codes.index(long_to_code[fields[1]])
    scx_of: dict[int, tuple[int, ...]] = {}
    for fields in lines("ScriptExtensions.txt"):
        first, last = span(fields[0])
        members = tuple(sorted(script_codes.index(script_names[name]) for name in fields[1].split()))
        for cp in range(first, last + 1):
            scx_of[cp] = members

    # Validation tables must be exactly the 12.1 names (plus the ES2020
    # binary table) so every validated escape has data.
    syntax_gc = syntax_table("js_regexp_gc_names")
    syntax_sc = syntax_table("js_regexp_script_names")
    syntax_bin = syntax_table("js_regexp_binary_names")
    expected_bin = {name for name, _ in BINARY} | set(BINARY_ALIASES.values())
    for label, have, want in [("General_Category", syntax_gc, set(gc_names)),
                              ("Script", syntax_sc, set(script_names)),
                              ("binary", syntax_bin, expected_bin)]:
        if set(have) != want or len(have) != len(set(have)):
            extra = sorted(set(have) - want)
            missing = sorted(want - set(have))
            raise SystemExit(f"{SYNTAX}: {label} names differ from Unicode 12.1: extra {extra}, missing {missing}")
    canonical_bin = {alias: name for name, alias in BINARY_ALIASES.items()} | {name: name for name, _ in BINARY}
    binary_order = [name for name, _ in BINARY]
    gc_value_order = list(masks)

    gc_ids = bytes(gc_value_order.index(gc_names[name]) for name in syntax_gc)
    sc_ids = bytes(script_codes.index(script_names[name]) for name in syntax_sc)
    bin_ids = bytes(binary_order.index(canonical_bin[name]) for name in syntax_bin)

    gc_part = partition(gc_of, leaves.index("Cn"))
    sc_part = partition(sc_of, script_codes.index("Zzzz"))
    sets: list[tuple[int, ...]] = []
    scx_assign: dict[int, int] = {}
    for cp, members in scx_of.items():
        if members == (sc_of.get(cp),):
            continue
        if members not in sets:
            sets.append(members)
        scx_assign[cp] = sets.index(members) + 1
    scx_part = partition(scx_assign, 0)
    set_data = bytearray()
    set_offsets = bytearray()
    for members in sets:
        set_offsets += bytes([len(set_data) & 255, len(set_data) >> 8])
        set_data += bytes([len(members)]) + bytes(members)

    points: dict[str, set[int]] = {}
    for source in sorted({source for _, source in BINARY if source != "computed"}):
        points.update(binary_points(source, {name for name, s in BINARY if s == source}))
    # ID_Start/ID_Continue reuse the identifier tables in unicode.w (generated
    # from the same 12.1 DerivedCoreProperties); check they still agree.
    for name, values in identifier_ranges().items():
        if values != points[name]:
            raise SystemExit(f"libs/extras/javascript/unicode_12_1.ranges {name} differs from {UCD}")
    points["Assigned"] = {cp for cp, value in gc_of.items() if value != leaves.index("Cn")}
    # Each stored property is base XOR ranges, with the base chosen (smallest
    # property first) to minimise the stored ranges; 255 means no base.
    computed = {"Any", "ASCII", "Assigned", "ID_Start", "ID_Continue"}
    plan: dict[str, tuple[str | None, list[tuple[int, int]]]] = {}
    done = sorted(computed - {"Any", "ASCII"})
    for name in sorted(points.keys() - computed, key=lambda key: (len(ranges(points[key])), key)):
        if not points[name]:
            raise SystemExit(f"no Unicode 12.1 data for {name}")
        best: tuple[str | None, list[tuple[int, int]]] = (None, ranges(points[name]))
        for base in done:
            spans = ranges(points[name] ^ points[base])
            if len(spans) < len(best[1]):
                best = (base, spans)
        plan[name] = best
        done.append(name)
    bin_data = bytearray()
    bin_index = bytearray()
    for name in binary_order:
        base, spans = plan.get(name, (None, []))
        bin_index += u24(len(bin_data) // 6) + u24(len(spans)) + bytes([255 if base is None else binary_order.index(base)])
        for first, last in spans:
            bin_data += u24(first) + u24(last)
    mask_data = b"".join(masks[value].to_bytes(4, "little") for value in gc_value_order)

    def part_bytes(part: list[tuple[int, int]]) -> bytes:
        return b"".join(u24(start) + bytes([value]) for start, value in part)

    computed_ids = {name: binary_order.index(name) for name in computed}
    points["Any"] = set(range(MAX + 1))
    points["ASCII"] = set(range(128))
    MODEL.update(gc=gc_of, cn=leaves.index("Cn"), sc=sc_of, unknown=script_codes.index("Zzzz"), scx=scx_of,
                 scripts=len(script_codes), binary=[points[name] for name in binary_order])
    return f'''# Generated by tools/javascript_regexp_property.py from tools/unicode/12.1.0
# (Unicode {version("PropertyValueAliases.txt")} UCD, emoji data {version("emoji-data.txt")}).
# Copyright Unicode, Inc.; see UNICODE-LICENSE.txt. Do not edit.
# RegExp \\p{{...}} data: General_Category ({len(gc_part)} runs), Script
# ({len(sc_part)} runs), Script_Extensions ({len(scx_part)} runs, {len(sets)} sets) and
# {len(binary_order)} ES2020 binary properties ({len(bin_data) // 6} XOR ranges).
import libs.extras.javascript.regexp_syntax
import libs.extras.javascript.unicode


int js_regexp_property_u24(char* data, int offset):
\treturn (data[offset] & 255) | ((data[offset + 1] & 255) << 8) | ((data[offset + 2] & 255) << 16)


# Value of the run containing cp in a (start u24, value u8) partition.
int js_regexp_property_run(char* data, int count, int cp):
\tint lo = 0
\tint hi = count - 1
\twhile (lo < hi):
\t\tint mid = hi - (hi - lo) / 2
\t\tif (js_regexp_property_u24(data, mid * 4) <= cp): lo = mid
\t\telse: hi = mid - 1
\treturn data[lo * 4 + 3] & 255


int js_regexp_property_in_ranges(char* data, int first, int count, int cp):
\tint lo = first
\tint hi = first + count
\twhile (lo < hi):
\t\tint mid = lo + (hi - lo) / 2
\t\tif (cp < js_regexp_property_u24(data, mid * 6)): hi = mid
\t\telse if (cp > js_regexp_property_u24(data, mid * 6 + 3)): lo = mid + 1
\t\telse: return 1
\treturn 0


# Runtime ids for the validation table words (1-based word index - 1).
int js_regexp_property_gc_id(int index):
\tchar* ids = c"{literal(gc_ids)}"\n\treturn ids[index - 1] & 255


int js_regexp_property_script_id(int index):
\tchar* ids = c"{literal(sc_ids)}"\n\treturn ids[index - 1] & 255


int js_regexp_property_binary_id(int index):
\tchar* ids = c"{literal(bin_ids)}"\n\treturn ids[index - 1] & 255


int js_regexp_property_gc(int cp):
\treturn js_regexp_property_run(c"{literal(part_bytes(gc_part))}", {len(gc_part)}, cp)


int js_regexp_property_script(int cp):
\treturn js_regexp_property_run(c"{literal(part_bytes(sc_part))}", {len(sc_part)}, cp)


int js_regexp_property_has_gc(int id, int cp):
\tchar* masks = c"{literal(mask_data)}"
\tint mask = (masks[id * 4] & 255) | ((masks[id * 4 + 1] & 255) << 8) | ((masks[id * 4 + 2] & 255) << 16) | ((masks[id * 4 + 3] & 255) << 24)
\treturn (mask >> js_regexp_property_gc(cp)) & 1


int js_regexp_property_has_scx(int id, int cp):
\tint which = js_regexp_property_run(c"{literal(part_bytes(scx_part))}", {len(scx_part)}, cp)
\tif (which == 0): return js_regexp_property_script(cp) == id
\tchar* offsets = c"{literal(bytes(set_offsets))}"
\tchar* members = c"{literal(bytes(set_data))}"
\tint at = (offsets[(which - 1) * 2] & 255) | ((offsets[(which - 1) * 2 + 1] & 255) << 8)
\tfor i in range(members[at] & 255):
\t\tif ((members[at + 1 + i] & 255) == id): return 1
\treturn 0


char* js_regexp_property_binary_data():
\treturn c"{literal(bytes(bin_data))}"


int js_regexp_property_has_binary(int id, int cp):
\tif (id == {computed_ids["Any"]}): return 1
\tif (id == {computed_ids["ASCII"]}): return cp < 128
\tif (id == {computed_ids["Assigned"]}): return js_regexp_property_gc(cp) != {leaves.index("Cn")}
\tif (id == {computed_ids["ID_Start"]}): return js_unicode_id_start(cp)
\tif (id == {computed_ids["ID_Continue"]}): return js_unicode_id_continue(cp)
\t# Records: first range u24, range count u24, base property (255: none).
\tchar* index = c"{literal(bytes(bin_index))}"
\tint has = js_regexp_property_in_ranges(js_regexp_property_binary_data(), js_regexp_property_u24(index, id * 7), js_regexp_property_u24(index, id * 7 + 3), cp)
\tint base = index[id * 7 + 6] & 255
\tif (base == 255): return has
\treturn has != js_regexp_property_has_binary(base, cp)


# kind is JS_RX_PROPERTY_BINARY/GC/SCRIPT/SCX and id a runtime id above.
int js_regexp_property_has(int kind, int id, int cp):
\tif (kind == JS_RX_PROPERTY_GC): return js_regexp_property_has_gc(id, cp)
\tif (kind == JS_RX_PROPERTY_SCRIPT): return js_regexp_property_script(cp) == id
\tif (kind == JS_RX_PROPERTY_SCX): return js_regexp_property_has_scx(id, cp)
\treturn js_regexp_property_has_binary(id, cp)
'''


def scx_sample() -> list[int]:
    return [cp for cp in range(MAX + 1) if cp in MODEL["scx"] or cp % 61 == 0]


def expected_dump() -> list[str]:
    """What `<test binary> dump` must print: run starts of General_Category and
    Script, Script_Extensions for the sampled code points it reads from stdin
    (every ScriptExtensions.txt entry plus every 61st), then each binary property's membership transitions."""
    out = ["gc"]
    previous = None
    for cp in range(MAX + 1):
        value = MODEL["gc"].get(cp, MODEL["cn"])
        if value != previous:
            out.append(f"{cp} {value}")
            previous = value
    out.append("sc")
    previous = None
    for cp in range(MAX + 1):
        value = MODEL["sc"].get(cp, MODEL["unknown"])
        if value != previous:
            out.append(f"{cp} {value}")
            previous = value
    out.append("scx")
    for cp in scx_sample():
        members = MODEL["scx"].get(cp, (MODEL["sc"].get(cp, MODEL["unknown"]),))
        out.append(" ".join(str(item) for item in [cp, *sorted(members)]))
    for index, members in enumerate(MODEL["binary"]):
        out.append(f"binary {index}")
        for first, last in ranges(members):
            out.append(str(first))
            if last < MAX:
                out.append(str(last + 1))
    return out


def verify(binary: str) -> int:
    import subprocess
    sample = "".join(f"{cp}\n" for cp in scx_sample())
    result = subprocess.run([binary, "dump", str(MODEL["scripts"])], input=sample, capture_output=True, text=True, check=False)
    if result.returncode != 0:
        print(f"{binary} dump failed: {result.stderr}", file=sys.stderr)
        return 1
    actual = result.stdout.splitlines()
    expected = expected_dump()
    if actual != expected:
        for index, (left, right) in enumerate(zip(actual, expected)):
            if left != right:
                print(f"line {index + 1}: got {left!r}, expected {right!r}", file=sys.stderr)
                break
        else:
            print(f"got {len(actual)} lines, expected {len(expected)}", file=sys.stderr)
        return 1
    print(f"regexp property tables match Unicode 12.1: {len(expected)} records")
    return 0


def main() -> int:
    text = render()
    if len(sys.argv) == 3 and sys.argv[1] == "--verify":
        return verify(sys.argv[2])
    if sys.argv[1:] == ["--check"]:
        if not OUTPUT.exists() or OUTPUT.read_text() != text:
            print(f"{OUTPUT} is stale; run tools/javascript_regexp_property.py", file=sys.stderr)
            return 1
        return 0
    if sys.argv[1:]:
        print(__doc__, file=sys.stderr)
        return 2
    OUTPUT.write_text(text)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
