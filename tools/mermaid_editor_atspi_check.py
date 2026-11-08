#!/usr/bin/env python3
"""Qualify the Mermaid editor's canvas semantics against real AT-SPI.

Run by tools/mermaid_editor_atspi_test.sh, which provides Xvfb, a private
session bus and at-spi-bus-launcher (and optionally Orca). This script is a
libatspi client: it launches bin/wmermaid_editor, finds the diagram canvas
in the desktop tree, checks the nodes' and edges' roles, names,
descriptions, states and extents, drives focus/selection through the
accessibility API and the keyboard (XTest, via libatspi), and checks the
events a screen reader relies on. With --orca LOG it also checks what Orca
spoke (its --debug-file). Exits non-zero on the first failed check.
"""
import ctypes
import subprocess
import sys
import time

import gi

gi.require_version("Atspi", "2.0")
from gi.repository import Atspi, GLib  # noqa: E402

EVENTS = []
ANNOUNCEMENTS = []


def note(event):
    try:
        name = event.source.get_name()
    except GLib.Error:
        name = "?"
    EVENTS.append((event.type, name, event.detail1))
    if event.type.startswith("object:announcement") and isinstance(event.any_data, str):
        ANNOUNCEMENTS.append((event.any_data, event.detail1))


def pump(seconds):
    end = time.monotonic() + seconds
    context = GLib.MainContext.default()
    while time.monotonic() < end:
        while context.iteration(False):
            pass
        time.sleep(0.02)


def require(condition, message):
    if not condition:
        print("FAIL: " + message, file=sys.stderr)
        sys.exit(1)
    print("ok: " + message)


def wait_for(predicate, message, seconds=10.0):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        pump(0.1)
        try:
            if predicate():
                print("ok: " + message)
                return
        except GLib.Error:
            pass
    require(False, message)


def find_app(name):
    desktop = Atspi.get_desktop(0)
    for i in range(desktop.get_child_count()):
        app = desktop.get_child_at_index(i)
        if app is not None and app.get_name() == name:
            return app
    return None


def walk(node):
    yield node
    for i in range(node.get_child_count()):
        child = node.get_child_at_index(i)
        if child is not None:
            yield from walk(child)


def find_canvas(app):
    for node in walk(app):
        if node.get_role() == Atspi.Role.LIST and node.get_name().startswith("Diagram canvas"):
            return node
    return None


def children(node):
    node.clear_cache()
    return [node.get_child_at_index(i) for i in range(node.get_child_count())]


def names(node):
    return [child.get_name() for child in children(node)]


def states(node):
    node.clear_cache()
    return node.get_state_set()


def item(canvas, name):
    for child in children(canvas):
        if child.get_name() == name:
            return child
    return None


def has(canvas, name, state):
    child = item(canvas, name)
    return child is not None and states(child).contains(state)


XLIB = ctypes.CDLL("libX11.so.6")
XLIB.XOpenDisplay.restype = ctypes.c_void_p
XLIB.XKeysymToKeycode.argtypes = [ctypes.c_void_p, ctypes.c_ulong]
DISPLAY = XLIB.XOpenDisplay(None)


def keycode(keysym):
    return XLIB.XKeysymToKeycode(DISPLAY, keysym)


# Real key presses through XTest. Atspi.generate_keyboard_event drops some
# keys on hosts whose registryd cannot map the keycode (Tab never arrived on
# an Ubuntu 26.04 host), so synthesize them directly, as the XTest UI driver
# does; the check is about what AT-SPI reports, not how the key was sent.
XTST = ctypes.CDLL("libXtst.so.6")
XTST.XTestFakeKeyEvent.argtypes = [ctypes.c_void_p, ctypes.c_uint, ctypes.c_int, ctypes.c_ulong]
XLIB.XFlush.argtypes = [ctypes.c_void_p]


def key(keysym, ctrl=False, shift=False):
    held = [sym for sym, on in ((0xFFE3, ctrl), (0xFFE1, shift)) if on]
    for sym in held:
        XTST.XTestFakeKeyEvent(DISPLAY, keycode(sym), 1, 0)
    XTST.XTestFakeKeyEvent(DISPLAY, keycode(keysym), 1, 0)
    XTST.XTestFakeKeyEvent(DISPLAY, keycode(keysym), 0, 0)
    for sym in reversed(held):
        XTST.XTestFakeKeyEvent(DISPLAY, keycode(sym), 0, 0)
    XLIB.XFlush(DISPLAY)
    pump(0.4)


class Speech:
    """New SPEECH OUTPUT lines in Orca's debug log, since the last check."""

    def __init__(self, path):
        self.path = path
        self.offset = 0
        self.heard = []

    def expect(self, phrase, seconds=20.0):
        if self.path is None:
            return
        end = time.monotonic() + seconds
        while time.monotonic() < end:
            pump(0.2)
            with open(self.path, "rb") as log:
                log.seek(self.offset)
                chunk = log.read()
            lines = chunk.splitlines(True)
            if lines and not lines[-1].endswith(b"\n"):
                lines.pop()
            for raw in lines:
                self.offset += len(raw)
                line = raw.decode("utf-8", "replace")
                if "SPEECH OUTPUT: '" in line:
                    spoken = line.split("SPEECH OUTPUT: '", 1)[1].split("'", 1)[0]
                    self.heard.append(spoken)
                    if phrase in spoken:
                        print("ok: Orca spoke %r" % spoken)
                        return
        require(False, "Orca spoke %r (heard %r)" % (phrase, self.heard[-8:]))


def focus_events(name):
    return [e for e in EVENTS if e[0] == "object:state-changed:focused" and e[1] == name and e[2] == 1]


def main():
    editor, path = sys.argv[1], sys.argv[2]
    orca_log = None
    if len(sys.argv) > 4 and sys.argv[3] == "--orca":
        orca_log = sys.argv[4]
    with open(path, "w") as out:
        out.write("%% atspi qualification\nflowchart LR\nA[Alpha] -->|pays| B[Beta]\nB --> C[Gamma]\n")
    listener = Atspi.EventListener.new(note)
    for kind in ("object:state-changed:focused", "object:state-changed:selected", "object:selection-changed", "object:children-changed", "object:property-change:accessible-name", "object:announcement"):
        listener.register(kind)
    process = subprocess.Popen([editor, path])
    try:
        app = None
        end = time.monotonic() + 20.0
        while app is None and time.monotonic() < end:
            pump(0.2)
            app = find_app("W Mermaid")
        require(app is not None, "editor registered on the AT-SPI desktop")
        frame = app.get_child_at_index(0)
        wait_for(lambda: frame.get_role() == Atspi.Role.FRAME and frame.get_name().startswith("W Mermaid: "), "window frame named after the file")
        canvas = None
        end = time.monotonic() + 10.0
        while canvas is None and time.monotonic() < end:
            pump(0.2)
            canvas = find_canvas(app)
        require(canvas is not None, "diagram canvas is a list in the tree")
        description = canvas.get_description()
        require("flowchart, 3 nodes, 2 edges" in description, "canvas summary: " + description)
        expected = ["Alpha", "Beta", "Gamma", "Alpha to Beta: pays", "Beta to Gamma"]
        require(names(canvas) == expected, "nodes and edges are canvas children in order: %r" % names(canvas))
        for child in children(canvas):
            require(child.get_role() == Atspi.Role.LIST_ITEM, child.get_name() + " is a list item")
            require(states(child).contains(Atspi.StateType.FOCUSABLE), child.get_name() + " is focusable")
            require(states(child).contains(Atspi.StateType.SELECTABLE), child.get_name() + " is selectable")
        require(item(canvas, "Beta").get_description() == "node B, 1 outgoing, 1 incoming, movable", "node description")
        require(item(canvas, "Alpha to Beta: pays").get_description() == "edge from Alpha to Beta, label pays", "edge description")
        window = frame.get_extents(Atspi.CoordType.SCREEN)
        box = item(canvas, "Beta").get_extents(Atspi.CoordType.SCREEN)
        area = canvas.get_extents(Atspi.CoordType.SCREEN)
        require(box.width > 10 and box.height > 10, "node has extents %dx%d" % (box.width, box.height))
        require(area.x <= box.x and box.x + box.width <= area.x + area.width, "node lies inside the canvas horizontally")
        require(area.y <= box.y and box.y + box.height <= area.y + area.height, "node lies inside the canvas vertically")
        require(window.width >= area.width, "canvas inside the window")
        hit = canvas.get_accessible_at_point(box.x + box.width // 2, box.y + box.height // 2, Atspi.CoordType.SCREEN)
        require(hit is not None and hit.get_name() == "Beta", "hit testing at the node's center finds it")

        speech = Speech(orca_log)
        speech.expect("W Mermaid: ")
        # Assistive focus (Orca's focus tracking, GrabFocus) selects the node.
        item(canvas, "Beta").grab_focus()
        wait_for(lambda: has(canvas, "Beta", Atspi.StateType.FOCUSED) and has(canvas, "Beta", Atspi.StateType.SELECTED), "GrabFocus focuses and selects Beta")
        wait_for(lambda: focus_events("Beta"), "focus event for Beta")
        speech.expect("Beta")

        # Selection interface (SelectChild) selects an edge.
        selection = canvas.get_selection_iface()
        require(selection is not None, "canvas implements Selection")
        selection.select_child(3)
        wait_for(lambda: has(canvas, "Alpha to Beta: pays", Atspi.StateType.SELECTED), "SelectChild selects the edge")
        wait_for(lambda: focus_events("Alpha to Beta: pays"), "focus event for the selected edge")
        speech.expect("Alpha to Beta: pays")
        wait_for(lambda: not has(canvas, "Beta", Atspi.StateType.SELECTED), "previous selection cleared")

        # Keyboard only: Tab cycles nodes while the canvas has focus, and each
        # step moves the published focus (what Orca announces).
        # The status line is a polite live region: edit results are
        # announced (Object:Announcement) wherever focus is.
        status = None
        for node in walk(app):
            if node.get_role() == Atspi.Role.LABEL and node.get_name() and node.get_attributes().get("live") == "polite":
                status = node
        require(status is not None, "status line is a polite live region (live attribute)")
        save = None
        for node in walk(app):
            if node.get_role() == Atspi.Role.PUSH_BUTTON and node.get_name() == "Save":
                save = node
        require(save is not None, "Save button in the tree")
        save.get_action_iface().do_action(0)
        wait_for(lambda: ("Saved.", 1) in ANNOUNCEMENTS, "saving announces 'Saved.' politely")
        speech.expect("Saved.")
        with open(path, "a") as out:
            out.write("C --> D[Delta]\n")
        wait_for(lambda: any("changed on disk" in text for text, _ in ANNOUNCEMENTS), "an external change is announced", 15.0)
        speech.expect("changed on disk")

        key(0xFF09)
        wait_for(lambda: has(canvas, "Alpha", Atspi.StateType.FOCUSED), "Tab moves focus to Alpha")
        wait_for(lambda: focus_events("Alpha"), "focus event for Alpha after Tab")
        speech.expect("Alpha")
        key(0xFF09)
        wait_for(lambda: has(canvas, "Beta", Atspi.StateType.FOCUSED), "second Tab moves focus to Beta")
        speech.expect("Beta")
        key(0xFF09, shift=True)
        wait_for(lambda: has(canvas, "Alpha", Atspi.StateType.FOCUSED), "Shift+Tab moves focus back to Alpha")
        speech.expect("Alpha")
        key(0xFF09)
        wait_for(lambda: has(canvas, "Beta", Atspi.StateType.FOCUSED), "Tab returns to Beta")
        key(0xFFFF)
        wait_for(lambda: names(canvas) == ["Alpha", "Gamma"], "Delete removes Beta and its edges: %r" % names(canvas))
        require([e for e in EVENTS if e[0].startswith("object:children-changed")], "children-changed events on deletion")
        key(ord("z"), ctrl=True)
        wait_for(lambda: names(canvas) == expected, "Ctrl+Z restores the nodes and edges")
        key(ord("d"), ctrl=True)
        key(0xFF09)
        wait_for(lambda: has(canvas, "Alpha", Atspi.StateType.FOCUSED), "Ctrl+D then Tab focuses a node again")

        # The node list (#913): a multi-selection list box mirroring the
        # canvas selection, driven from the keyboard and through the
        # Selection interface.
        nodes = None
        for node in walk(app):
            if node.get_role() == Atspi.Role.LIST and node.get_name() == "Nodes":
                nodes = node
        require(nodes is not None, "node list in the tree")
        require(states(nodes).contains(Atspi.StateType.MULTISELECTABLE), "node list is multiselectable")
        require(names(nodes) == ["Alpha", "Beta", "Gamma"], "node list items: %r" % names(nodes))
        require(has(nodes, "Alpha", Atspi.StateType.SELECTED), "the canvas selection shows in the list")
        nodes.grab_focus()
        wait_for(lambda: has(nodes, "Alpha", Atspi.StateType.FOCUSED), "GrabFocus on the list focuses its cursor item")
        key(0xFF54, shift=True)
        wait_for(lambda: has(canvas, "Alpha", Atspi.StateType.SELECTED) and has(canvas, "Beta", Atspi.StateType.SELECTED), "Shift+Down selects Alpha and Beta on the canvas")
        wait_for(lambda: has(nodes, "Beta", Atspi.StateType.FOCUSED), "the list's focus follows its cursor")
        key(ord("a"), ctrl=True)
        wait_for(lambda: all(has(canvas, n, Atspi.StateType.SELECTED) for n in ("Alpha", "Beta", "Gamma")), "Ctrl+A in the list selects every node")
        selection = nodes.get_selection_iface()
        require(selection.get_n_selected_children() == 3, "three selected children")
        require(selection.deselect_child(1), "DeselectChild")
        wait_for(lambda: not has(canvas, "Beta", Atspi.StateType.SELECTED) and has(canvas, "Gamma", Atspi.StateType.SELECTED), "DeselectChild deselects Beta on the canvas")
        require(selection.clear_selection(), "ClearSelection")
        wait_for(lambda: not any(has(canvas, n, Atspi.StateType.SELECTED) for n in ("Alpha", "Beta", "Gamma")), "ClearSelection empties the canvas selection")
        require(selection.select_child(2), "SelectChild")
        wait_for(lambda: has(canvas, "Gamma", Atspi.StateType.SELECTED) and selection.get_n_selected_children() == 1, "SelectChild selects Gamma")

        if orca_log is not None:
            print("Orca speech, in order: %r" % speech.heard)
    finally:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
    check_compartments(editor, path)
    print("Mermaid editor AT-SPI qualification passed")


def check_compartments(editor, path):
    """The compartment grid (#913): an ER entity's attributes as a table
    with a header row and the attribute names as row headers; picking a
    row picks the line the inspector edits."""
    with open(path, "w") as out:
        out.write("erDiagram\nCUSTOMER {\n  string name PK \"full name\"\n  int age\n}\nCUSTOMER ||--o{ ORDER : places\n")
    process = subprocess.Popen([editor, path])
    try:
        app = None
        end = time.monotonic() + 20.0
        while app is None and time.monotonic() < end:
            pump(0.2)
            app = find_app("W Mermaid")
        require(app is not None, "ER editor registered")
        canvas = None
        end = time.monotonic() + 10.0
        while canvas is None and time.monotonic() < end:
            pump(0.2)
            canvas = find_canvas(app)
        require(canvas is not None, "ER canvas")
        wait_for(lambda: item(canvas, "CUSTOMER") is not None, "entity on the canvas")
        item(canvas, "CUSTOMER").grab_focus()
        wait_for(lambda: has(canvas, "CUSTOMER", Atspi.StateType.SELECTED), "entity selected")

        def grid():
            for node in walk(app):
                if node.get_role() == Atspi.Role.TABLE:
                    return node
            return None
        wait_for(lambda: grid() is not None, "compartment grid in the tree")
        table = grid()
        require(table.get_n_rows() == 2 and table.get_n_columns() == 4, "two attributes by four columns")
        require([table.get_column_header(c).get_name() for c in range(4)] == ["Name", "Type", "Keys", "Comment"], "column headers")
        require(table.get_row_header(0).get_name() == "name" and table.get_row_header(1).get_name() == "age", "attribute names head their rows")
        require(table.get_accessible_at(0, 0).get_role() == Atspi.Role.TABLE_ROW_HEADER, "row header role")
        require(table.get_accessible_at(0, 2).get_name() == "PK" and table.get_accessible_at(0, 3).get_name() == "full name", "keys and comment cells")
        require(table.get_accessible_at(1, 1).get_name() == "int", "type cell")

        def picked_line():
            for node in walk(app):
                if node.get_name() in ("1/2", "2/2"):
                    return node.get_name()
            return None
        require(picked_line() == "1/2", "first line picked")
        # Selection counts the table's children: the header row is child 0.
        rows = table.get_selection_iface()
        require(rows.is_child_selected(1) and not rows.is_child_selected(2), "the first row is selected")
        require(rows.select_child(2), "SelectChild on the second row")
        wait_for(lambda: picked_line() == "2/2", "the inspector edits the second line")
    finally:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()


if __name__ == "__main__":
    main()
