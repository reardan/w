#!/usr/bin/env python3
"""Host-side consistency check for the Android JNI bridge (no SDK needed).

Every `extern` in graphics/android/{ui,kit}.w must have a C definition in
tools/android/{host,kit}.c with the same parameter count; kit.c and
WKit.java must agree on operation codes; WActivity must provide the Java
methods that host.c and kit.c look up by name and signature.
"""
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[2]


def externs(path):
    found = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        match = re.match(r"extern\s+\S+\s+(\w+)\((.*)\)\s*$", line)
        if match:
            params = [p for p in match.group(2).split(",") if p.strip()]
            found[match.group(1)] = len(params)
    return found


def definitions(text):
    found = {}
    for match in re.finditer(r"^(?:intptr_t|void)\s+(wandroid_\w+)\(([^)]*)\)\s*\{", text, re.M):
        params = [p for p in match.group(2).split(",") if p.strip() and p.strip() != "void"]
        found[match.group(1)] = len(params)
    return found


def main():
    android = ROOT / "tools/android"
    c_text = (android / "host.c").read_text(encoding="utf-8") + (android / "kit.c").read_text(encoding="utf-8")
    defined = definitions(c_text)
    errors = []
    declared = {}
    for source in ("graphics/android/ui.w", "graphics/android/kit.w"):
        declared.update(externs(ROOT / source))
    for name, count in sorted(declared.items()):
        if name not in defined:
            errors.append(f"{name} is declared in W but not defined in host.c/kit.c")
        elif defined[name] != count:
            errors.append(f"{name}: W declares {count} parameters, C defines {defined[name]}")
    kit_c = (android / "kit.c").read_text(encoding="utf-8")
    enum = re.search(r"enum \{\s*(OP_SCREEN = 32,[^}]*)\}", kit_c).group(1)
    c_ops = {}
    value = 31
    for item in re.findall(r"(OP_\w+)(?:\s*=\s*(\d+))?", enum):
        value = int(item[1]) if item[1] else value + 1
        c_ops[item[0]] = value
    java = (android / "WKit.java").read_text(encoding="utf-8")
    java_ops = {name: int(number) for name, number in re.findall(r"\b(OP_\w+) = (\d+)", java)}
    if c_ops != java_ops:
        errors.append(f"kit.c and WKit.java operation codes differ: {sorted(set(c_ops.items()) ^ set(java_ops.items()))}")
    for name in ("GET_TEXT", "GET_SECURE", "GET_URI"):
        c_value = re.search(rf"{name} = (\d+)", kit_c)
        j_value = re.search(rf"{name} = (\d+)", java)
        if not c_value or not j_value or c_value.group(1) != j_value.group(1):
            errors.append(f"{name} differs between kit.c and WKit.java")
    activity = (android / "WActivity.java").read_text(encoding="utf-8")
    for signature in (r"public long kitCall\(int op, long a, long b, byte\[\] s, byte\[\] t, byte\[\] u, byte\[\] v\)",
                      r"public byte\[\] kitBytes\(int op, long a, byte\[\] s\)",
                      r"public long addControl\(int kind, byte\[\] bytes\)",
                      r"public void setLabel\(long handle, byte\[\] bytes\)"):
        if not re.search(signature, activity):
            errors.append(f"WActivity lacks {signature}")
    if '"kitCall", "(IJJ[B[B[B[B)J"' not in kit_c or '"kitBytes", "(IJ[B)[B"' not in kit_c:
        errors.append("kit.c JNI signatures do not match WActivity")
    kit_w = (ROOT / "graphics/android/kit.w").read_text(encoding="utf-8")
    events = dict(re.findall(r"const int android_event_(\w+) = (\d+)", kit_w))
    for name, number in re.findall(r"EVENT_(\w+) = (\d+)", java):
        if name.lower() in ("click", "text"):
            continue
        if events.get(name.lower()) != number:
            errors.append(f"event kind {name} differs between kit.w and WKit.java")
    if errors:
        sys.exit("\n".join(errors))
    print(f"Android bridge: {len(declared)} W externs, {len(c_ops)} kit operations: OK")


if __name__ == "__main__":
    main()
