"""Exercise the real native editor with X11 input, without an automation package.

Run after building wmermaid/wmermaid_editor:
    xvfb-run -a python3 tools/mermaid_editor_ui_test.py
Requires X11 and XTest, and deliberately fails when a display is unavailable.
Unit/controller tests are display-independent and belong to the normal suite.
"""
from __future__ import annotations

import ctypes as C
import ctypes.util
from pathlib import Path
import subprocess
import tempfile
import time
import xml.etree.ElementTree as ET


def eventually(predicate, message, timeout=5):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        result = predicate()
        if result:
            return result
        time.sleep(0.04)
    raise AssertionError(message)


class WindowAttributes(C.Structure):
    _fields_ = [(name, C.c_int) for name in ("x", "y", "width", "height", "border_width", "depth")] + [
        ("visual", C.c_void_p), ("root", C.c_ulong), ("window_class", C.c_int),
        ("bit_gravity", C.c_int), ("win_gravity", C.c_int), ("backing_store", C.c_int),
        ("backing_planes", C.c_ulong), ("backing_pixel", C.c_ulong), ("save_under", C.c_int),
        ("colormap", C.c_ulong), ("map_installed", C.c_int), ("map_state", C.c_int),
        ("all_event_masks", C.c_long), ("your_event_mask", C.c_long),
        ("do_not_propagate_mask", C.c_long), ("override_redirect", C.c_int), ("screen", C.c_void_p),
    ]


class Desktop:
    def __init__(self):
        self.x = C.CDLL(ctypes.util.find_library("X11"))
        self.xt = C.CDLL(ctypes.util.find_library("Xtst"))
        pointer, window = C.c_void_p, C.c_ulong
        signatures = {
            "XOpenDisplay": ([C.c_char_p], pointer),
            "XDefaultRootWindow": ([pointer], window),
            "XQueryTree": ([pointer, window, C.POINTER(window), C.POINTER(window),
                            C.POINTER(C.POINTER(window)), C.POINTER(C.c_uint)], C.c_int),
            "XFetchName": ([pointer, window, C.POINTER(C.c_char_p)], C.c_int),
            "XGetWindowAttributes": ([pointer, window, C.POINTER(WindowAttributes)], C.c_int),
            "XFree": ([pointer], C.c_int),
            "XStringToKeysym": ([C.c_char_p], C.c_ulong),
            "XKeysymToKeycode": ([pointer, C.c_ulong], C.c_uint),
            "XSetInputFocus": ([pointer, window, C.c_int, C.c_ulong], C.c_int),
            "XFlush": ([pointer], C.c_int),
            "XCloseDisplay": ([pointer], C.c_int),
            "XTranslateCoordinates": ([pointer, window, window, C.c_int, C.c_int,
                                        C.POINTER(C.c_int), C.POINTER(C.c_int),
                                        C.POINTER(window)], C.c_int),
        }
        for name, (args, result) in signatures.items():
            fn = getattr(self.x, name)
            fn.argtypes, fn.restype = args, result
        self.xt.XTestFakeKeyEvent.argtypes = [pointer, C.c_uint, C.c_int, C.c_ulong]
        self.xt.XTestFakeButtonEvent.argtypes = [pointer, C.c_uint, C.c_int, C.c_ulong]
        self.xt.XTestFakeMotionEvent.argtypes = [pointer, C.c_int, C.c_int, C.c_int, C.c_ulong]
        self.display = self.x.XOpenDisplay(None)
        assert self.display, "X11 unavailable; run with xvfb-run -a"
        self.root = self.x.XDefaultRootWindow(self.display)
        self.window = 0

    def find_window(self, parent=None):
        parent = self.root if parent is None else parent
        name = C.c_char_p()
        if self.x.XFetchName(self.display, parent, C.byref(name)) and name.value:
            matches = name.value == b"W Mermaid"
            self.x.XFree(name)
            if matches:
                self.window = parent
                return parent
        root, ancestor, children, count = C.c_ulong(), C.c_ulong(), C.POINTER(C.c_ulong)(), C.c_uint()
        if not self.x.XQueryTree(self.display, parent, C.byref(root), C.byref(ancestor),
                                C.byref(children), C.byref(count)):
            return 0
        result = 0
        try:
            for child in children[:count.value]:
                result = self.find_window(child)
                if result:
                    break
        finally:
            if children:
                self.x.XFree(children)
        return result

    def focus(self):
        def viewable():
            attributes = WindowAttributes()
            return self.x.XGetWindowAttributes(self.display, self.window, C.byref(attributes)) and attributes.map_state == 2
        eventually(viewable, "editor window did not become viewable")
        self.x.XSetInputFocus(self.display, self.window, 1, 0)
        self.flush()

    def flush(self):
        self.x.XFlush(self.display)
        time.sleep(0.06)

    def raw_key(self, name, down):
        sym = self.x.XStringToKeysym(name.encode())
        code = self.x.XKeysymToKeycode(self.display, sym)
        assert code, name
        self.xt.XTestFakeKeyEvent(self.display, code, down, 0)

    def key(self, name, *modifiers):
        for modifier in modifiers:
            self.raw_key(modifier, 1)
        self.raw_key(name, 1)
        self.raw_key(name, 0)
        for modifier in reversed(modifiers):
            self.raw_key(modifier, 0)
        self.flush()

    def type_text(self, text):
        for char in text:
            self.key({" ": "space", "\n": "Return"}.get(char, char.lower()),
                     *(["Shift_L"] if char.isupper() else []))

    def move(self, x, y):
        ox, oy, child = C.c_int(), C.c_int(), C.c_ulong()
        self.x.XTranslateCoordinates(self.display, self.window, self.root, 0, 0,
                                     C.byref(ox), C.byref(oy), C.byref(child))
        self.xt.XTestFakeMotionEvent(self.display, -1, ox.value + int(x), oy.value + int(y), 0)
        self.flush()

    def button(self, down):
        self.xt.XTestFakeButtonEvent(self.display, 1, down, 0)
        self.flush()

    def close(self):
        self.x.XCloseDisplay(self.display)


def run():
    desktop = Desktop()
    process = None
    try:
        with tempfile.TemporaryDirectory(prefix="mermaid-ui-", dir="bin") as temp:
            path = Path(temp) / "diagram.mmd"
            original = b'%% keep this comment\nflowchart LR\nA[Alpha] --> B[Beta]\n'
            path.write_bytes(original)
            process = subprocess.Popen(["bin/wmermaid_editor", str(path)],
                                       stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            eventually(desktop.find_window, "editor window did not appear")
            desktop.focus()
            time.sleep(0.25)
            # Match the documented initial viewport and fit transform, deriving
            # diagram bounds from the real SVG backend rather than node guesses.
            svg = Path(temp) / "initial.svg"
            subprocess.run(["bin/wmermaid", "svg", str(path), str(svg)], check=True, timeout=20)
            root = ET.parse(svg).getroot()
            rect = root.find(".//{http://www.w3.org/2000/svg}rect")
            assert rect is not None
            _, _, width, height = map(float, root.get("viewBox").split())
            zoom = min(1.0, (815 - 24) / width, (596 - 24) / height)
            nx = 453 + (815 - width * zoom) / 2 + (float(rect.get("x")) + float(rect.get("width")) / 2) * zoom
            ny = 134 + (596 - height * zoom) / 2 + (float(rect.get("y")) + float(rect.get("height")) / 2) * zoom
            desktop.move(nx, ny)
            desktop.button(1)
            desktop.move(nx + 1, ny + 1)
            desktop.button(0)
            desktop.key("s", "Control_L")
            assert path.read_bytes() == original, "click jitter moved a node"
            desktop.move(nx, ny)
            desktop.button(1)
            for step in range(1, 6):
                desktop.move(nx + 14 * step, ny + 9 * step)
            desktop.button(0)
            desktop.key("s", "Control_L")
            eventually(lambda: path.read_bytes() != original, "mouse drag panned instead of moving node")
            assert b"@w-position" in path.read_bytes()
            desktop.key("z", "Control_L")
            desktop.key("s", "Control_L")
            eventually(lambda: path.read_bytes() == original, "drag was not one undo step")
            desktop.move(nx, ny)
            desktop.button(1)
            desktop.move(nx + 60, ny + 40)
            desktop.key("Escape")
            desktop.button(0)
            desktop.key("s", "Control_L")
            assert path.read_bytes() == original, "Escape committed an unfinished drag"
            # The inspector offers the same movement without dragging.
            desktop.move(65, 312)
            desktop.button(1)
            desktop.button(0)
            desktop.move(1000, 550)
            desktop.button(1)
            desktop.button(0)
            desktop.key("s", "Control_L")
            eventually(lambda: path.read_bytes() != original, "Move here did not place the node")
            assert b"@w-position" in path.read_bytes()
            desktop.key("z", "Control_L")
            desktop.key("s", "Control_L")
            eventually(lambda: path.read_bytes() == original, "placement undo changed source")
            # Connect through the canvas, then undo the newly added edge.
            other = root.findall(".//{http://www.w3.org/2000/svg}rect")[1]
            bx = 453 + (815 - width * zoom) / 2 + (float(other.get("x")) + float(other.get("width")) / 2) * zoom
            by = 134 + (596 - height * zoom) / 2 + (float(other.get("y")) + float(other.get("height")) / 2) * zoom
            desktop.move(155, 312)
            desktop.button(1)
            desktop.button(0)
            desktop.move(bx, by)
            desktop.button(1)
            desktop.button(0)
            desktop.key("s", "Control_L")
            eventually(lambda: path.read_bytes().count(b"-->") == 2, "Link to did not create an edge")
            desktop.key("z", "Control_L")
            desktop.key("s", "Control_L")
            eventually(lambda: path.read_bytes() == original, "connection undo changed source")
            desktop.key("d", "Control_L")
            # Escape retains selection; clicking empty canvas clears it before
            # testing keyboard navigation from an unselected state.
            desktop.move(1250, 700)
            desktop.button(1)
            desktop.button(0)
            desktop.key("Tab")
            desktop.key("Right")
            desktop.key("s", "Control_L")
            eventually(lambda: path.read_bytes() != original, "keyboard movement was not saved")
            moved = path.read_bytes()
            assert b"@w-position" in moved and b"%% keep this comment" in moved
            desktop.key("z", "Control_L")
            desktop.key("s", "Control_L")
            eventually(lambda: path.read_bytes() == original, "undo did not restore exact source")
            desktop.key("z", "Control_L", "Shift_L")
            desktop.key("s", "Control_L")
            eventually(lambda: path.read_bytes() == moved, "redo did not restore moved node")

            desktop.key("r", "Control_L")
            desktop.key("a", "Control_L")
            desktop.type_text("Renamed")
            desktop.key("Return", "Control_L")
            desktop.key("s", "Control_L")
            eventually(lambda: b'["Renamed"]' in path.read_bytes(), "inspector did not replace the entire label")
            renamed = path.read_bytes()
            assert b"%% keep this comment" in renamed and b"Beta" in renamed
            # Delete in the text field must not delete the selected graph node.
            desktop.key("r", "Control_L")
            desktop.key("a", "Control_L")
            desktop.key("Delete")
            desktop.key("s", "Control_L")
            assert path.read_bytes() == renamed, "text-field Delete removed a diagram object"
            desktop.key("d", "Control_L")
            desktop.key("Delete")
            desktop.key("s", "Control_L")
            eventually(lambda: b"Renamed" not in path.read_bytes(), "Delete did not remove selected node")
            assert b"Beta" in path.read_bytes()
            desktop.key("z", "Control_L")
            desktop.key("s", "Control_L")
            eventually(lambda: path.read_bytes() == renamed, "undo deletion lost document bytes")
            desktop.key("e", "Control_L")
            desktop.key("Home", "Control_L")
            desktop.type_text("%% typed\n")
            desktop.key("z", "Control_L")
            desktop.key("s", "Control_L")
            eventually(lambda: path.read_bytes() == renamed, "contiguous source typing was not one undo step")
            subprocess.run(["bin/wmermaid", "check", str(path)], check=True, timeout=20)
            desktop.key("q", "Control_L")
            out, err = process.communicate(timeout=5)
            assert process.returncode == 0, (out, err)
            process = None
            screenshot = Path("bin/mermaid-editor-workflow.ppm")
            subprocess.run(["bin/wmermaid_editor", str(path), "--frames", "3", "--screenshot", str(screenshot)],
                           check=True, timeout=20)
            assert screenshot.read_bytes().startswith(b"P6\n")
            assert path.read_bytes() == renamed, "reopening changed source bytes"
    finally:
        if process is not None:
            process.terminate()
            try:
                process.communicate(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.communicate()
        desktop.close()
    print("Mermaid native editor workflow passed")


if __name__ == "__main__":
    run()
