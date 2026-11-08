/*
graphics.ui.widgets.listbox: a scrollable list whose items can be
selected together (#913), the desktop list box with extended selection.

	char[64] picked             # caller-owned, one flag per item
	ui_listbox_begin(ctx, area, &st, c"Fruit", &picked[0], count)
	for i in range(count): ui_listbox_item(ctx, &st, i, name_of(i))
	if (ui_listbox_end(ctx, &st)): ... picked[] changed this frame

Pointer: a click selects one item; Ctrl (or Super) + click toggles one;
Shift + click selects the range from the anchor (Ctrl + Shift adds it).
Keyboard, while the list holds focus: Up/Down/Home/End/Page Up/Page
Down move the cursor and select it alone; with Shift they select the
range from the anchor; with Ctrl they move the cursor only. Space
toggles the cursor's item (Shift + Space selects the range), Ctrl+A
selects every item.

The selection lives in the caller's flags, so an application whose
selection has another owner (the Mermaid canvas) fills them every frame
and reads them back on a change. The cursor and the anchor are the
widget's.

Semantics: the list is a LIST with UI_ACCESS_MULTISELECTABLE, its items
LIST_ITEMs with UI_ACCESS_SELECTED, and every item is published (not
only the visible ones) so a screen reader counts the whole selection.
Items take UI_ACCESS_SELECT ("add", "remove", "only"), activation
(select alone) and focus (move the cursor); while the list holds focus
the snapshot's focused node is its cursor item.

Ids are reserved, not counted: the list takes 1 + count ids on every
frame, item i being first_id + i, so a request names the same item on
the frame it arrives.
*/
import lib.lib
import graphics.event
import graphics.ui.rect
import graphics.ui.theme
import graphics.ui.font
import graphics.ui.render
import graphics.ui.text
import graphics.ui.widgets.state
import graphics.ui.widgets.layout
import graphics.ui.widgets.context
import graphics.ui.widgets.scroll


struct ui_listbox_state:
	ui_scroll_state scroll
	int32 cursor           # the keyboard's item, -1 before the first
	int32 anchor           # where a Shift range starts
	int32 row_height       # 0 = the theme's widget height
	# Set by ui_listbox_begin, read by item/end.
	char* flags
	int32 count
	int32 list_id
	int32 first_id
	float32 body_x
	float32 body_y
	float32 body_w
	int32 changed
	int32 access_saved_parent


void ui_listbox_init(ui_listbox_state* st):
	ui_scroll_init(&st.scroll)
	st.cursor = 0 - 1
	st.anchor = 0 - 1
	st.row_height = 0
	st.flags = 0
	st.count = 0
	st.list_id = 0
	st.first_id = 0
	st.body_x = 0.0
	st.body_y = 0.0
	st.body_w = 0.0
	st.changed = 0
	st.access_saved_parent = 0


int ui_listbox_row_height(ui_context* ctx, ui_listbox_state* st):
	if (st.row_height > 0): return st.row_height
	return ctx.theme.widget_height


void ui_listbox_set(ui_listbox_state* st, int index, int on):
	if ((index < 0) || (index >= st.count)): return
	int v = 0
	if (on): v = 1
	if (st.flags[index] != v):
		st.flags[index] = v
		st.changed = 1


# Select [from, to] (either order); only=1 clears the rest first.
void ui_listbox_select_range(ui_listbox_state* st, int from, int to, int only):
	if (from > to):
		int t = from
		from = to
		to = t
	for i in range(st.count):
		if ((i >= from) && (i <= to)): ui_listbox_set(st, i, 1)
		else if (only): ui_listbox_set(st, i, 0)


void ui_listbox_select_only(ui_listbox_state* st, int index):
	ui_listbox_select_range(st, index, index, 1)


# Number of selected items.
int ui_listbox_selected_count(ui_listbox_state* st):
	int n = 0
	for i in range(st.count):
		if (st.flags[i]): n = n + 1
	return n


# Apply a pointer click or a key's selection to item index under
# modifier bits, moving the cursor there.
void ui_listbox_pick(ui_listbox_state* st, int index, int mods):
	int extend = mods & GFX_MOD_SHIFT
	int toggle = mods & (GFX_MOD_CTRL | GFX_MOD_SUPER)
	if (extend):
		int from = st.anchor
		if ((from < 0) || (from >= st.count)): from = index
		ui_listbox_select_range(st, from, index, toggle == 0)
		st.anchor = from
	else if (toggle):
		ui_listbox_set(st, index, st.flags[index] == 0)
		st.anchor = index
	else:
		ui_listbox_select_only(st, index)
		st.anchor = index
	st.cursor = index


int ui_listbox_ctrl_a(int ch, int mods):
	if ((mods & (GFX_MOD_CTRL | GFX_MOD_SUPER)) == 0): return 0
	if (mods & GFX_MOD_ALT): return 0
	return (ch == 'a') || (ch == 'A') || (ch == 1)


# The frame's keys while the list holds focus.
void ui_listbox_keys(ui_context* ctx, ui_listbox_state* st, float32 row_h):
	int page = 1
	if (st.scroll.view_h > row_h): page = cast(int, st.scroll.view_h / row_h)
	int moved = 0
	for k in range(ctx.nav_count):
		int nav = ctx.navs[k]
		int mods = ctx.nav_mods[k]
		int to = st.cursor
		if (nav == GFX_NAV_DOWN): to = to + 1
		else if (nav == GFX_NAV_UP): to = to - 1
		else if (nav == GFX_NAV_HOME): to = 0
		else if (nav == GFX_NAV_END): to = st.count - 1
		else if (nav == GFX_NAV_PAGE_DOWN): to = to + page
		else if (nav == GFX_NAV_PAGE_UP): to = to - page
		else: continue
		if (st.cursor < 0): to = 0
		if (to >= st.count): to = st.count - 1
		if (to < 0): to = 0
		ctx.navs[k] = 0
		moved = 1
		if (((mods & GFX_MOD_SHIFT) == 0) && ((mods & (GFX_MOD_CTRL | GFX_MOD_SUPER)) != 0)):
			# Ctrl moves the cursor and leaves the selection alone.
			st.cursor = to
		else: ui_listbox_pick(st, to, mods & (GFX_MOD_SHIFT | GFX_MOD_CTRL | GFX_MOD_SUPER))
	for k in range(ctx.char_count):
		int ch = ctx.chars[k]
		int mods = ctx.char_mods[k]
		if (ui_listbox_ctrl_a(ch, mods)):
			ui_listbox_select_range(st, 0, st.count - 1, 1)
			ctx.chars[k] = 0
		else if ((ch == 32) && ((mods & GFX_MOD_ALT) == 0)):
			if (st.cursor < 0): st.cursor = 0
			if (mods & GFX_MOD_SHIFT): ui_listbox_pick(st, st.cursor, GFX_MOD_SHIFT | (mods & GFX_MOD_CTRL))
			else: ui_listbox_pick(st, st.cursor, GFX_MOD_CTRL)
			ctx.chars[k] = 0
			moved = 1
	if (moved): ui_scroll_reveal(&st.scroll, row_h * cast(float32, st.cursor), row_h)


# Item index's row in content space.
ui_rect ui_listbox_row(ui_context* ctx, ui_listbox_state* st, int index):
	float32 row_h = cast(float32, ui_listbox_row_height(ctx, st))
	return ui_rect_new(st.body_x, st.body_y + row_h * cast(float32, index), st.body_w, row_h)


# Draw the frame and enter the scrollable body. flags holds count bytes,
# 1 for a selected item; the widget changes them in place.
void ui_listbox_begin(ui_context* ctx, ui_rect area, ui_listbox_state* st, char* name, char* flags, int count):
	st.flags = flags
	st.count = count
	st.changed = 0
	if (st.cursor >= count): st.cursor = count - 1
	if (st.anchor >= count): st.anchor = count - 1
	float32 row_h = cast(float32, ui_listbox_row_height(ctx, st))
	int id = ctx.next_id
	st.list_id = id
	st.first_id = id + 1
	ctx.next_id = ctx.next_id + 1 + count
	# An assistive focus request named an item: the list takes the
	# keyboard and its cursor moves there.
	if ((ctx.focus >= st.first_id) && (ctx.focus < st.first_id + count)):
		st.cursor = ctx.focus - st.first_id
		ctx.focus = id
	st.access_saved_parent = ctx.access_parent
	ui_access_node* n = ui_access_widget(ctx, id, UI_ACCESS_LIST, area, name)
	if (n != 0):
		n.states = n.states | UI_ACCESS_MULTISELECTABLE
		ctx.access_parent = id
	ui_draw_rrect(ctx.rndr, area, cast(float32, ctx.theme.radius_small), ctx.theme.surface)
	ui_outline(ctx, area, 1.0, ctx.theme.border)
	if (ui_focus_stop(ctx, id, area, 0) && (ctx.disabled == 0) && (ui_scope_blocked(ctx) == 0) && (count > 0)):
		ui_listbox_keys(ctx, st, row_h)
		if (st.cursor >= 0):
			ctx.access_focus_owner = id
			ctx.access_focus_child = st.first_id + st.cursor
	ui_rect body = ui_rect_inset(area, 1.0)
	ui_scroll_begin(ctx, body, &st.scroll)
	ui_layout* lo = ui_layout_top(ctx)
	st.body_x = lo.bounds.x
	st.body_y = lo.bounds.y
	st.body_w = body.w
	# Clicks and assistive requests apply here, before any item is
	# published, so the snapshot and the drawing agree with the flags.
	if (count > 0):
		int first = cast(int, st.scroll.offset_y / row_h)
		int last = cast(int, (st.scroll.offset_y + st.scroll.view_h) / row_h)
		if (first < 0): first = 0
		if (last >= count): last = count - 1
		for i in range(first, last + 1):
			if (ui_click_behavior(ctx, st.first_id + i, ui_listbox_row(ctx, st, i))): ui_listbox_pick(st, i, ctx.input.mods)
	if ((ctx.access_activation_count > 0) || (ctx.access_select_count > 0)):
		for i in range(count):
			int item = st.first_id + i
			if ((ctx.disabled == 0) && (ui_scope_blocked(ctx) == 0) && ui_access_take_activation(ctx, item)): ui_listbox_pick(st, i, 0)
			int mode = ui_access_take_select(ctx, item)
			if (mode == UI_ACCESS_SELECT_ONLY): ui_listbox_pick(st, i, 0)
			else if (mode == UI_ACCESS_SELECT_ADD): ui_listbox_set(st, i, 1)
			else if (mode == UI_ACCESS_SELECT_REMOVE): ui_listbox_set(st, i, 0)


# Item index (0 .. count-1, in order). Returns 1 when it is on screen.
int ui_listbox_item(ui_context* ctx, ui_listbox_state* st, int index, char* label):
	if ((index < 0) || (index >= st.count)): return 0
	float32 row_h = cast(float32, ui_listbox_row_height(ctx, st))
	ui_rect row = ui_listbox_row(ctx, st, index)
	ui_region_claim(ctx, row)
	int id = st.first_id + index
	float32 top = row_h * cast(float32, index)
	int visible = (top + row_h > st.scroll.offset_y) && (top < st.scroll.offset_y + st.scroll.view_h)
	ui_access_node* n = ui_access_widget(ctx, id, UI_ACCESS_LIST_ITEM, row, label)
	if (n != 0):
		n.states = n.states | UI_ACCESS_FOCUSABLE
		n.actions = UI_ACCESS_ACTIVATE | UI_ACCESS_SELECT | UI_ACCESS_FOCUS
		if (st.flags[index]): n.states = n.states | UI_ACCESS_SELECTED
	if (visible == 0): return 0
	if (st.flags[index]):
		ui_render_rect(ctx.rndr, row, ctx.theme.widget_active)
		ui_selection_marker(ctx, row)
	else if (ctx.hot == id): ui_render_rect(ctx.rndr, row, ctx.theme.widget_hot)
	if ((index == st.cursor) && (ctx.focus == st.list_id) && ctx.focus_visible):
		ui_outline(ctx, ui_rect_inset(row, 1.0), 1.0, ctx.theme.focus)
	int scale = ctx.theme.text_scale
	float32 pad = cast(float32, ctx.theme.pad)
	ui_clip_push(ctx.rndr, row)
	ui_draw_text(ctx.rndr, row.x + pad + 6.0, row.y + (row_h - cast(float32, ui_text_height(scale))) * 0.5, label, scale, ui_text_color(ctx))
	ui_clip_pop(ctx.rndr)
	return 1


# Leave the body. Returns 1 on a frame the selection changed.
int ui_listbox_end(ui_context* ctx, ui_listbox_state* st):
	ui_scroll_end(ctx, &st.scroll)
	ctx.access_parent = st.access_saved_parent
	return st.changed
