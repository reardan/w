#!/usr/bin/env python3
"""Qualify the #863 accessibility depth against real AT-SPI (libatspi).

Run by tools/mermaid_editor_atspi_test.sh with APP=bin/access_depth_app
(the access_atspi_depth_test target), which provides Xvfb, a private
session bus and at-spi-bus-launcher. This libatspi client launches the
fixture (tools/access_depth_app.w) and checks, through libatspi's own
API, glyph geometry (character and range extents, the offset at a
point), text attributes (default set and runs), multiple selections,
a multi-selection list, table row headers and spans, and that libatspi
moved its queries onto the application's peer-to-peer bus. Exits
non-zero on the first failed check.
"""
import subprocess
import sys
import threading
import time

import gi

gi.require_version("Atspi", "2.0")
from gi.repository import Atspi, GLib  # noqa: E402

EVENTS = []
OUTPUT = []


def note(event):
    EVENTS.append(event.type)


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
        print("app said: " + "".join(OUTPUT), file=sys.stderr)
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


def by_name_role(app, name, role):
    for node in walk(app):
        if node.get_name() == name and node.get_role() == role:
            return node
    return None


def requests():
    return [line for line in "".join(OUTPUT).splitlines() if line.startswith("request ")]


def read_output(stream):
    for line in iter(stream.readline, ""):
        OUTPUT.append(line)


def rect(r):
    return (r.x, r.y, r.width, r.height)


def main():
    app_path = sys.argv[1]
    Atspi.init()
    listener = Atspi.EventListener.new(note)
    for kind in ("object:text-selection-changed", "object:selection-changed", "object:state-changed:selected"):
        listener.register(kind)
    proc = subprocess.Popen([app_path], stdout=subprocess.PIPE, text=True)
    threading.Thread(target=read_output, args=(proc.stdout,), daemon=True).start()
    try:
        wait_for(lambda: find_app("W depth") is not None, "application on the desktop")
        app = find_app("W depth")
        editor = by_name_role(app, "Notes", Atspi.Role.ENTRY)
        require(editor is not None, "editor found")

        # Glyph geometry.
        require(rect(editor.get_character_extents(4, Atspi.CoordType.WINDOW)) == (24, 30, 12, 16),
                "character extents (window)")
        require(rect(editor.get_character_extents(0, Atspi.CoordType.SCREEN)) == (114, 212, 10, 16),
                "character extents (screen)")
        require(rect(editor.get_range_extents(1, 5, Atspi.CoordType.WINDOW)) == (14, 12, 22, 34),
                "range extents over two lines")
        require(editor.get_offset_at_point(125, 235, Atspi.CoordType.SCREEN) == 4, "offset at a point")
        require(editor.get_offset_at_point(90, 90, Atspi.CoordType.WINDOW) == -1, "no character there")

        # Text attributes.
        defaults = editor.get_default_attributes()
        require(defaults.get("family-name") == "Liberation Sans" and defaults.get("size") == "12"
                and defaults.get("weight") == "400", "default attributes")
        require(defaults.get("fg-color") == "4112,8224,12336", "foreground colour")
        run = Atspi.Text.get_attribute_run(editor, 4, False)
        require(run[0] == {"weight": "700"} and (run[1], run[2]) == (3, 5), "attribute run")
        run = Atspi.Text.get_attribute_run(editor, 1, True)
        require(run[0].get("weight") == "400" and run[0].get("style") == "normal"
                and (run[1], run[2]) == (0, 3), "run with defaults")
        require(Atspi.Text.get_text_attribute_value(editor, 4, "weight") == "700", "attribute value")

        # Multiple selections.
        require(Atspi.Text.get_n_selections(editor) == 2, "two selections")
        second = Atspi.Text.get_selection(editor, 1)
        require((second.start_offset, second.end_offset) == (3, 5), "second selection")
        require(Atspi.Text.add_selection(editor, 2, 3), "add a selection")
        wait_for(lambda: "request 2 64 0 1 3 5 2 3" in requests(), "SET_SELECTIONS reaches the application")
        wait_for(lambda: Atspi.Text.get_n_selections(editor) == 3, "three selections after the republish")
        require("object:text-selection-changed" in EVENTS, "text-selection-changed event")
        require(Atspi.Text.remove_selection(editor, 0), "remove the first selection")
        wait_for(lambda: Atspi.Text.get_n_selections(editor) == 2, "two selections again")

        # The multi-selection list.
        fruit = by_name_role(app, "Fruit", Atspi.Role.LIST)
        require(fruit.get_state_set().contains(Atspi.StateType.MULTISELECTABLE), "multiselectable state")
        require(Atspi.Selection.get_n_selected_children(fruit) == 1, "one selected")
        require(Atspi.Selection.select_child(fruit, 0), "select another child")
        wait_for(lambda: Atspi.Selection.get_n_selected_children(fruit) == 2, "two selected")
        require(Atspi.Selection.select_all(fruit), "select all")
        wait_for(lambda: Atspi.Selection.get_n_selected_children(fruit) == 3, "all selected")
        require(Atspi.Selection.deselect_child(fruit, 1), "deselect a child")
        wait_for(lambda: Atspi.Selection.get_n_selected_children(fruit) == 2, "deselected")
        require(Atspi.Selection.clear_selection(fruit), "clear the selection")
        wait_for(lambda: Atspi.Selection.get_n_selected_children(fruit) == 0, "none selected")
        require("object:selection-changed" in EVENTS, "selection-changed event")

        # The table: header row, row header over two rows, a cell over
        # two columns.
        table = next(node for node in walk(app) if node.get_role() == Atspi.Role.TABLE)
        require(table.get_n_rows() == 2 and table.get_n_columns() == 3, "table size")
        require(table.get_row_header(1).get_name() == "Fruit", "row header")
        require(table.get_column_header(2).get_name() == "Item", "spanning column header")
        require(table.get_row_extent_at(1, 0) == 2, "row extent")
        require(table.get_column_extent_at(1, 1) == 2, "column extent")
        cherry = table.get_accessible_at(1, 2)
        require(cherry.get_name() == "Cherry", "cell at a covered slot")
        span = cherry.get_row_column_span()
        require(tuple(span)[-4:] == (1, 1, 1, 2), "cell position and span: %r" % (tuple(span),))
        headers = cherry.get_row_header_cells()
        require([h.get_name() for h in headers] == ["Fruit"], "row header cells")
        require([h.get_name() for h in cherry.get_column_header_cells()] == ["Item"], "column header cells")
        fruit_cell = table.get_accessible_at(0, 0)
        require(fruit_cell.get_role() == Atspi.Role.TABLE_ROW_HEADER, "row header role")

        # The peer-to-peer bus: libatspi sends its queries straight to
        # the application once it has the address.
        Atspi.Accessible.clear_cache(app)
        for _ in range(3):
            editor.get_character_count()
            table.get_n_rows()
        wait_for(lambda: any(line.startswith("p2p ") and int(line.split()[1]) > 0
                             for line in "".join(OUTPUT).splitlines()),
                 "queries answered over the peer-to-peer bus")
    finally:
        proc.terminate()
        proc.wait(5)
    print("access depth AT-SPI qualification OK")


main()
