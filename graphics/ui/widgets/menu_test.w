# Headless unit tests for the context menu: right-click opening, item
# choice closing the menu, disabled items, and the popup scope it
# inherits from the popover (docs/projects/ui_widgets.md §9).
# No GL context or display.
# x64-only: the widget set imports graphics.gl/graphics.window, which
# link libGL/libX11 on the 64-bit Linux targets.
# wbuild: name=graphics_ui_menu_test arch_only=x64
import lib.testing
import graphics.event
import graphics.ui.rect
import graphics.ui.theme
import graphics.ui.render
import graphics.ui.widgets
import graphics.ui.testing


# A right-click: a bare press edge, no release — nothing drags with it.
void feed_right_click(ui_context* ctx, int x, int y):
	ui_test_event(ctx, GFX_EVENT_MOUSE_DOWN, 3, x, y, 0)


# The area the menu belongs to: the left half of the window, so a
# right-click on the right half is genuinely outside it.
ui_rect menu_area():
	return ui_rect_new(0.0, 0.0, 160.0, 240.0)


# One frame: an area that owns a three-item menu, with a background
# button behind it. `chosen` records the item index picked this frame.
void menu_frame(ui_context* ctx, ui_menu_state* st, int32* chosen, int32* bg, int enable_second):
	chosen[0] = 0 - 1
	ui_begin(ctx, 320, 240)
	if (ui_button(ctx, c"behind")):
		bg[0] = bg[0] + 1
	ui_menu_open_on_right_click(ctx, menu_area(), st)
	if (ui_menu_begin(ctx, st)):
		if (ui_menu_item(ctx, st, c"New File", 1)):
			chosen[0] = 0
		if (ui_menu_item(ctx, st, c"Rename", enable_second)):
			chosen[0] = 1
		ui_menu_separator(ctx, st)
		if (ui_menu_item(ctx, st, c"Delete", 1)):
			chosen[0] = 2
		ui_menu_end(ctx, st)
	ui_end(ctx)


# A right-click inside the area pins the menu at the pointer; one
# outside leaves it closed.
void test_right_click_inside_the_area_opens_the_menu_at_the_pointer():
	ui_fixture fx
	ui_context* ctx = ui_fixture_init(&fx)
	ui_menu_state st
	ui_menu_init(&st, 140.0)
	int32 chosen
	int32 bg
	bg = 0

	menu_frame(ctx, &st, &chosen, &bg, 1)
	assert_equal(0, st.open)

	feed_right_click(ctx, 40, 90)
	menu_frame(ctx, &st, &chosen, &bg, 1)
	assert_equal(1, st.open)
	asserts(c"pinned at the pointer", st.at_x == 40.0)
	asserts(c"pinned at the pointer", st.at_y == 90.0)
	asserts(c"and it drew on the popup layer", fx.r.layer_vert_count[UI_LAYER_POPUP] > 0)
	ui_render_destroy(&fx.r)


void test_right_click_outside_the_area_does_not_open_it():
	ui_fixture fx
	ui_context* ctx = ui_fixture_init(&fx)
	ui_menu_state st
	ui_menu_init(&st, 140.0)
	int32 chosen
	int32 bg
	bg = 0

	feed_right_click(ctx, 240, 90)
	menu_frame(ctx, &st, &chosen, &bg, 1)
	assert_equal(0, st.open)
	assert_equal(0, ctx.popup_depth)
	ui_render_destroy(&fx.r)


# The right-click edge is consumed by whoever opens a menu on it, so two
# overlapping areas cannot both open one from a single click.
void test_the_right_click_edge_is_consumed():
	ui_fixture fx
	ui_context* ctx = ui_fixture_init(&fx)
	ui_menu_state first
	ui_menu_state second
	ui_menu_init(&first, 140.0)
	ui_menu_init(&second, 140.0)

	feed_right_click(ctx, 40, 90)
	ui_begin(ctx, 320, 240)
	ui_menu_open_on_right_click(ctx, menu_area(), &first)
	ui_menu_open_on_right_click(ctx, menu_area(), &second)
	ui_end(ctx)

	assert_equal(1, first.open)
	assert_equal(0, second.open)
	ui_render_destroy(&fx.r)


# Choosing an item reports it once and closes the menu — a context menu
# never survives its own action.
void test_choosing_an_item_reports_it_once_and_closes():
	ui_fixture fx
	ui_context* ctx = ui_fixture_init(&fx)
	ui_menu_state st
	ui_menu_init(&st, 140.0)
	int32 chosen
	int32 bg
	bg = 0

	feed_right_click(ctx, 40, 40)
	menu_frame(ctx, &st, &chosen, &bg, 1)
	assert_equal(1, st.open)

	# The surface sits just below the pin, inset by a pad; the first item
	# starts there. Click the middle of it.
	int item_y = cast(int, 40.0 + ui_popover_gap() + cast(float32, ctx.theme.pad) + ui_menu_item_height() * 0.5)
	ui_test_click(ctx, 60, item_y)
	menu_frame(ctx, &st, &chosen, &bg, 1)
	assert_equal(0, chosen)
	assert_equal(0, st.open)

	# Closed, unregistered, and reporting nothing on the next frame.
	menu_frame(ctx, &st, &chosen, &bg, 1)
	assert_equal(0 - 1, chosen)
	assert_equal(0, ctx.popup_depth)
	ui_render_destroy(&fx.r)


# A disabled item ignores the click and leaves the menu open, rather
# than closing as if something had happened.
void test_a_disabled_item_does_nothing():
	ui_fixture fx
	ui_context* ctx = ui_fixture_init(&fx)
	ui_menu_state st
	ui_menu_init(&st, 140.0)
	int32 chosen
	int32 bg
	bg = 0

	feed_right_click(ctx, 40, 40)
	menu_frame(ctx, &st, &chosen, &bg, 0)

	# The second item, one row down from the first.
	int item_y = cast(int, 40.0 + ui_popover_gap() + cast(float32, ctx.theme.pad) + ui_menu_item_height() * 1.5)
	ui_test_click(ctx, 60, item_y)
	menu_frame(ctx, &st, &chosen, &bg, 0)
	assert_equal(0 - 1, chosen)
	assert_equal(1, st.open)
	ui_render_destroy(&fx.r)


# Escape closes it, and so does a click on the page outside the surface
# — which is also consumed, so the button behind does not fire.
void test_escape_and_an_outside_click_both_close_it():
	ui_fixture fx
	ui_context* ctx = ui_fixture_init(&fx)
	ui_menu_state st
	ui_menu_init(&st, 140.0)
	int32 chosen
	int32 bg
	bg = 0

	feed_right_click(ctx, 40, 90)
	menu_frame(ctx, &st, &chosen, &bg, 1)
	ui_test_char(ctx, 27)
	menu_frame(ctx, &st, &chosen, &bg, 1)
	assert_equal(0, st.open)

	feed_right_click(ctx, 40, 90)
	menu_frame(ctx, &st, &chosen, &bg, 1)
	ui_test_click(ctx, 20, 20)
	menu_frame(ctx, &st, &chosen, &bg, 1)
	assert_equal(0, st.open)
	asserts(c"the closing click did not also press the button", bg == 0)
	ui_render_destroy(&fx.r)


# Opening and closing leaves the layout and popup brackets exactly where
# they were, whatever path the menu took to close.
void test_the_bracket_balances():
	ui_fixture fx
	ui_context* ctx = ui_fixture_init(&fx)
	ui_menu_state st
	ui_menu_init(&st, 140.0)
	int32 chosen
	int32 bg
	bg = 0

	menu_frame(ctx, &st, &chosen, &bg, 1)
	int depth_closed = ctx.layout_depth

	feed_right_click(ctx, 40, 40)
	menu_frame(ctx, &st, &chosen, &bg, 1)
	assert_equal(depth_closed, ctx.layout_depth)
	assert_equal(0, ctx.bracket_depth)
	assert_equal(UI_LAYER_BASE, fx.r.layer)

	# And through the choose-an-item path, which closes mid-bracket.
	int item_y = cast(int, 40.0 + ui_popover_gap() + cast(float32, ctx.theme.pad) + ui_menu_item_height() * 0.5)
	ui_test_click(ctx, 60, item_y)
	menu_frame(ctx, &st, &chosen, &bg, 1)
	assert_equal(depth_closed, ctx.layout_depth)
	assert_equal(0, ctx.bracket_depth)
	assert_equal(UI_LAYER_BASE, fx.r.layer)
	ui_render_destroy(&fx.r)
