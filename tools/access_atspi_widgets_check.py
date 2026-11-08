#!/usr/bin/env python3
"""Qualify the #913 widgets against real AT-SPI (libatspi).

Run by tools/mermaid_editor_atspi_test.sh with APP=bin/access_widgets_app
(the access_atspi_widgets_test target), which provides Xvfb, a private
session bus and at-spi-bus-launcher. This libatspi client launches the
fixture (tools/access_widgets_app.w), whose snapshot the widgets
themselves publish, and checks through libatspi's own API: the list
box's multiselectable state and selected children, and select_child,
select_all, deselect_child and clear_selection reaching the widget's
flags; the grid table's size, header row, row headers, spans and the
cell at a covered slot. Exits non-zero on the first failed check.
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


def picked():
    lines = [line for line in "".join(OUTPUT).splitlines() if line.startswith("picked ")]
    return lines[-1].split()[1] if lines else None


def read_output(stream):
    for line in iter(stream.readline, ""):
        OUTPUT.append(line)


def main():
    app_path = sys.argv[1]
    Atspi.init()
    listener = Atspi.EventListener.new(note)
    for kind in ("object:selection-changed", "object:state-changed:selected"):
        listener.register(kind)
    proc = subprocess.Popen([app_path], stdout=subprocess.PIPE, text=True)
    threading.Thread(target=read_output, args=(proc.stdout,), daemon=True).start()
    try:
        wait_for(lambda: find_app("W widgets") is not None, "application on the desktop")
        app = find_app("W widgets")

        # The list box (graphics.ui.widgets.listbox).
        fruit = by_name_role(app, "Fruit", Atspi.Role.LIST)
        require(fruit is not None, "list box found")
        states = fruit.get_state_set()
        require(states.contains(Atspi.StateType.MULTISELECTABLE), "multiselectable state")
        require(states.contains(Atspi.StateType.FOCUSABLE), "focusable list")
        require(fruit.get_child_count() == 4, "four items")
        require(fruit.get_child_at_index(0).get_role() == Atspi.Role.LIST_ITEM, "list item role")
        require(Atspi.Selection.get_n_selected_children(fruit) == 1, "one selected")
        require(Atspi.Selection.get_selected_child(fruit, 0).get_name() == "Cherry", "Cherry selected")
        require(Atspi.Selection.select_child(fruit, 2), "select another child")
        wait_for(lambda: Atspi.Selection.get_n_selected_children(fruit) == 2, "two selected")
        require(picked() == "0110", "the widget's flags follow")
        require(Atspi.Selection.is_child_selected(fruit, 2), "Kiwi selected")
        require(Atspi.Selection.select_all(fruit), "select all")
        wait_for(lambda: Atspi.Selection.get_n_selected_children(fruit) == 4, "all selected")
        require(picked() == "1111", "all flags set")
        require(Atspi.Selection.deselect_child(fruit, 1), "deselect a child")
        wait_for(lambda: Atspi.Selection.get_n_selected_children(fruit) == 3, "deselected")
        require(picked() == "1011", "one flag cleared")
        require(Atspi.Selection.clear_selection(fruit), "clear the selection")
        wait_for(lambda: Atspi.Selection.get_n_selected_children(fruit) == 0, "none selected")
        require(picked() == "0000", "no flags")
        require("object:selection-changed" in EVENTS, "selection-changed event")

        # The grid table (graphics.ui.widgets.table): a header spanning
        # two columns, a row header over two rows, a cell over two
        # columns, and a plain row whose first cell heads it.
        table = next(node for node in walk(app) if node.get_role() == Atspi.Role.TABLE)
        require(table.get_n_rows() == 3 and table.get_n_columns() == 3, "table size")
        require(table.get_column_header(1).get_name() == "Item", "column header")
        require(table.get_column_header(2).get_name() == "Item", "spanning column header")
        require(table.get_row_header(0).get_name() == "Fruit", "row header")
        require(table.get_row_header(1).get_name() == "Fruit", "row header spanning down")
        require(table.get_row_header(2).get_name() == "Nut", "third row's header")
        require(table.get_row_extent_at(0, 0) == 2, "row extent")
        require(table.get_column_extent_at(1, 1) == 2, "column extent")
        cherry = table.get_accessible_at(1, 2)
        require(cherry.get_name() == "Cherry", "cell at a covered slot")
        span = cherry.get_row_column_span()
        require(tuple(span)[-4:] == (1, 1, 1, 2), "cell position and span: %r" % (tuple(span),))
        require([h.get_name() for h in cherry.get_row_header_cells()] == ["Fruit"], "row header cells")
        require([h.get_name() for h in cherry.get_column_header_cells()] == ["Item"], "column header cells")
        require(table.get_accessible_at(0, 0).get_role() == Atspi.Role.TABLE_ROW_HEADER, "row header role")
        require(table.get_accessible_at(0, 1).get_role() == Atspi.Role.TABLE_CELL, "data cell role")
        require(table.get_accessible_at(2, 2).get_name() == "Brown", "plain row cell")
    finally:
        proc.terminate()
        proc.wait(5)
    print("widgets AT-SPI qualification OK")


main()
