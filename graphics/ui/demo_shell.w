/*
graphics.ui.demo_shell: the editor shell — round 2's six widgets
assembled into the layout they exist for
(docs/projects/ui_widgets.md §9). Driven by graphics/ui/demo.w --shell
in a 900x600 window:

	./bin/wv2 x64 graphics/ui/demo.w -o bin/demo
	./bin/demo --shell

	+----------------+--------------------------------------+
	| src/       [v] | main.w | tree.w | tabs.w |          x |  <- ui_tabs
	|   main.w       +--------------------------------------+
	|   tree.w       |                                      |
	|   tabs.w       |  ui_textarea over the open document   |
	| docs/      [>] |                                      |
	+----------------+--------------------------------------+
	         ^ ui_tree over a static file list
	         ^ the seam between them is a ui_split

Right-clicking the sidebar opens a ui_menu; choosing an item fires a
ui_toast. Clicking a file in the tree opens it as a tab; clicking a tab
switches the editor to it; the cross closes it.

This is a NEW demo rather than an extension of graphics/ui/demo_shared.w
on purpose: that form is a 320x680 column whose row coordinates are
load-bearing for graphics/ui/smoke_test.w's pixel probes and
tools/web/run_ui_stub.mjs's scripted clicks. An editor shell wants a
wide window, which that column cannot become without moving everything.

The document set is static and caller-owned, and the tree takes plain
labels: there is no filesystem here. A readdir-backed explorer belongs
to the editor project, not to the widget layer — getdents is Linux-only
in this tree, so a real file tree inside graphics/ui/ would not run
under the wasm gate.
*/
import lib.lib
import graphics.ui.rect
import graphics.ui.theme
import graphics.ui.font
import graphics.ui.render
import graphics.ui.text
import graphics.ui.widgets


# How many documents the shell knows about. Two folders' worth, with the
# second folder's files sharing the same tab strip.
int ui_shell_doc_count():
	return 5


int ui_shell_folder_count():
	return 2


char* ui_shell_folder_name(int folder):
	if (folder == 0):
		return c"src"
	return c"docs"


# Files per folder: src has three, docs has two, and their document ids
# run 0..4 in that order.
int ui_shell_folder_files(int folder):
	if (folder == 0):
		return 3
	return 2


int ui_shell_doc_id(int folder, int index):
	if (folder == 0):
		return index
	return 3 + index


char* ui_shell_doc_name(int doc):
	if (doc == 0):
		return c"tree.w"
	if (doc == 1):
		return c"tabs.w"
	if (doc == 2):
		return c"toast.w"
	if (doc == 3):
		return c"ui_widgets.md"
	return c"README.md"


# Placeholder contents, so the editor pane shows something per document
# and switching tabs visibly changes it.
char* ui_shell_doc_body(int doc):
	if (doc == 0):
		return c"# tree.w\n\nThe caller's recursion is the tree walk.\nA collapsed subtree costs nothing because\nthe caller simply does not recurse into it.\n\nLeft collapses, then ascends to the parent.\nRight expands, then descends to the first child."
	if (doc == 1):
		return c"# tabs.w\n\nThe close affordance is hit-tested before\nthe tab and consumes the click, so closing a\nbackground tab never first drags it into focus."
	if (doc == 2):
		return c"# toast.w\n\nThe widget holds no clock: the time comes in\nas an argument. UI code should not read clocks.\n\nDraws on UI_LAYER_TOP, takes no input."
	if (doc == 3):
		return c"# Widget expansion\n\nRound 1: clipping, layers, regions, scroll,\na text buffer, and Modal/Table/Textarea.\n\nRound 2: the editor shell."
	return c"# W\n\nA small, self-hosting compiled language.\nC-like semantics, Python-like syntax.\n\nThe compiler is written in W."


struct ui_shell_state:
	ui_split_state split
	ui_tree_state tree
	ui_tab_state tabs
	ui_menu_state menu
	ui_toast_state toast
	ui_textarea_state editor
	int32[2] folder_open
	# Which documents are open as tabs, in strip order, and which of
	# them the editor is showing.
	int32[5] open_docs
	int32 open_count
	int32 active_tab
	# The document the editor's buffer currently holds, so switching
	# tabs only reloads when it has to.
	int32 loaded_doc
	ui_theme theme


void ui_shell_init(ui_shell_state* st):
	ui_split_init(&st.split, 200.0)
	st.split.min_a = 120.0
	st.split.min_b = 240.0
	ui_tree_init(&st.tree)
	ui_tab_init(&st.tabs)
	ui_menu_init(&st.menu, 150.0)
	ui_toast_init(&st.toast)
	ui_textarea_init(&st.editor)
	st.folder_open[0] = 1
	st.folder_open[1] = 0
	int i = 0
	while (i < ui_shell_doc_count()):
		st.open_docs[i] = 0
		i = i + 1
	st.open_count = 0
	st.active_tab = 0
	st.loaded_doc = 0 - 1
	ui_theme_dark(&st.theme)


# Open a document as a tab, or switch to it if it is already open.
void ui_shell_open_doc(ui_shell_state* st, int doc):
	int i = 0
	while (i < st.open_count):
		if (st.open_docs[i] == doc):
			st.active_tab = i
			return
		i = i + 1
	if (st.open_count >= ui_shell_doc_count()):
		return
	st.open_docs[st.open_count] = doc
	st.active_tab = st.open_count
	st.open_count = st.open_count + 1


void ui_shell_close_tab(ui_shell_state* st, int index):
	if ((index < 0) || (index >= st.open_count)):
		return
	int i = index
	while (i + 1 < st.open_count):
		st.open_docs[i] = st.open_docs[i + 1]
		i = i + 1
	st.open_count = st.open_count - 1
	if (st.active_tab >= st.open_count):
		st.active_tab = st.open_count - 1
	if (st.active_tab < 0):
		st.active_tab = 0
	# The editor is showing a document that may no longer be the active
	# one; force a reload on the next frame.
	st.loaded_doc = 0 - 1


# Open the context menu at a point without a right-click, so a
# screenshot of it is reproducible from the CLI rather than by clicking
# before capturing. The menu is otherwise entirely right-click driven.
void ui_shell_pin_menu(ui_shell_state* st, float32 x, float32 y):
	st.menu.open = 1
	st.menu.at_x = x
	st.menu.at_y = y


# One frame of the shell. Call between ui_begin_window and ui_end.
# now_ms drives the toast, and is the caller's to supply — the widget
# layer reads no clocks (docs/projects/ui_widgets.md §9.3).
void ui_shell_body(ui_context* ctx, ui_shell_state* st, int now_ms):
	float32 vw = cast(float32, ctx.rndr.vp_w)
	float32 vh = cast(float32, ctx.rndr.vp_h)
	ui_rect sidebar
	ui_rect pane
	ui_split(ctx, ui_rect_new(0.0, 0.0, vw, vh), 1, &st.split, &sidebar, &pane)

	# ---- sidebar: the file tree ----------------------------------------
	ui_render_rect(ctx.rndr, sidebar, ctx.theme.background)
	ui_tree_begin(ctx, sidebar, &st.tree)
	int folder = 0
	while (folder < ui_shell_folder_count()):
		if (ui_tree_node(ctx, &st.tree, ui_shell_folder_name(folder), &st.folder_open[folder])):
			int f = 0
			while (f < ui_shell_folder_files(folder)):
				int doc = ui_shell_doc_id(folder, f)
				if (ui_tree_leaf(ctx, &st.tree, ui_shell_doc_name(doc))):
					ui_shell_open_doc(st, doc)
				f = f + 1
			ui_tree_node_end(ctx, &st.tree)
		folder = folder + 1
	ui_tree_end(ctx, &st.tree)

	# ---- editor pane: tabs over a text surface -------------------------
	float32 strip_h = 28.0
	ui_rect strip = ui_rect_new(pane.x, pane.y, pane.w, strip_h)
	ui_tabs_begin(ctx, strip, &st.tabs, &st.active_tab)
	int t = 0
	while (t < st.open_count):
		ui_tab(ctx, &st.tabs, ui_shell_doc_name(st.open_docs[t]), 1)
		t = t + 1
	int closed = ui_tabs_end(ctx, &st.tabs)
	if (closed >= 0):
		ui_shell_close_tab(st, closed)

	if (st.open_count > 0):
		int doc = st.open_docs[st.active_tab]
		if (st.loaded_doc != doc):
			ui_textarea_set(&st.editor, ui_shell_doc_body(doc))
			st.loaded_doc = doc
		ui_textarea(ctx, ui_rect_new(pane.x, pane.y + strip_h, pane.w, pane.h - strip_h), &st.editor)
	else:
		# Nothing open: say so rather than showing an empty field that
		# looks broken.
		ui_draw_text_centered(ctx.rndr, ui_rect_new(pane.x, pane.y + strip_h, pane.w, pane.h - strip_h), c"Pick a file in the sidebar", ctx.theme.text_scale, ctx.theme.text_muted)

	# ---- the overlays ---------------------------------------------------
	# Right-clicking the sidebar opens the context menu at the pointer.
	ui_menu_open_on_right_click(ctx, sidebar, &st.menu)
	if (ui_menu_begin(ctx, &st.menu)):
		if (ui_menu_item(ctx, &st.menu, c"Open", st.tree.selected >= 0)):
			ui_toast_show(&st.toast, c"Open is a demo action", now_ms, 2000)
		if (ui_menu_item(ctx, &st.menu, c"Collapse All", 1)):
			st.folder_open[0] = 0
			st.folder_open[1] = 0
			ui_toast_show(&st.toast, c"Collapsed every folder", now_ms, 2000)
		ui_menu_separator(ctx, &st.menu)
		if (ui_menu_item(ctx, &st.menu, c"Close All Tabs", st.open_count > 0)):
			st.open_count = 0
			st.active_tab = 0
			st.loaded_doc = 0 - 1
			ui_toast_show(&st.toast, c"Closed every tab", now_ms, 2000)
		ui_menu_end(ctx, &st.menu)

	ui_toast(ctx, &st.toast, now_ms)
