/*
graphics.ui.widgets.tree: a scrollable, keyboard-navigable tree view —
the editor shell's sidebar (docs/projects/ui_widgets.md §9.2).

	ui_tree_begin(ctx, sidebar, &st)
	int d = 0
	while (d < dir_count):
		if (ui_tree_node(ctx, &st, dir_name(d), &dir_open[d])):
			int f = 0
			while (f < file_count(d)):
				if (ui_tree_leaf(ctx, &st, file_name(d, f))):
					open_file(d, f)
				f = f + 1
			ui_tree_node_end(ctx, &st)
		d = d + 1
	ui_tree_end(ctx, &st)

The caller's own recursion IS the tree walk. That is the whole design:
a collapsed subtree costs nothing because ui_tree_node returns 0 and
the caller simply does not recurse into it — no flattening pass, no
node array, and expansion stays caller-owned int32 state exactly like
ui_dropdown's and ui_modal_begin's `open`. ui_tree_node follows
ui_modal_begin's contract: it returns 0 having pushed nothing, and then
ui_tree_node_end must not be called.

ui_tree_leaf returns 1 on the frame its leaf is activated, so the
caller acts at the call site and never has to map a row index back to
its own data. Activation is a SINGLE click, which is what Sublime's
sidebar does — and which conveniently means this widget needs no
double-click and therefore no clock.

Two things worth knowing about the implementation:

Every row in the walk takes a widget id, including rows scrolled out of
view; only the drawing and hit-testing are skipped. Virtualization is
about not measuring text and not emitting vertices, and an integer
increment is not worth saving — whereas if off-screen rows skipped
their ids, every widget issued after the tree would shift its id as the
tree SCROLLED, which is far more frequent than expanding. (Ids still
shift when the row count changes; hash ids remain the real fix.)

Keyboard navigation happens during the walk, because the widget never
holds the tree and so cannot see what the next visible row is before
the caller issues it. Up/down move a walk-index cursor against the
PREVIOUS frame's row count; left/right are queued in ui_tree_begin and
resolved inside ui_tree_node at the moment the focused node's own
`open` pointer is in hand. parent_of_depth, maintained by the walk
itself, makes "left collapses, then ascends to the parent" exact
rather than inferred. Motion that changes the cursor mid-walk shows up
one frame later, the same trade §4.4 documents for scroll extent.
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


# Deepest nesting the parent index tracks. Deeper rows still draw and
# still navigate up and down; only "left ascends to the parent" stops
# working past it, which is the documented fixed-capacity convention
# ui_context.chars and the popup stack already use.
int ui_tree_max_depth():
	return 32


# Width of the disclosure marker's column. Leaves reserve it too, so a
# folder's label and a file's label line up at the same depth.
float32 ui_tree_marker():
	return 14.0


struct ui_tree_state:
	ui_scroll_state scroll
	int32 selected         # walk-order index of the selected row, -1 = none
	int32 focused          # keyboard cursor, walk-order index, -1 = none
	int32 row_height       # 0 = the theme's widget height
	int32 indent           # 0 = theme.unit * 2
	# Per-frame walk cursor, reset by ui_tree_begin.
	int32 walk_index
	int32 depth
	int32 row_count        # the previous frame's total, for nav clamping
	int32 activated        # 1 on the frame a leaf was activated
	int32 changed          # 1 on the frame the selection moved
	int32 tree_id          # the container's id; rows get their own
	int32 pending_nav      # a LEFT/RIGHT queued for this frame's walk
	int32 pending_enter
	int32[32] parent_of_depth
	float32 body_x
	float32 body_y
	float32 body_w


void ui_tree_init(ui_tree_state* st):
	ui_scroll_init(&st.scroll)
	st.selected = 0 - 1
	st.focused = 0 - 1
	st.row_height = 0
	st.indent = 0
	st.walk_index = 0
	st.depth = 0
	st.row_count = 0
	st.activated = 0
	st.changed = 0
	st.tree_id = 0
	st.pending_nav = 0
	st.pending_enter = 0
	int i = 0
	while (i < ui_tree_max_depth()):
		st.parent_of_depth[i] = 0 - 1
		i = i + 1
	st.body_x = 0.0
	st.body_y = 0.0
	st.body_w = 0.0


int ui_tree_row_height(ui_context* ctx, ui_tree_state* st):
	if (st.row_height > 0):
		return st.row_height
	return ctx.theme.widget_height


float32 ui_tree_indent(ui_context* ctx, ui_tree_state* st):
	if (st.indent > 0):
		return cast(float32, st.indent)
	return cast(float32, ctx.theme.unit) * 2.0


# Enter the tree: claim focus, resolve the frame's keyboard input, and
# open the scrollable body. Everything between here and ui_tree_end is
# the caller's walk.
void ui_tree_begin(ui_context* ctx, ui_rect area, ui_tree_state* st):
	int id = ctx.next_id
	ctx.next_id = ctx.next_id + 1
	st.tree_id = id
	st.walk_index = 0
	st.depth = 0
	st.activated = 0
	st.changed = 0
	st.pending_nav = 0
	st.pending_enter = 0

	# Focus follows the press, like ui_textarea's. It is claimed by the
	# container rather than by a row: row ids shift as the tree expands
	# and scrolls, so a persistent ctx.focus must never key on one. The
	# keyboard cursor is st.focused, a walk index.
	if (ctx.input.mouse_pressed && (ui_scope_blocked(ctx) == 0) && (ctx.disabled == 0)):
		if (ui_rect_contains(area, cast(float32, ctx.input.press_x), cast(float32, ctx.input.press_y))):
			ctx.focus = id
		else if (ctx.focus == id):
			ctx.focus = 0

	if ((ctx.focus == id) && (ctx.disabled == 0)):
		int i = 0
		while (i < ctx.char_count):
			# Return arrives as a CHAR, not a NAV — there is no
			# GFX_NAV_ENTER — so activation is drained from both queues.
			if (ctx.chars[i] == 13):
				st.pending_enter = 1
			else if (ctx.chars[i] == 27):
				ctx.focus = 0
			i = i + 1
		i = 0
		while (i < ctx.nav_count):
			int nav = ctx.navs[i]
			if (nav == GFX_NAV_UP):
				if (st.focused > 0):
					st.focused = st.focused - 1
				else if (st.row_count > 0):
					st.focused = 0
			else if (nav == GFX_NAV_DOWN):
				if (st.focused + 1 < st.row_count):
					st.focused = st.focused + 1
			else if (nav == GFX_NAV_HOME):
				if (st.row_count > 0):
					st.focused = 0
			else if (nav == GFX_NAV_END):
				st.focused = st.row_count - 1
			else:
				# LEFT and RIGHT need the focused node's own `open`
				# pointer, which only exists partway through the walk.
				if ((nav == GFX_NAV_LEFT) || (nav == GFX_NAV_RIGHT)):
					st.pending_nav = nav
			i = i + 1

	float32 row_h = cast(float32, ui_tree_row_height(ctx, st))
	# Keep the cursor in view. Up/down are already applied, so the common
	# case is exact; left/right land one frame later.
	if (st.focused >= 0):
		ui_scroll_reveal(&st.scroll, cast(float32, st.focused) * row_h, row_h)

	ui_scroll_begin(ctx, area, &st.scroll)
	ui_layout* lo = ui_layout_top(ctx)
	st.body_x = lo.bounds.x
	st.body_y = lo.bounds.y
	st.body_w = area.w


# Is the row at this walk index inside the viewport the last frame
# measured? Content-space test, exactly ui_table_row's.
int ui_tree_row_visible(ui_tree_state* st, float32 row_h, int index):
	float32 top = row_h * cast(float32, index)
	if (top + row_h <= st.scroll.offset_y):
		return 0
	if (top >= st.scroll.offset_y + st.scroll.view_h):
		return 0
	return 1


# The body of a row, shared by nodes and leaves. Advances the walk,
# claims the extent, and — for visible rows only — hit-tests and draws.
# Returns 1 when this row was clicked.
int ui_tree_row(ui_context* ctx, ui_tree_state* st, char* label, int is_node, int expanded):
	float32 row_h = cast(float32, ui_tree_row_height(ctx, st))
	int index = st.walk_index
	st.walk_index = st.walk_index + 1

	ui_rect row = ui_rect_new(st.body_x, st.body_y + row_h * cast(float32, index), st.body_w, row_h)
	# Claimed whether or not it is drawn: the scroll region has to know
	# how tall the whole tree is, not just its visible part.
	ui_region_claim(ctx, row)

	# Taken for every row, visible or not — see the module header.
	int id = ctx.next_id
	ctx.next_id = ctx.next_id + 1
	if (ui_tree_row_visible(st, row_h, index) == 0):
		return 0

	int clicked = ui_click_behavior(ctx, id, row)
	if (clicked):
		if (st.selected != index):
			st.selected = index
			st.changed = 1
		st.focused = index
		ctx.focus = st.tree_id

	if (st.selected == index):
		ui_render_rect(ctx.rndr, row, ctx.theme.widget_active)
	else if (ctx.hot == id):
		ui_render_rect(ctx.rndr, row, ctx.theme.widget_hot)
	# The keyboard cursor is drawn even when it is not the selection, so
	# arrowing around without pressing Enter is visible.
	if ((st.focused == index) && (ctx.focus == st.tree_id) && (st.selected != index)):
		ui_render_rect(ctx.rndr, ui_rect_new(row.x, row.y, 2.0, row.h), ctx.theme.focus)

	float32 marker = ui_tree_marker()
	float32 x = row.x + cast(float32, ctx.theme.pad) + ui_tree_indent(ctx, st) * cast(float32, st.depth)
	if (is_node):
		ui_rect chev = ui_rect_new(x, row.y + (row_h - marker) * 0.5, marker, marker)
		if (expanded):
			ui_draw_chevron(ctx.rndr, chev, ctx.theme.text_muted)
		else:
			ui_draw_chevron_right(ctx.rndr, chev, ctx.theme.text_muted)

	int scale = ctx.theme.text_scale
	float32 tx = x + marker + 4.0
	float32 ty = row.y + (row_h - cast(float32, ui_text_height(scale))) * 0.5
	# Clipped to the row, so a long name truncates instead of spilling
	# past the sidebar's edge.
	ui_clip_push(ctx.rndr, row)
	ui_draw_text(ctx.rndr, tx, ty, label, scale, ui_text_color(ctx))
	ui_clip_pop(ctx.rndr)
	return clicked


# A row with children. Returns 1 when it is expanded, and only then does
# the caller recurse and call ui_tree_node_end. Returns 0 having pushed
# nothing — the ui_modal_begin contract.
int ui_tree_node(ui_context* ctx, ui_tree_state* st, char* label, int32* open):
	int index = st.walk_index
	if (st.depth < ui_tree_max_depth()):
		st.parent_of_depth[st.depth] = index

	# Left and right are resolved here, where this node's own expansion
	# state is addressable, rather than guessed at in ui_tree_begin.
	if ((index == st.focused) && (st.pending_nav != 0)):
		if (st.pending_nav == GFX_NAV_RIGHT):
			if (open[0] == 0):
				open[0] = 1
			else:
				# Already open: descend to the first child, which is
				# always the very next row in the walk.
				st.focused = index + 1
		else:
			if (open[0]):
				open[0] = 0
			else if (st.depth > 0):
				st.focused = st.parent_of_depth[st.depth - 1]
		st.pending_nav = 0

	if (ui_tree_row(ctx, st, label, 1, open[0])):
		# A click anywhere on a folder row toggles it, chevron or label.
		if (open[0]):
			open[0] = 0
		else:
			open[0] = 1
	if (open[0] == 0):
		return 0
	st.depth = st.depth + 1
	return 1


void ui_tree_node_end(ui_context* ctx, ui_tree_state* st):
	if (st.depth > 0):
		st.depth = st.depth - 1


# A row without children. Returns 1 on the frame it is activated, by a
# click or by Enter while it holds the keyboard cursor.
int ui_tree_leaf(ui_context* ctx, ui_tree_state* st, char* label):
	int index = st.walk_index
	int activated = 0

	if (index == st.focused):
		if (st.pending_nav == GFX_NAV_LEFT):
			# A leaf has nothing to collapse, so left always ascends.
			if (st.depth > 0):
				st.focused = st.parent_of_depth[st.depth - 1]
			st.pending_nav = 0
		else if (st.pending_nav == GFX_NAV_RIGHT):
			st.pending_nav = 0
		if (st.pending_enter):
			st.pending_enter = 0
			activated = 1
			if (st.selected != index):
				st.selected = index
				st.changed = 1

	if (ui_tree_row(ctx, st, label, 0, 0)):
		activated = 1
	if (activated):
		st.activated = 1
	return activated


# Leave the tree. Returns 1 on the frame the selection moved or a leaf
# was activated, 0 otherwise.
int ui_tree_end(ui_context* ctx, ui_tree_state* st):
	ui_scroll_end(ctx, &st.scroll)
	st.row_count = st.walk_index
	# The walk may have shrunk under the cursor — a node collapsing
	# takes its children with it.
	if (st.focused >= st.row_count):
		st.focused = st.row_count - 1
	if (st.selected >= st.row_count):
		st.selected = st.row_count - 1
	st.depth = 0
	if (st.changed || st.activated):
		return 1
	return 0
