#!/usr/bin/env python3
"""Qualify the #863 accessibility depth against real AT-SPI (libatspi).

Run by tools/mermaid_editor_atspi_test.sh with APP=bin/access_depth_app
(the access_atspi_depth_test target), which provides Xvfb, a private
session bus and at-spi-bus-launcher. This libatspi client launches the
fixture (tools/access_depth_app.w) and checks, through libatspi's own
API, glyph geometry (character and range extents, the offset at a
point), text attributes (default set and runs), multiple selections,
a multi-selection list, table row headers and spans, relations and a
slider's value (#911), bounded ranges and scroll-substring-to on a
scrolled log (#912), and that libatspi moved its queries onto the
application's peer-to-peer bus. Exits
non-zero on the first failed check.
"""
import subprocess
import sys
import threading
import time

import gi

gi.require_version("Atspi", "2.0")
from gi.repository import Atspi, Gio, GLib  # noqa: E402

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


A11Y_BUS = []


def bounded_ranges(node, x, y, width, height, coord, xclip, yclip):
    """Text.GetBoundedRanges on node over the accessibility bus, as
    (start, end, text) tuples."""
    if not A11Y_BUS:
        session = Gio.bus_get_sync(Gio.BusType.SESSION, None)
        reply = session.call_sync("org.a11y.Bus", "/org/a11y/bus", "org.a11y.Bus", "GetAddress",
                                  None, GLib.VariantType("(s)"), Gio.DBusCallFlags.NONE, 2000, None)
        flags = Gio.DBusConnectionFlags.AUTHENTICATION_CLIENT | Gio.DBusConnectionFlags.MESSAGE_BUS_CONNECTION
        A11Y_BUS.append(Gio.DBusConnection.new_for_address_sync(reply.unpack()[0], flags, None, None))
    reply = A11Y_BUS[0].call_sync(node.app.bus_name, node.path, "org.a11y.atspi.Text", "GetBoundedRanges",
                                  GLib.Variant("(iiiiuuu)", (x, y, width, height, coord, xclip, yclip)),
                                  GLib.VariantType("(a(iisv))"), Gio.DBusCallFlags.NONE, 2000, None)
    return [(start, end, text) for start, end, text, _ in reply.unpack()[0]]


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

        # Relations and the slider's value (#911).
        slider = next(node for node in walk(app) if node.get_role() == Atspi.Role.SLIDER)
        relations = slider.get_relation_set()
        require([r.get_relation_type() for r in relations] == [Atspi.RelationType.LABELLED_BY], "labelled-by relation")
        label = relations[0].get_target(0)
        require(label.get_name() == "Volume" and label.get_role() == Atspi.Role.LABEL, "relation target")
        require([r.get_relation_type() for r in label.get_relation_set()] == [Atspi.RelationType.LABEL_FOR],
                "the reverse label-for relation")
        require(label.get_relation_set()[0].get_target(0).get_role() == Atspi.Role.SLIDER, "label-for target")
        require(slider.get_current_value() == 4.0 and slider.get_maximum_value() == 10.0
                and slider.get_minimum_value() == 0.0 and slider.get_minimum_increment() == 0.5, "slider range")
        require(slider.set_current_value(7.5), "set the slider")
        wait_for(lambda: "request 41 4 7.5" in requests(), "SET_VALUE reaches the application")
        wait_for(lambda: slider.get_current_value() == 7.5, "new value after the republish")

        # Scroll-aware text geometry (#912): the log shows two of its
        # four lines; scrolling a substring moves which ones.
        log = by_name_role(app, "Log", Atspi.Role.ENTRY)
        none = Atspi.TextClipType.NONE

        def shown(y=220, clip=none):
            # libatspi 2.52 hands back a GArray of AtspiTextRange
            # pointers that its introspection data declares as structs,
            # so Atspi.Text.get_bounded_ranges crashes Python: the same
            # call goes over the accessibility bus instead.
            return bounded_ranges(log, 10, y, 100, 40, int(Atspi.CoordType.WINDOW), int(clip), int(clip))

        require(shown() == [(3, 9, "cd\nef\n")], "bounded ranges: the visible lines %r" % (shown(),))
        both = Atspi.TextClipType.BOTH
        require([r[:2] for r in shown(225, both)] == [(6, 9)], "clipped bounded ranges")
        require(Atspi.Text.scroll_substring_to(log, 9, 11, Atspi.ScrollType.BOTTOM_EDGE), "scroll a substring")
        wait_for(lambda: "request 42 128 9 11 1" in requests(), "SCROLL_TO reaches the application")
        wait_for(lambda: shown() == [(6, 11, "ef\ngh")], "last lines visible after scrolling")
        require(Atspi.Text.scroll_substring_to(log, 0, 1, Atspi.ScrollType.TOP_EDGE), "scroll to the top")
        wait_for(lambda: shown() == [(0, 6, "ab\ncd\n")], "first lines visible after scrolling")

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
