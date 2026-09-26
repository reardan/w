# Headless unit tests for the tree view: the caller-driven walk, row
# virtualization, click selection and activation, and keyboard
# navigation resolved during the walk
# (docs/projects/ui_widgets.md §9.2). No GL context or display.
# x64-only: the widget set imports graphics.gl/graphics.window, which
# link libGL/libX11 on the 64-bit Linux targets.
# wbuild: name=graphics_ui_tree_test arch_only=x64
import lib.testing
import graphics.event
import graphics.ui.rect
import graphics.ui.theme
import graphics.ui.render
import graphics.ui.widgets
import graphics.ui.testing


# The fixture tree: two folders of two files each.
#
#   0  src/          (open[0])
#   1    main.w
#   2    lib.w
#   3  docs/         (open[1])
#   4    readme.md
#   5    design.md
#
# Walk indices are the numbers on the left, and they only exist for
# rows the caller actually issues — a collapsed folder contributes one.
char* fixture_file(int folder, int index):
	if (folder == 0):
		if (index == 0): return c"main.w"
		return c"lib.w"
	if (index == 0): return c"readme.md"
	return c"design.md"


char* fixture_folder(int folder):
	if (folder == 0): return c"src"
	return c"docs"


# One frame of the fixture tree. `opened` collects the walk index of any
# leaf activated this frame, or -1.
int fixture_frame(ui_context* ctx, ui_tree_state* st, int32* open, ui_rect area):
	int activated = 0 - 1
	ui_begin(ctx, 320, 240)
	ui_tree_begin(ctx, area, st)
	for d in range(2):
		if (ui_tree_node(ctx, st, fixture_folder(d), &open[d])):
			for f in range(2):
				# Read the walk index before the call: ui_tree_leaf
				# advances it.
				int at = st.walk_index
				if (ui_tree_leaf(ctx, st, fixture_file(d, f))): activated = at
			ui_tree_node_end(ctx, st)
	ui_tree_end(ctx, st)
	ui_end(ctx)
	return activated


ui_rect fixture_area():
	return ui_rect_new(0.0, 0.0, 200.0, 240.0)


# A collapsed folder's children are never issued at all. That is the
# whole point of making the caller drive the walk: the cost of a
# collapsed subtree is not "drawn and clipped away", it is not paid.
void test_a_collapsed_node_never_issues_its_children():
	ui_fixture fx
	ui_context* ctx = ui_fixture_init(&fx)
	ui_tree_state st
	ui_tree_init(&st)
	int32[2] open
	open[0] = 0
	open[1] = 0

	fixture_frame(ctx, &st, &open[0], fixture_area())
	assert_equal(2, st.row_count)

	open[0] = 1
	fixture_frame(ctx, &st, &open[0], fixture_area())
	assert_equal(4, st.row_count)

	open[1] = 1
	fixture_frame(ctx, &st, &open[0], fixture_area())
	assert_equal(6, st.row_count)
	ui_render_destroy(&fx.r)


# Clicking a folder row toggles it — anywhere on the row, not only on
# the chevron, which is what every file tree does.
void test_clicking_a_folder_row_toggles_it():
	ui_fixture fx
	ui_context* ctx = ui_fixture_init(&fx)
	ui_tree_state st
	ui_tree_init(&st)
	int32[2] open
	open[0] = 0
	open[1] = 0

	# Row 0 spans y 0..32 at the default widget height; click its label,
	# well clear of the chevron column.
	ui_test_click(ctx, 120, 16)
	fixture_frame(ctx, &st, &open[0], fixture_area())
	assert_equal(1, open[0])

	ui_test_click(ctx, 120, 16)
	fixture_frame(ctx, &st, &open[0], fixture_area())
	assert_equal(0, open[0])
	ui_render_destroy(&fx.r)


# A single click on a leaf activates it, once, and reports which leaf at
# the call site. Sublime's sidebar opens files on one click.
void test_clicking_a_leaf_activates_it_exactly_once():
	ui_fixture fx
	ui_context* ctx = ui_fixture_init(&fx)
	ui_tree_state st
	ui_tree_init(&st)
	int32[2] open
	open[0] = 1
	open[1] = 0

	# Walk index 1 is src/main.w, the row spanning y 32..64.
	ui_test_click(ctx, 120, 48)
	assert_equal(1, fixture_frame(ctx, &st, &open[0], fixture_area()))
	assert_equal(1, st.selected)

	# The edge is one frame wide, like every other widget's.
	assert_equal(0 - 1, fixture_frame(ctx, &st, &open[0], fixture_area()))
	ui_render_destroy(&fx.r)


# Rows scrolled out of the viewport draw nothing, while the scroll
# region still learns the full height — the ui_table_row bargain.
void test_offscreen_rows_cost_no_vertices_but_still_count():
	ui_fixture fx
	ui_context* ctx = ui_fixture_init(&fx)
	ui_tree_state st
	ui_tree_init(&st)
	int32[2] open
	open[0] = 1
	open[1] = 1

	# A viewport two rows tall over a six-row tree.
	ui_rect small = ui_rect_new(0.0, 0.0, 200.0, 64.0)
	fixture_frame(ctx, &st, &open[0], small)
	assert_equal(6, st.row_count)
	asserts(c"the content is taller than the view", st.scroll.content_h > st.scroll.view_h)
	int verts_two_rows = fx.r.layer_vert_count[UI_LAYER_BASE]

	# The same six rows in a viewport tall enough for all of them must
	# cost strictly more geometry.
	ui_tree_state big_st
	ui_tree_init(&big_st)
	fixture_frame(ctx, &big_st, &open[0], fixture_area())
	int verts_six_rows = fx.r.layer_vert_count[UI_LAYER_BASE]
	asserts(c"showing more rows costs more vertices", verts_six_rows > verts_two_rows)
	ui_render_destroy(&fx.r)


# Down and up move the cursor and clamp at both ends. They act against
# the previous frame's row count, so the first frame establishes it.
void test_down_and_up_move_the_cursor_and_clamp():
	ui_fixture fx
	ui_context* ctx = ui_fixture_init(&fx)
	ui_tree_state st
	ui_tree_init(&st)
	int32[2] open
	open[0] = 0
	open[1] = 0

	# Click to focus the tree, then establish row_count.
	ui_test_click(ctx, 120, 16)
	fixture_frame(ctx, &st, &open[0], fixture_area())
	open[0] = 0
	fixture_frame(ctx, &st, &open[0], fixture_area())
	assert_equal(2, st.row_count)

	ui_test_nav(ctx, GFX_NAV_DOWN)
	fixture_frame(ctx, &st, &open[0], fixture_area())
	assert_equal(1, st.focused)

	# Past the last row it stops rather than wrapping or running off.
	ui_test_nav(ctx, GFX_NAV_DOWN)
	fixture_frame(ctx, &st, &open[0], fixture_area())
	assert_equal(1, st.focused)

	ui_test_nav(ctx, GFX_NAV_UP)
	fixture_frame(ctx, &st, &open[0], fixture_area())
	assert_equal(0, st.focused)

	ui_test_nav(ctx, GFX_NAV_UP)
	fixture_frame(ctx, &st, &open[0], fixture_area())
	assert_equal(0, st.focused)
	ui_render_destroy(&fx.r)


# Right expands the focused folder, and on an already-open one descends
# to its first child. This is the motion that cannot be resolved in
# ui_tree_begin, because the node's `open` pointer only exists partway
# through the caller's walk.
void test_right_expands_then_descends():
	ui_fixture fx
	ui_context* ctx = ui_fixture_init(&fx)
	ui_tree_state st
	ui_tree_init(&st)
	int32[2] open
	open[0] = 0
	open[1] = 0

	ui_test_click(ctx, 120, 16)
	fixture_frame(ctx, &st, &open[0], fixture_area())
	open[0] = 0
	fixture_frame(ctx, &st, &open[0], fixture_area())
	assert_equal(0, st.focused)

	ui_test_nav(ctx, GFX_NAV_RIGHT)
	fixture_frame(ctx, &st, &open[0], fixture_area())
	asserts(c"right expanded the folder", open[0] == 1)
	assert_equal(0, st.focused)

	ui_test_nav(ctx, GFX_NAV_RIGHT)
	fixture_frame(ctx, &st, &open[0], fixture_area())
	asserts(c"it stayed open", open[0] == 1)
	assert_equal(1, st.focused)
	ui_render_destroy(&fx.r)


# Left collapses an open folder, and from a leaf ascends to its exact
# parent — the index parent_of_depth recorded during this very walk,
# not a guess.
void test_left_collapses_then_ascends_to_the_parent():
	ui_fixture fx
	ui_context* ctx = ui_fixture_init(&fx)
	ui_tree_state st
	ui_tree_init(&st)
	int32[2] open
	open[0] = 1
	open[1] = 1

	# Focus docs/readme.md, walk index 4, the row spanning y 128..160.
	ui_test_click(ctx, 120, 144)
	fixture_frame(ctx, &st, &open[0], fixture_area())
	assert_equal(4, st.focused)

	# Its parent is docs/, walk index 3 — not "one row up", which would
	# be index 3 here by luck; the fixture's first folder proves the
	# difference below.
	ui_test_nav(ctx, GFX_NAV_LEFT)
	fixture_frame(ctx, &st, &open[0], fixture_area())
	assert_equal(3, st.focused)

	# Now on the folder itself, left collapses it instead of ascending.
	ui_test_nav(ctx, GFX_NAV_LEFT)
	fixture_frame(ctx, &st, &open[0], fixture_area())
	assert_equal(0, open[1])
	assert_equal(3, st.focused)

	# From the second file of the FIRST folder — walk index 2, parent 0
	# — ascending is a two-row jump, which only an exact parent index
	# gets right.
	ui_test_click(ctx, 120, 80)
	fixture_frame(ctx, &st, &open[0], fixture_area())
	assert_equal(2, st.focused)
	ui_test_nav(ctx, GFX_NAV_LEFT)
	fixture_frame(ctx, &st, &open[0], fixture_area())
	assert_equal(0, st.focused)
	ui_render_destroy(&fx.r)


# Enter activates the focused leaf, reporting it at the same call site a
# click would. Return arrives as a CHAR, not a NAV.
void test_enter_activates_the_focused_leaf():
	ui_fixture fx
	ui_context* ctx = ui_fixture_init(&fx)
	ui_tree_state st
	ui_tree_init(&st)
	int32[2] open
	open[0] = 1
	open[1] = 0

	# Focus src/lib.w, walk index 2.
	ui_test_click(ctx, 120, 80)
	fixture_frame(ctx, &st, &open[0], fixture_area())
	assert_equal(2, st.focused)

	ui_test_char(ctx, 13)
	assert_equal(2, fixture_frame(ctx, &st, &open[0], fixture_area()))

	# And once only.
	assert_equal(0 - 1, fixture_frame(ctx, &st, &open[0], fixture_area()))
	ui_render_destroy(&fx.r)


# Keyboard input belongs to the tree only while it holds focus, so a
# tree in a sidebar does not steal the arrow keys from the editor pane
# next to it.
void test_navigation_is_ignored_without_focus():
	ui_fixture fx
	ui_context* ctx = ui_fixture_init(&fx)
	ui_tree_state st
	ui_tree_init(&st)
	int32[2] open
	open[0] = 1
	open[1] = 0

	fixture_frame(ctx, &st, &open[0], fixture_area())
	assert_equal(0 - 1, st.focused)

	ui_test_nav(ctx, GFX_NAV_DOWN)
	fixture_frame(ctx, &st, &open[0], fixture_area())
	asserts(c"an unfocused tree ignores the arrows", st.focused == 0 - 1)

	ui_test_char(ctx, 13)
	assert_equal(0 - 1, fixture_frame(ctx, &st, &open[0], fixture_area()))
	ui_render_destroy(&fx.r)


# Collapsing a folder takes its children with it, which can leave the
# cursor and the selection pointing past the end of the walk.
void test_the_cursor_survives_the_walk_shrinking_under_it():
	ui_fixture fx
	ui_context* ctx = ui_fixture_init(&fx)
	ui_tree_state st
	ui_tree_init(&st)
	int32[2] open
	open[0] = 1
	open[1] = 1

	# Select the last row, walk index 5.
	ui_test_click(ctx, 120, 176)
	fixture_frame(ctx, &st, &open[0], fixture_area())
	assert_equal(5, st.selected)

	open[0] = 0
	open[1] = 0
	fixture_frame(ctx, &st, &open[0], fixture_area())
	assert_equal(2, st.row_count)
	asserts(c"the selection was pulled back into range", st.selected < st.row_count)
	asserts(c"and so was the cursor", st.focused < st.row_count)
	ui_render_destroy(&fx.r)


# Every row takes an id whether or not it is on screen, so the widgets a
# caller issues after a tree do not shift as the tree scrolls. They do
# still shift when the row count changes; hash ids remain the real fix.
void test_scrolling_does_not_shift_later_widget_ids():
	ui_fixture fx
	ui_context* ctx = ui_fixture_init(&fx)
	int32[2] open
	open[0] = 1
	open[1] = 1
	ui_rect small = ui_rect_new(0.0, 0.0, 200.0, 64.0)

	ui_tree_state top
	ui_tree_init(&top)
	fixture_frame(ctx, &top, &open[0], small)
	int ids_at_top = ctx.next_id

	# Same tree, same viewport, scrolled so a different pair of rows is
	# visible.
	ui_tree_state scrolled
	ui_tree_init(&scrolled)
	fixture_frame(ctx, &scrolled, &open[0], small)
	ui_scroll_to(&scrolled.scroll, 96.0)
	fixture_frame(ctx, &scrolled, &open[0], small)
	int ids_when_scrolled = ctx.next_id

	asserts(c"it really scrolled", scrolled.scroll.offset_y > 0.0)
	assert_equal(ids_at_top, ids_when_scrolled)
	ui_render_destroy(&fx.r)
