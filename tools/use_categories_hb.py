#!/usr/bin/env python3
"""Extract HarfBuzz's Universal Shaping Engine categories.

    git clone --depth 1 --branch 15.0.0 https://github.com/harfbuzz/harfbuzz
    python3 tools/use_categories_hb.py harfbuzz/src > tools/unicode/use_categories.txt

HarfBuzz builds its USE category table (src/hb-ot-shaper-use-table.hh)
with gen-use-table.py from the Unicode Character Database plus
Microsoft's USE overrides (src/ms-use/). Rather than port that script
and carry a second, newer copy of the UCD, this compiles the generated
table with a C compiler (cc) and prints every non-Other range as
"XXXX..YYYY; CAT" in codepoint order, with the category names of
src/hb-ot-shaper-use-machine.rl. tools/generate_use_data.w turns the
file into lib/ttf_use_data.w for lib/ttf_use.w (issue #825).
"""
import os
import re
import subprocess
import sys
import tempfile


def main():
    if len(sys.argv) != 2:
        print(__doc__)
        return 2
    src = sys.argv[1]
    machine = open(os.path.join(src, "hb-ot-shaper-use-machine.rl")).read()
    exports = re.findall(r"^export\s+(\w+)\s*=\s*(\d+);", machine, re.M)
    table = open(os.path.join(src, "hb-ot-shaper-use-table.hh")).read().splitlines()
    # The table body: from the category #defines to the first (size-
    # optimized off) hb_use_get_category, without the hb.hh includes.
    start = next(i for i, line in enumerate(table) if line.startswith("#define B\t"))
    end = next(i for i, line in enumerate(table) if line.startswith("static inline uint8_t hb_use_get_category"))
    body = []
    for line in table[start:end + 5]:
        if line.startswith("#pragma") or line.startswith("#ifndef HB_OPTIMIZE_SIZE"):
            continue
        body.append(line)
    program = []
    for name, value in exports:
        program.append("#define USE_%s %s" % (name, value))
    program.append("#define USE(x) USE_##x")
    program.extend(body)
    program.append("#include <stdio.h>")
    program.append("static const char *names[64];")
    program.append("int main(void) {")
    for name, value in exports:
        program.append('  names[%s] = "%s";' % (value, name))
    program.append("  unsigned start = 0; int prev = hb_use_get_category(0);")
    program.append("  for (unsigned u = 1; u <= 0x110000; u++) {")
    program.append("    int c = u < 0x110000 ? hb_use_get_category(u) : -1;")
    program.append("    if (c == prev) continue;")
    program.append('    if (prev != USE_O) printf("%04X..%04X; %s\\n", start, u - 1, names[prev]);')
    program.append("    start = u; prev = c;")
    program.append("  }")
    program.append("  return 0;")
    program.append("}")
    with tempfile.TemporaryDirectory() as tmp:
        c_path = os.path.join(tmp, "dump.c")
        exe = os.path.join(tmp, "dump")
        with open(c_path, "w") as f:
            f.write("\n".join(program) + "\n")
        subprocess.run(["cc", "-w", "-o", exe, c_path], check=True)
        ranges = subprocess.run([exe], capture_output=True, text=True, check=True).stdout
    header = table[1:48]
    print("# Universal Shaping Engine categories of HarfBuzz 15.0.0, extracted")
    print("# from src/hb-ot-shaper-use-table.hh by tools/use_categories_hb.py.")
    print("# Every codepoint not listed is O (Other). Category names are those of")
    print("# src/hb-ot-shaper-use-machine.rl. HarfBuzz is MIT licensed; its table")
    print("# header follows:")
    for line in header:
        if line.startswith(" * ") or line == " *":
            print("#" + line[2:])
    sys.stdout.write(ranges)
    return 0


if __name__ == "__main__":
    sys.exit(main())
