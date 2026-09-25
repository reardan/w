# Headless unit tests for the multi-select dropdown: the header summary,
# opening, toggling rows without closing, and the ways it closes
# (docs/projects/ui_widgets.md §6, §9). No GL context or display.
# x64-only: the widget set imports graphics.gl/graphics.window, which
# link libGL/libX11 on the 64-bit Linux targets.
# wbuild: name=graphics_ui_dropdown_multi_test arch_only=x64
import lib.testing
import graphics.event
import graphics.ui.rect
import graphics.ui.theme
import graphics.ui.render
import graphics.ui.widgets
import graphics.ui.testing


char** fruit():
	char** items = cast(char**, malloc(3 * __word_size__))
	items[0] = c"apple"
	items[1] = c"banana"
	items[2] = c"cherry"
	return items


# What one frame did.
struct multi_frame:
	int32 changed
	int32 behind           # clicks that reached the button after it
	int32 ids_used


# One frame: the dropdown at the first row (8, 8, 160, 32), then a
# button that sits under the open list. Open, the surface spans y
# 44..156 (a 4px gap below the header) and its rows, inset by the 8px
# pad, are y 52..84, 84..116 and 116..148 over x 16..160.
void run_frame(ui_context* ctx, char** items, int32* checked, int32* open, multi_frame* out):
	ui_begin(ctx, 320, 240)
	out.changed = ui_dropdown_multi(ctx, 160.0, items, 3, checked, open)
	out.ids_used = ctx.next_id
	out.behind = ui_button(ctx, c"behind")
	ui_end(ctx)


void test_summary_names_the_first_and_counts_the_rest():
	char** items = fruit()
	int32[3] checked
	checked[0] = 0
	checked[1] = 0
	checked[2] = 0
	char[64] out
	assert_equal(0, ui_dropdown_multi_summary(&out[0], 64, items, 3, &checked[0]))
	assert_equal(0, strlen(&out[0]))

	checked[1] = 1
	assert_equal(1, ui_dropdown_multi_summary(&out[0], 64, items, 3, &checked[0]))
	asserts(c"one names it", strcmp(&out[0], c"banana") == 0)

	checked[0] = 1
	checked[2] = 1
	assert_equal(3, ui_dropdown_multi_summary(&out[0], 64, items, 3, &checked[0]))
	asserts(c"first plus the count of the rest", strcmp(&out[0], c"apple +2") == 0)

	# A small buffer truncates rather than overflowing.
	assert_equal(3, ui_dropdown_multi_summary(&out[0], 4, items, 3, &checked[0]))
	asserts(c"truncated to cap", strcmp(&out[0], c"app") == 0)


# Double-digit counts format correctly.
void test_summary_counts_past_nine():
	char** items = cast(char**, malloc(12 * __word_size__))
	int32[12] checked
	for i in range(12):
		items[i] = c"x"
		checked[i] = 1
	char[64] out
	assert_equal(12, ui_dropdown_multi_summary(&out[0], 64, items, 12, &checked[0]))
	asserts(c"x +11", strcmp(&out[0], c"x +11") == 0)


# Clicking the header opens the list on the popup layer; the opening
# click's press does not close it again on the same frame.
void test_header_click_opens():
	ui_fixture fx
	ui_context* ctx = ui_fixture_init(&fx)
	char** items = fruit()
	int32[3] checked
	checked[0] = 0
	checked[1] = 0
	checked[2] = 0
	int32 open = 0
	multi_frame f

	run_frame(ctx, items, &checked[0], &open, &f)
	assert_equal(0, open)
	assert_equal(0, fx.r.layer_vert_count[UI_LAYER_POPUP])

	ui_test_click(ctx, 20, 20)
	run_frame(ctx, items, &checked[0], &open, &f)
	assert_equal(1, open)
	assert_equal(0, f.changed)
	assert_equal(1, ctx.popup_depth)
	asserts(c"the list drew on the popup layer", fx.r.layer_vert_count[UI_LAYER_POPUP] > 0)
	ui_render_destroy(&fx.r)


# Rows toggle and the list stays open; each toggle is a change frame,
# and the press never reaches the button underneath.
void test_rows_toggle_and_stay_open():
	ui_fixture fx
	ui_context* ctx = ui_fixture_init(&fx)
	char** items = fruit()
	int32[3] checked
	checked[0] = 0
	checked[1] = 0
	checked[2] = 0
	int32 open = 1
	multi_frame f

	run_frame(ctx, items, &checked[0], &open, &f)
	ui_test_click(ctx, 40, 60)
	run_frame(ctx, items, &checked[0], &open, &f)
	assert_equal(1, f.changed)
	assert_equal(1, checked[0])
	assert_equal(1, open)
	assert_equal(0, f.behind)

	ui_test_click(ctx, 40, 130)
	run_frame(ctx, items, &checked[0], &open, &f)
	assert_equal(1, f.changed)
	assert_equal(1, checked[2])
	assert_equal(1, open)

	# The change edge is one frame.
	run_frame(ctx, items, &checked[0], &open, &f)
	assert_equal(0, f.changed)

	# Pressing a checked row unchecks it.
	ui_test_click(ctx, 40, 60)
	run_frame(ctx, items, &checked[0], &open, &f)
	assert_equal(1, f.changed)
	assert_equal(0, checked[0])
	assert_equal(0, checked[1])
	assert_equal(1, checked[2])
	assert_equal(1, ctx.popup_depth)

	# A press on the surface's padding, between no rows, changes nothing.
	ui_test_click(ctx, 40, 150)
	run_frame(ctx, items, &checked[0], &open, &f)
	assert_equal(0, f.changed)
	assert_equal(1, open)
	ui_render_destroy(&fx.r)


# A press outside closes without changing anything, and is consumed.
void test_press_outside_closes():
	ui_fixture fx
	ui_context* ctx = ui_fixture_init(&fx)
	char** items = fruit()
	int32[3] checked
	checked[0] = 1
	checked[1] = 0
	checked[2] = 0
	int32 open = 1
	multi_frame f

	run_frame(ctx, items, &checked[0], &open, &f)
	ui_test_click(ctx, 300, 220)
	run_frame(ctx, items, &checked[0], &open, &f)
	assert_equal(0, open)
	assert_equal(0, f.changed)
	assert_equal(1, checked[0])
	assert_equal(0, ctx.popup_depth)
	ui_render_destroy(&fx.r)


# Pressing the header again closes it (the header lies outside the
# surface), rather than reopening.
void test_header_press_closes():
	ui_fixture fx
	ui_context* ctx = ui_fixture_init(&fx)
	char** items = fruit()
	int32[3] checked
	checked[0] = 0
	checked[1] = 0
	checked[2] = 0
	int32 open = 0
	multi_frame f

	ui_test_click(ctx, 20, 20)
	run_frame(ctx, items, &checked[0], &open, &f)
	assert_equal(1, open)
	ui_test_click(ctx, 20, 20)
	run_frame(ctx, items, &checked[0], &open, &f)
	assert_equal(0, open)
	run_frame(ctx, items, &checked[0], &open, &f)
	assert_equal(0, open)
	assert_equal(0, ctx.popup_depth)
	ui_render_destroy(&fx.r)


void test_escape_closes():
	ui_fixture fx
	ui_context* ctx = ui_fixture_init(&fx)
	char** items = fruit()
	int32[3] checked
	checked[0] = 0
	checked[1] = 0
	checked[2] = 0
	int32 open = 1
	multi_frame f

	run_frame(ctx, items, &checked[0], &open, &f)
	ui_test_char(ctx, 27)
	run_frame(ctx, items, &checked[0], &open, &f)
	assert_equal(0, open)
	assert_equal(0, ctx.popup_depth)
	ui_render_destroy(&fx.r)


# Open or closed, the widget takes one id and leaves scope, layer and
# layout depth where it found them.
void test_ids_and_bracket_are_stable():
	ui_fixture fx
	ui_context* ctx = ui_fixture_init(&fx)
	char** items = fruit()
	int32[3] checked
	checked[0] = 0
	checked[1] = 1
	checked[2] = 0
	int32 open = 0
	multi_frame f

	run_frame(ctx, items, &checked[0], &open, &f)
	int closed_ids = f.ids_used
	open = 1
	run_frame(ctx, items, &checked[0], &open, &f)
	assert_equal(closed_ids, f.ids_used)
	assert_equal(2, closed_ids)
	assert_equal(1, ctx.layout_depth)
	assert_equal(0, ctx.scope)
	assert_equal(0, ctx.bracket_depth)
	assert_equal(UI_LAYER_BASE, fx.r.layer)
	ui_render_destroy(&fx.r)
