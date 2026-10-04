/*
graphics.ui.demo_shell: the editor shell — round 2's six widgets
assembled into the layout they exist for
(docs/projects/ui_widgets.md §9). Driven by graphics/ui/demo.w --shell
in a 900x600 window:

	./bin/wv2 x64 graphics/ui/demo.w -o bin/demo
	./bin/demo --shell

	| File  Edit  View  Help                                 |  <- ui_menubar
	+----------------+--------------------------------------+
	| src/       [v] | main.w | tree.w | tabs.w |          x |  <- ui_tabs
	|   main.w       +--------------------------------------+
	|   tree.w       |                                      |
	|   tabs.w       |  ui_textarea over the open document   |
	| docs/      [>] |                                      |
	+----------------+--------------------------------------+
	         ^ ui_tree over a static file list
	         ^ the seam between them is a ui_split

The menu bar's File, Edit, View and Help menus show off the menu
kit: shortcuts that work with the menu closed (Ctrl+N, Ctrl+W), an
Open Recent submenu, a Sidebar check item, and a Theme submenu of radio
items that restyles the whole shell. Right-clicking the sidebar opens a
ui_menu; choosing an item fires a ui_toast. Clicking a file in the tree opens it as a tab; clicking a tab
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
import graphics.event
import lib.mem


# How many documents the shell knows about. Two folders' worth, with the
# second folder's files sharing the same tab strip.
const int ui_shell_doc_count = 5
const int ui_shell_folder_count = 2


char* ui_shell_folder_name(int folder):
	if (folder == 0): return c"src"
	return c"docs"


# Files per folder: src has three, docs has two, and their document ids
# run 0..4 in that order.
int ui_shell_folder_files(int folder):
	if (folder == 0): return 3
	return 2


int ui_shell_doc_id(int folder, int index):
	if (folder == 0):
		return index
	return 3 + index


char* ui_shell_doc_name(int doc):
	switch (doc):
		case 0: return c"tree.w"
		case 1: return c"tabs.w"
		case 2: return c"toast.w"
		case 3: return c"ui_widgets.md"
		default: return c"README.md"


# Placeholder contents, so the editor pane shows something per document
# and switching tabs visibly changes it.
char* ui_shell_doc_body(int doc):
	switch (doc):
		case 0: return c"# tree.w\n\nThe caller's recursion is the tree walk.\nA collapsed subtree costs nothing because\nthe caller simply does not recurse into it.\n\nLeft collapses, then ascends to the parent.\nRight expands, then descends to the first child."
		case 1: return c"# tabs.w\n\nThe close affordance is hit-tested before\nthe tab and consumes the click, so closing a\nbackground tab never first drags it into focus."
		case 2: return c"# toast.w\n\nThe widget holds no clock: the time comes in\nas an argument. UI code should not read clocks.\n\nDraws on UI_LAYER_TOP, takes no input."
		case 3: return c"# Widget expansion\n\nRound 1: clipping, layers, regions, scroll,\na text buffer, and Modal/Table/Textarea.\n\nRound 2: the editor shell."
		default: return c"# W\n\nA small, self-hosting compiled language.\nC-like semantics, Python-like syntax.\n\nThe compiler is written in W."


struct ui_shell_state:
	ui_split_state split
	ui_tree_state tree
	ui_tab_state tabs
	ui_menubar_state bar
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
	# View menu state: the sidebar check item, the Theme radio group
	# (0 light, 1 dark, 2 ocean) and the theme it last applied.
	int32 show_sidebar
	int32 theme_choice
	int32 theme_applied
	ui_theme theme


void ui_shell_init(ui_shell_state* st):
	ui_split_init(&st.split, 200.0)
	st.split.min_a = 120.0
	st.split.min_b = 240.0
	ui_tree_init(&st.tree)
	ui_tab_init(&st.tabs)
	ui_menubar_init(&st.bar)
	ui_menu_init(&st.menu, 150.0)
	ui_toast_init(&st.toast)
	ui_textarea_init(&st.editor)
	st.folder_open[0] = 1
	st.folder_open[1] = 0
	mem_fill[int32](st.open_docs, 0, ui_shell_doc_count)
	st.open_count = 0
	st.active_tab = 0
	st.loaded_doc = 0 - 1
	st.show_sidebar = 1
	st.theme_choice = 1
	st.theme_applied = 1
	ui_theme_dark(&st.theme)


# Restyle the shell for a Theme radio choice.
void ui_shell_set_theme(ui_shell_state* st, int choice):
	if (choice == 0): ui_theme_light(&st.theme)
	else if (choice == 2): ui_theme_ocean(&st.theme)
	else: ui_theme_dark(&st.theme)
	st.theme_choice = choice
	st.theme_applied = choice


# Open a document as a tab, or switch to it if it is already open.
void ui_shell_open_doc(ui_shell_state* st, int doc):
	int i = 0
	while (i < st.open_count):
		if (st.open_docs[i] == doc):
			st.active_tab = i
			return
		i = i + 1
	if (st.open_count >= ui_shell_doc_count): return
	st.open_docs[st.open_count] = doc
	st.active_tab = st.open_count
	st.open_count = st.open_count + 1


void ui_shell_close_tab(ui_shell_state* st, int index):
	if ((index < 0) || (index >= st.open_count)): return
	int i = index
	while (i + 1 < st.open_count):
		st.open_docs[i] = st.open_docs[i + 1]
		i = i + 1
	st.open_count = st.open_count - 1
	if (st.active_tab >= st.open_count): st.active_tab = st.open_count - 1
	if (st.active_tab < 0): st.active_tab = 0
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


# Open the menu bar's View menu with its Theme submenu showing, for the
# same reproducible-screenshot reason as ui_shell_pin_menu.
void ui_shell_pin_menubar(ui_shell_state* st):
	ui_menubar_switch(&st.bar, 2, 0)
	st.bar.menu.hl[0] = 1
	st.bar.menu.sub[0] = 1


# The menu bar. Its items act on the shell directly, and the toast
# says what happened for the ones that are only demo actions.
void ui_shell_menubar(ui_context* ctx, ui_shell_state* st, ui_rect strip, int now_ms):
	ui_menu_state* m = &st.bar.menu
	ui_menubar_begin(ctx, &st.bar, strip)
	if (ui_menubar_menu(ctx, &st.bar, c"&File")):
		if (ui_menu_item_key(ctx, m, c"&New File", GFX_MOD_CTRL, 'n', 1)):
			ui_toast_show(&st.toast, c"New File is a demo action", now_ms, 2000)
		if (ui_menu_begin_sub(ctx, m, c"Open &Recent", 1)):
			int doc = 0
			while (doc < ui_shell_doc_count):
				if (ui_menu_item(ctx, m, ui_shell_doc_name(doc), 1)): ui_shell_open_doc(st, doc)
				doc = doc + 1
			ui_menu_end_sub(ctx, m)
		ui_menu_separator(ctx, m)
		if (ui_menu_item_key(ctx, m, c"&Close Tab", GFX_MOD_CTRL, 'w', st.open_count > 0)):
			ui_shell_close_tab(st, st.active_tab)
		if (ui_menu_item(ctx, m, c"Close &All Tabs", st.open_count > 0)):
			st.open_count = 0
			st.active_tab = 0
			st.loaded_doc = 0 - 1
		ui_menubar_menu_end(ctx, &st.bar)
	if (ui_menubar_menu(ctx, &st.bar, c"&Edit")):
		ui_menu_item_key(ctx, m, c"&Undo", GFX_MOD_CTRL, 'z', 0)
		ui_menu_item_key(ctx, m, c"&Redo", GFX_MOD_CTRL | GFX_MOD_SHIFT, 'z', 0)
		ui_menu_separator(ctx, m)
		if (ui_menu_item_key(ctx, m, c"&Find", GFX_MOD_CTRL, 'f', 1)):
			ui_toast_show(&st.toast, c"Find is a demo action", now_ms, 2000)
		ui_menubar_menu_end(ctx, &st.bar)
	if (ui_menubar_menu(ctx, &st.bar, c"&View")):
		ui_menu_check_key(ctx, m, c"&Sidebar", &st.show_sidebar, GFX_MOD_CTRL, 'b', 1)
		if (ui_menu_begin_sub(ctx, m, c"&Theme", 1)):
			ui_menu_radio(ctx, m, c"&Light", &st.theme_choice, 0, 1)
			ui_menu_radio(ctx, m, c"&Dark", &st.theme_choice, 1, 1)
			ui_menu_radio(ctx, m, c"&Ocean", &st.theme_choice, 2, 1)
			ui_menu_end_sub(ctx, m)
		ui_menu_separator(ctx, m)
		if (ui_menu_item(ctx, m, c"&Collapse All Folders", 1)):
			st.folder_open[0] = 0
			st.folder_open[1] = 0
		ui_menubar_menu_end(ctx, &st.bar)
	if (ui_menubar_menu(ctx, &st.bar, c"&Help")):
		if (ui_menu_item(ctx, m, c"&About W", 1)):
			ui_toast_show(&st.toast, c"W: a small self-hosting language", now_ms, 2000)
		ui_menubar_menu_end(ctx, &st.bar)
	ui_menubar_end(ctx, &st.bar)


void ui_shell_sidebar(ui_context* ctx, ui_shell_state* st, ui_rect sidebar):
	ui_render_rect(ctx.rndr, sidebar, ctx.theme.background)
	ui_tree_begin(ctx, sidebar, &st.tree)
	int folder = 0
	while (folder < ui_shell_folder_count):
		if (ui_tree_node(ctx, &st.tree, ui_shell_folder_name(folder), &st.folder_open[folder])):
			int f = 0
			while (f < ui_shell_folder_files(folder)):
				int doc = ui_shell_doc_id(folder, f)
				if (ui_tree_leaf(ctx, &st.tree, ui_shell_doc_name(doc))): ui_shell_open_doc(st, doc)
				f = f + 1
			ui_tree_node_end(ctx, &st.tree)
		folder = folder + 1
	ui_tree_end(ctx, &st.tree)


# ---- editor pane: tabs over a text surface -----------------------------
void ui_shell_pane(ui_context* ctx, ui_shell_state* st, ui_rect pane):
	float32 strip_h = 28.0
	ui_rect strip = ui_rect_new(pane.x, pane.y, pane.w, strip_h)
	ui_tabs_begin(ctx, strip, &st.tabs, &st.active_tab)
	int t = 0
	while (t < st.open_count):
		ui_tab(ctx, &st.tabs, ui_shell_doc_name(st.open_docs[t]), 1)
		t = t + 1
	int closed = ui_tabs_end(ctx, &st.tabs)
	if (closed >= 0): ui_shell_close_tab(st, closed)

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


# ---- the overlays -------------------------------------------------------
void ui_shell_overlays(ui_context* ctx, ui_shell_state* st, ui_rect sidebar, int now_ms):
	# Right-clicking the sidebar opens the context menu at the pointer.
	if (st.show_sidebar): ui_menu_open_on_right_click(ctx, sidebar, &st.menu)
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


# One frame of the shell. Call between ui_begin_window and ui_end.
# now_ms drives the toast, and is the caller's to supply — the widget
# layer reads no clocks (docs/projects/ui_widgets.md §9.3).
void ui_shell_body(ui_context* ctx, ui_shell_state* st, int now_ms):
	float32 vw = cast(float32, ctx.rndr.vp_w)
	float32 vh = cast(float32, ctx.rndr.vp_h)
	# The menu bar goes first: it owns the keyboard while one of its
	# menus is open, so it has to see the keys before the editor does.
	float32 bar_h = 28.0
	ui_shell_menubar(ctx, st, ui_rect_new(0.0, 0.0, vw, bar_h), now_ms)

	ui_rect body = ui_rect_new(0.0, bar_h, vw, vh - bar_h)
	ui_rect sidebar = ui_rect_new(0.0, bar_h, 0.0, 0.0)
	ui_rect pane = body
	if (st.show_sidebar): ui_split(ctx, body, 1, &st.split, &sidebar, &pane)

	# ---- sidebar: the file tree ----------------------------------------
	if (st.show_sidebar): ui_shell_sidebar(ctx, st, sidebar)
	ui_shell_pane(ctx, st, pane)
	ui_shell_overlays(ctx, st, sidebar, now_ms)
	# A Theme pick restyles everything from the next frame on.
	if (st.theme_choice != st.theme_applied): ui_shell_set_theme(st, st.theme_choice)
