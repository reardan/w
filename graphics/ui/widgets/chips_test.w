# Headless unit tests for chips: wrapping onto a new row at the area's
# edge, filter toggles, removing without toggling, the disabled scope,
# and ids that do not shift (docs/projects/ui_widgets.md §2, §6).
# No GL context or display.
# x64-only: the widget set imports graphics.gl/graphics.window, which
# link libGL/libX11 on the 64-bit Linux targets.
# wbuild: name=graphics_ui_chips_test arch_only=x64
import lib.testing
import graphics.event
import graphics.ui.rect
import graphics.ui.theme
import graphics.ui.render
import graphics.ui.widgets
import graphics.ui.testing


# What one frame of the test row reported.
struct chips_frame_out:
	int32 rust_toggled
	int32 go_toggled
	int32 python_removed
	int32 ids_used


# Two filter chips and a removable chip that is also selectable, at
# (10, 10) across width w. Theme metrics: pad 8, gap 8, chips 32 tall.
void chips_frame(ui_context* ctx, ui_chips_state* st, float32 w, int32* sel, chips_frame_out* out):
	ui_begin(ctx, 640, 480)
	int first = ctx.next_id
	ui_chips_begin(ctx, st, ui_rect_new(10.0, 10.0, w, 0.0))
	out.rust_toggled = ui_chip(ctx, st, c"Rust", &sel[0])
	out.go_toggled = ui_chip(ctx, st, c"Go", &sel[1])
	out.python_removed = ui_chip_removable(ctx, st, c"Python", &sel[2])
	ui_chips_end(ctx, st)
	out.ids_used = ctx.next_id - first
	ui_end(ctx)


float32 rust_w(ui_context* ctx):
	return ui_chip_width(ctx, c"Rust", 1, 0)


float32 go_w(ui_context* ctx):
	return ui_chip_width(ctx, c"Go", 1, 0)


float32 python_w(ui_context* ctx):
	return ui_chip_width(ctx, c"Python", 1, 1)


float32 wide():
	return 600.0


# Chips flow along one row while they fit, and the chip that would
# cross the area's right edge starts the next row at the left edge.
void test_chips_wrap_at_the_region_edge():
	ui_fixture fx
	ui_context* ctx = ui_fixture_init(&fx)
	ui_chips_state st
	ui_chips_init(&st)
	int32[3] sel
	sel[0] = 0
	sel[1] = 0
	sel[2] = 0
	chips_frame_out out

	chips_frame(ctx, &st, wide(), &sel[0], &out)
	assert_equal(1, st.rows)
	assert_equal(32, cast(int, st.height))

	# Room for Rust and Go, one pixel short of Python.
	float32 gap = cast(float32, fx.theme.gap)
	float32 w = rust_w(ctx) + gap + go_w(ctx) + gap + python_w(ctx) - 1.0
	chips_frame(ctx, &st, w, &sel[0], &out)
	assert_equal(2, st.rows)
	assert_equal(32 + 8 + 32, cast(int, st.height))
	asserts(c"the first row is as wide as its two chips", st.content_w == rust_w(ctx) + gap + go_w(ctx))

	# Python now sits at the left edge of the second row: clicking where
	# it would be on the first row does nothing, clicking the start of
	# row two toggles it.
	int row1_y = 10 + 16
	int row2_y = 10 + 40 + 16
	ui_test_click(ctx, cast(int, 10.0 + rust_w(ctx) + gap + go_w(ctx) + gap + 10.0), row1_y)
	chips_frame(ctx, &st, w, &sel[0], &out)
	assert_equal(0, sel[2])
	ui_test_click(ctx, 20, row2_y)
	chips_frame(ctx, &st, w, &sel[0], &out)
	assert_equal(1, sel[2])
	assert_equal(0, sel[0])
	ui_render_destroy(&fx.r)


# The walk claims the rows it covered on the enclosing region, so a
# scroll viewport around a chip row sizes its bar correctly.
void test_chips_claim_their_extent():
	ui_fixture fx
	ui_context* ctx = ui_fixture_init(&fx)
	ui_chips_state st
	ui_chips_init(&st)
	int32[3] sel
	sel[0] = 0
	sel[1] = 0
	sel[2] = 0

	ui_begin(ctx, 640, 480)
	ui_region_push(ctx, ui_rect_new(10.0, 10.0, 90.0, 400.0))
	ui_chips_begin(ctx, &st, ui_rect_new(10.0, 10.0, 90.0, 0.0))
	ui_chip(ctx, &st, c"Rust", &sel[0])
	ui_chip(ctx, &st, c"Go", &sel[1])
	ui_chip_removable(ctx, &st, c"Python", &sel[2])
	ui_chips_end(ctx, &st)
	ui_rect content = ui_region_content(ctx)
	ui_region_pop(ctx)
	ui_end(ctx)

	asserts(c"narrow enough to take several rows", st.rows >= 2)
	asserts(c"the region measured the rows", content.h == st.height)
	asserts(c"and no wider than the area", content.w <= 90.0)
	ui_render_destroy(&fx.r)


# A chip wider than the whole area takes a row of its own, capped at
# the area's width, rather than leaving an empty row above it.
void test_an_over_wide_chip_is_capped_without_an_empty_row():
	ui_fixture fx
	ui_context* ctx = ui_fixture_init(&fx)
	ui_chips_state st
	ui_chips_init(&st)
	int32 on
	on = 0

	ui_begin(ctx, 640, 480)
	ui_chips_begin(ctx, &st, ui_rect_new(0.0, 0.0, 40.0, 0.0))
	ui_chip(ctx, &st, c"an-extremely-long-filter-name", &on)
	ui_chips_end(ctx, &st)
	ui_end(ctx)
	assert_equal(1, st.rows)
	asserts(c"capped at the area", st.content_w == 40.0)
	ui_render_destroy(&fx.r)


# A click flips the chip's flag and reports the edge on that frame only;
# a second click flips it back.
void test_toggle_reports_once_and_flips():
	ui_fixture fx
	ui_context* ctx = ui_fixture_init(&fx)
	ui_chips_state st
	ui_chips_init(&st)
	int32[3] sel
	sel[0] = 0
	sel[1] = 0
	sel[2] = 0
	chips_frame_out out

	chips_frame(ctx, &st, wide(), &sel[0], &out)
	int go_x = cast(int, 10.0 + rust_w(ctx) + cast(float32, fx.theme.gap) + 6.0)
	ui_test_click(ctx, go_x, 26)
	chips_frame(ctx, &st, wide(), &sel[0], &out)
	assert_equal(1, out.go_toggled)
	assert_equal(0, out.rust_toggled)
	assert_equal(1, sel[1])
	assert_equal(0, sel[0])

	chips_frame(ctx, &st, wide(), &sel[0], &out)
	assert_equal(0, out.go_toggled)
	assert_equal(1, sel[1])

	ui_test_click(ctx, go_x, 26)
	chips_frame(ctx, &st, wide(), &sel[0], &out)
	assert_equal(1, out.go_toggled)
	assert_equal(0, sel[1])
	ui_render_destroy(&fx.r)


# The cross consumes the click: removing reports 1 and leaves the chip's
# selection alone, whether the press and release share a frame or not.
# Clicking the body of the same chip toggles it and removes nothing.
void test_remove_click_does_not_toggle():
	ui_fixture fx
	ui_context* ctx = ui_fixture_init(&fx)
	ui_chips_state st
	ui_chips_init(&st)
	int32[3] sel
	sel[0] = 0
	sel[1] = 0
	sel[2] = 0
	chips_frame_out out

	chips_frame(ctx, &st, wide(), &sel[0], &out)
	float32 gap = cast(float32, fx.theme.gap)
	float32 py_x = 10.0 + rust_w(ctx) + gap + go_w(ctx) + gap
	# The cross's centre: a pad in from the right edge, half a mark more.
	int cross_x = cast(int, py_x + python_w(ctx) - cast(float32, fx.theme.pad) - ui_chip_mark_size() * 0.5)

	ui_test_click(ctx, cross_x, 26)
	chips_frame(ctx, &st, wide(), &sel[0], &out)
	assert_equal(1, out.python_removed)
	assert_equal(0, sel[2])
	chips_frame(ctx, &st, wide(), &sel[0], &out)
	assert_equal(0, out.python_removed)

	# Press on one frame, release on the next.
	ui_test_event(ctx, GFX_EVENT_MOUSE_DOWN, 1, cross_x, 26, 0)
	chips_frame(ctx, &st, wide(), &sel[0], &out)
	assert_equal(0, out.python_removed)
	ui_test_event(ctx, GFX_EVENT_MOUSE_UP, 1, cross_x, 26, 0)
	chips_frame(ctx, &st, wide(), &sel[0], &out)
	assert_equal(1, out.python_removed)
	assert_equal(0, sel[2])

	# The body still toggles.
	ui_test_click(ctx, cast(int, py_x) + 12, 26)
	chips_frame(ctx, &st, wide(), &sel[0], &out)
	assert_equal(0, out.python_removed)
	assert_equal(1, sel[2])
	ui_render_destroy(&fx.r)


# Inside a ui_disable scope chips draw but ignore clicks on the body
# and on the cross.
void test_disabled_chips_are_inert():
	ui_fixture fx
	ui_context* ctx = ui_fixture_init(&fx)
	ui_chips_state st
	ui_chips_init(&st)
	int32[3] sel
	sel[0] = 1
	sel[1] = 0
	sel[2] = 0
	chips_frame_out out

	ui_disable(ctx, 1)
	chips_frame(ctx, &st, wide(), &sel[0], &out)
	float32 gap = cast(float32, fx.theme.gap)
	float32 py_x = 10.0 + rust_w(ctx) + gap + go_w(ctx) + gap
	int cross_x = cast(int, py_x + python_w(ctx) - cast(float32, fx.theme.pad) - ui_chip_mark_size() * 0.5)

	ui_test_click(ctx, 20, 26)
	chips_frame(ctx, &st, wide(), &sel[0], &out)
	assert_equal(0, out.rust_toggled)
	assert_equal(1, sel[0])

	ui_test_click(ctx, cross_x, 26)
	chips_frame(ctx, &st, wide(), &sel[0], &out)
	assert_equal(0, out.python_removed)
	assert_equal(0, sel[2])
	ui_disable(ctx, 0)

	ui_test_click(ctx, 20, 26)
	chips_frame(ctx, &st, wide(), &sel[0], &out)
	assert_equal(1, out.rust_toggled)
	assert_equal(0, sel[0])
	ui_render_destroy(&fx.r)


# Every chip takes two ids however it is laid out, selected or not,
# removable or not — so nothing issued after the row shifts.
void test_ids_are_stable():
	ui_fixture fx
	ui_context* ctx = ui_fixture_init(&fx)
	ui_chips_state st
	ui_chips_init(&st)
	int32[3] sel
	sel[0] = 0
	sel[1] = 0
	sel[2] = 0
	chips_frame_out out

	chips_frame(ctx, &st, wide(), &sel[0], &out)
	assert_equal(6, out.ids_used)

	sel[0] = 1
	sel[2] = 1
	chips_frame(ctx, &st, 60.0, &sel[0], &out)
	asserts(c"narrow area wraps every chip", st.rows == 3)
	assert_equal(6, out.ids_used)

	ui_disable(ctx, 1)
	chips_frame(ctx, &st, wide(), &sel[0], &out)
	assert_equal(6, out.ids_used)
	ui_disable(ctx, 0)

	# A plain removable chip with no selection takes the same two.
	ui_begin(ctx, 640, 480)
	int first = ctx.next_id
	ui_chips_begin(ctx, &st, ui_rect_new(0.0, 0.0, 200.0, 0.0))
	ui_chip_removable(ctx, &st, c"tag", 0)
	ui_chips_end(ctx, &st)
	assert_equal(2, ctx.next_id - first)
	ui_end(ctx)
	ui_render_destroy(&fx.r)
