# Headless unit tests for the table: row virtualization, the sticky
# header, selection, and cells clipped to their columns
# (docs/projects/ui_widgets.md §5). No GL context or display.
# x64-only: the widget set imports graphics.gl/graphics.window, which
# link libGL/libX11 on the 64-bit Linux targets.
# wbuild: name=graphics_ui_table_test arch_only=x64
import lib.testing
import graphics.event
import graphics.ui.rect
import graphics.ui.theme
import graphics.ui.render
import graphics.ui.widgets
import graphics.ui.testing


char** make_headers():
	char** h = cast(char**, malloc(2 * __word_size__))
	h[0] = c"name"
	h[1] = c"size"
	return h


# One frame of a table with row_count rows; returns how many rows were
# issued (i.e. reported visible) through drawn.
int table_frame(ui_context* ctx, ui_rect area, ui_table_state* st, int row_count, int32* drawn):
	char** headers = make_headers()
	int32[2] widths
	widths[0] = 120
	widths[1] = 60
	drawn[0] = 0
	ui_begin(ctx, 320, 240)
	ui_table_begin(ctx, area, headers, &widths[0], 2, st)
	int row = 0
	while (row < row_count):
		if (ui_table_row(ctx, st, row)):
			drawn[0] = drawn[0] + 1
			ui_table_cell(ctx, st, c"alpha")
			ui_table_cell(ctx, st, c"12")
		row = row + 1
	int picked = ui_table_end(ctx, st)
	ui_end(ctx)
	free(cast(char*, headers))
	return picked


void test_only_visible_rows_are_issued():
	ui_fixture fx
	ui_context* ctx = ui_fixture_init(&fx)
	ui_table_state st
	ui_table_init(&st)
	# A body about four rows tall, holding 500.
	ui_rect area = ui_rect_new(10.0, 10.0, 200.0, 32.0 + 1.0 + 4.0 * 32.0)
	int32 drawn = 0
	table_frame(ctx, area, &st, 500, &drawn)

	# Virtualization is the point: a 500-row table costs the rows on
	# screen, not 500 rows' worth of anything.
	asserts(c"some rows drew", drawn > 0)
	asserts(c"not all rows drew", drawn < 12)
	# ...but the scroll region still knows how tall the whole table is.
	asserts(c"full height measured", st.scroll.content_h >= 500.0 * 32.0)
	assert_equal(1, ui_scroll_overflows(&st.scroll))
	ui_render_destroy(&fx.r)


void test_short_table_draws_every_row_and_does_not_scroll():
	ui_fixture fx
	ui_context* ctx = ui_fixture_init(&fx)
	ui_table_state st
	ui_table_init(&st)
	ui_rect area = ui_rect_new(10.0, 10.0, 200.0, 200.0)
	int32 drawn = 0
	table_frame(ctx, area, &st, 3, &drawn)
	assert_equal(3, drawn)
	assert_equal(0, ui_scroll_overflows(&st.scroll))
	ui_render_destroy(&fx.r)


void test_header_stays_put_while_the_body_scrolls():
	ui_fixture fx
	ui_context* ctx = ui_fixture_init(&fx)
	ui_table_state st
	ui_table_init(&st)
	ui_rect area = ui_rect_new(10.0, 10.0, 200.0, 129.0)
	int32 drawn = 0
	table_frame(ctx, area, &st, 200, &drawn)

	# The header is drawn outside the body's clip, so scrolling the
	# body cannot move or erase it: the first header vertex is at the
	# table's own top-left, before and after.
	float32 header_y = fx.r.layer_verts[UI_LAYER_BASE][1]
	ui_test_wheel(ctx, 0 - 3, 60, 60)
	table_frame(ctx, area, &st, 200, &drawn)
	asserts(c"body scrolled", st.scroll.offset_y > 0.0)
	asserts(c"header did not move", fx.r.layer_verts[UI_LAYER_BASE][1] == header_y)
	ui_render_destroy(&fx.r)


void test_scrolling_changes_which_rows_are_issued():
	ui_fixture fx
	ui_context* ctx = ui_fixture_init(&fx)
	ui_table_state st
	ui_table_init(&st)
	ui_rect area = ui_rect_new(10.0, 10.0, 200.0, 129.0)
	int32 drawn = 0
	table_frame(ctx, area, &st, 200, &drawn)
	int at_top = drawn

	# Scrolled to the bottom, a different — but comparable — set of
	# rows is issued.
	ui_scroll_to(&st.scroll, ui_scroll_max(&st.scroll))
	table_frame(ctx, area, &st, 200, &drawn)
	asserts(c"still a windowful", drawn > 0)
	asserts(c"comparable count", drawn <= at_top + 1)
	ui_render_destroy(&fx.r)


void test_row_click_selects():
	ui_fixture fx
	ui_context* ctx = ui_fixture_init(&fx)
	ui_table_state st
	ui_table_init(&st)
	ui_rect area = ui_rect_new(10.0, 10.0, 200.0, 200.0)
	int32 drawn = 0
	assert_equal(0 - 1, st.selected)

	# Row 1 sits one row below the header and its separator.
	table_frame(ctx, area, &st, 5, &drawn)
	ui_test_click(ctx, 60, 10 + 32 + 1 + 32 + 4)
	int picked = table_frame(ctx, area, &st, 5, &drawn)
	assert_equal(1, st.selected)
	assert_equal(1, picked)

	# Clicking the same row again is not a change.
	ui_test_click(ctx, 60, 10 + 32 + 1 + 32 + 4)
	picked = table_frame(ctx, area, &st, 5, &drawn)
	assert_equal(0 - 1, picked)
	assert_equal(1, st.selected)

	# A different row is.
	ui_test_click(ctx, 60, 10 + 32 + 1 + 4)
	picked = table_frame(ctx, area, &st, 5, &drawn)
	assert_equal(0, picked)
	assert_equal(0, st.selected)
	ui_render_destroy(&fx.r)


void test_cells_are_clipped_to_their_column():
	ui_fixture fx
	ui_context* ctx = ui_fixture_init(&fx)
	ui_table_state st
	ui_table_init(&st)
	ui_rect area = ui_rect_new(0.0, 0.0, 200.0, 200.0)
	char** headers = make_headers()
	int32[2] widths
	widths[0] = 40
	widths[1] = 40

	ui_begin(ctx, 320, 240)
	ui_table_begin(ctx, area, headers, &widths[0], 2, &st)
	ui_table_row(ctx, &st, 0)
	int before = fx.r.layer_vert_count[UI_LAYER_BASE]
	# A value far wider than its 40px column: the glyphs past the
	# column edge are clipped, so it cannot spill into the next one.
	ui_table_cell(ctx, &st, c"a value far too long for this column")
	int wide = fx.r.layer_vert_count[UI_LAYER_BASE] - before
	asserts(c"some glyphs drew", wide > 0)
	# Every vertex of the cell is inside the column.
	int i = before
	while (i < fx.r.layer_vert_count[UI_LAYER_BASE]):
		asserts(c"glyph inside column", fx.r.layer_verts[UI_LAYER_BASE][i * 8] <= 40.0)
		i = i + 1
	# A cell past the declared column count draws nothing at all.
	int filled = fx.r.layer_vert_count[UI_LAYER_BASE]
	ui_table_cell(ctx, &st, c"second")
	ui_table_cell(ctx, &st, c"third")
	int after_third = fx.r.layer_vert_count[UI_LAYER_BASE]
	ui_table_cell(ctx, &st, c"fourth")
	assert_equal(after_third, fx.r.layer_vert_count[UI_LAYER_BASE])
	asserts(c"second column drew", after_third > filled)
	ui_table_end(ctx, &st)
	ui_end(ctx)
	free(cast(char*, headers))
	ui_render_destroy(&fx.r)
