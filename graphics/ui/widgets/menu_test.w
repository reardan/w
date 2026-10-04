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
	if (ui_button(ctx, c"behind")): bg[0] = bg[0] + 1
	ui_menu_open_on_right_click(ctx, menu_area(), st)
	if (ui_menu_begin(ctx, st)):
		if (ui_menu_item(ctx, st, c"New File", 1)): chosen[0] = 0
		if (ui_menu_item(ctx, st, c"Rename", enable_second)): chosen[0] = 1
		ui_menu_separator(ctx, st)
		if (ui_menu_item(ctx, st, c"Delete", 1)): chosen[0] = 2
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


# ---- round 5: submenus, checks, keyboard, shortcuts (§12) -----------------

# A richer menu: a check item, a submenu of radio items, a separator, a
# disabled item, and a plain item with an explicit mnemonic.
struct rich_state:
	int32 chosen           # 0 Copy, 1 Delete, -1 none
	int32 wrap
	int32 sort


void rich_frame(ui_context* ctx, ui_menu_state* st, rich_state* rs):
	rs.chosen = 0 - 1
	ui_begin(ctx, 480, 320)
	if (ui_menu_begin(ctx, st)):
		if (ui_menu_item_key(ctx, st, c"&Copy", GFX_MOD_CTRL, 'c', 1)): rs.chosen = 0
		ui_menu_check(ctx, st, c"&Wrap", &rs.wrap, 1)
		if (ui_menu_begin_sub(ctx, st, c"S&ort", 1)):
			ui_menu_radio(ctx, st, c"&Name", &rs.sort, 0, 1)
			ui_menu_radio(ctx, st, c"&Size", &rs.sort, 1, 1)
			ui_menu_end_sub(ctx, st)
		ui_menu_separator(ctx, st)
		ui_menu_item(ctx, st, c"Paste", 0)
		if (ui_menu_item(ctx, st, c"&Delete", 1)): rs.chosen = 1
		ui_menu_end(ctx, st)
	ui_end(ctx)


void rich_init(rich_state* rs):
	rs.chosen = 0 - 1
	rs.wrap = 0
	rs.sort = 0


# The middle of item `index` on `level`, from where the last frame put
# that level's surface.
int item_x(ui_context* ctx, ui_menu_state* st, int level):
	return cast(int, st.surface[level].x + 30.0)


int item_y(ui_context* ctx, ui_menu_state* st, int level, int index):
	return cast(int, st.surface[level].y + cast(float32, ctx.theme.pad) + ui_menu_item_height() * (cast(float32, index) + 0.5))


void point_at(ui_context* ctx, int x, int y):
	ctx.input.mouse_x = x
	ctx.input.mouse_y = y


# Hovering a submenu item opens its submenu beside the menu; both levels
# take input at once, and choosing in the submenu closes the whole chain.
void test_hovering_a_submenu_item_opens_it_beside_the_menu():
	ui_fixture fx
	ui_context* ctx = ui_fixture_init(&fx)
	ui_menu_state st
	ui_menu_init(&st, 140.0)
	rich_state rs
	rich_init(&rs)
	ui_menu_open_at(&st, 40.0, 40.0, 0)
	rich_frame(ctx, &st, &rs)

	point_at(ctx, item_x(ctx, &st, 0), item_y(ctx, &st, 0, 2))
	rich_frame(ctx, &st, &rs)
	assert_equal(2, st.sub[0])
	assert_equal(1, st.live[1])
	asserts(c"the submenu opens to the right of its parent", st.surface[1].x >= st.surface[0].x + st.surface[0].w)
	asserts(c"level with the item that opened it", st.surface[1].y < cast(float32, item_y(ctx, &st, 0, 2)))
	assert_equal(1, ctx.popup_depth)

	# Choose "Size" in the submenu.
	ui_test_click(ctx, item_x(ctx, &st, 1), item_y(ctx, &st, 1, 1))
	rich_frame(ctx, &st, &rs)
	assert_equal(1, rs.sort)
	assert_equal(0, st.open)
	rich_frame(ctx, &st, &rs)
	assert_equal(0, ctx.popup_depth)
	assert_equal(0, ctx.bracket_depth)
	assert_equal(UI_LAYER_BASE, fx.r.layer)
	ui_render_destroy(&fx.r)


# Moving back onto a plain item of the parent closes the submenu.
void test_moving_back_to_the_parent_closes_the_submenu():
	ui_fixture fx
	ui_context* ctx = ui_fixture_init(&fx)
	ui_menu_state st
	ui_menu_init(&st, 140.0)
	rich_state rs
	rich_init(&rs)
	ui_menu_open_at(&st, 40.0, 40.0, 0)
	rich_frame(ctx, &st, &rs)
	point_at(ctx, item_x(ctx, &st, 0), item_y(ctx, &st, 0, 2))
	rich_frame(ctx, &st, &rs)
	assert_equal(1, st.live[1])

	point_at(ctx, item_x(ctx, &st, 0), item_y(ctx, &st, 0, 0))
	rich_frame(ctx, &st, &rs)
	rich_frame(ctx, &st, &rs)
	assert_equal(0 - 1, st.sub[0])
	assert_equal(0, st.live[1])
	assert_equal(1, st.open)
	ui_render_destroy(&fx.r)


# A check item flips its value and closes the menu; it reports the flip.
void test_a_check_item_toggles():
	ui_fixture fx
	ui_context* ctx = ui_fixture_init(&fx)
	ui_menu_state st
	ui_menu_init(&st, 140.0)
	rich_state rs
	rich_init(&rs)
	ui_menu_open_at(&st, 40.0, 40.0, 0)
	rich_frame(ctx, &st, &rs)
	ui_test_click(ctx, item_x(ctx, &st, 0), item_y(ctx, &st, 0, 1))
	rich_frame(ctx, &st, &rs)
	assert_equal(1, rs.wrap)
	assert_equal(0, st.open)

	ui_menu_open_at(&st, 40.0, 40.0, 0)
	rich_frame(ctx, &st, &rs)
	ui_test_click(ctx, item_x(ctx, &st, 0), item_y(ctx, &st, 0, 1))
	rich_frame(ctx, &st, &rs)
	assert_equal(0, rs.wrap)
	ui_render_destroy(&fx.r)


# The keyboard: Down steps over the separator and the disabled item and
# wraps; Right opens a submenu on its first item; Left and Escape close
# one level; Return chooses.
void test_keyboard_navigation():
	ui_fixture fx
	ui_context* ctx = ui_fixture_init(&fx)
	ui_menu_state st
	ui_menu_init(&st, 140.0)
	rich_state rs
	rich_init(&rs)
	ui_menu_open_at(&st, 40.0, 40.0, 1)
	rich_frame(ctx, &st, &rs)
	assert_equal(0, st.hl[0])

	ui_test_nav(ctx, GFX_NAV_DOWN)
	ui_test_nav(ctx, GFX_NAV_DOWN)
	rich_frame(ctx, &st, &rs)
	assert_equal(2, st.hl[0])

	# Sort -> (separator, disabled Paste skipped) -> Delete -> wraps to Copy.
	ui_test_nav(ctx, GFX_NAV_DOWN)
	rich_frame(ctx, &st, &rs)
	assert_equal(5, st.hl[0])
	ui_test_nav(ctx, GFX_NAV_DOWN)
	rich_frame(ctx, &st, &rs)
	assert_equal(0, st.hl[0])
	ui_test_nav(ctx, GFX_NAV_UP)
	rich_frame(ctx, &st, &rs)
	assert_equal(5, st.hl[0])
	ui_test_nav(ctx, GFX_NAV_HOME)
	rich_frame(ctx, &st, &rs)
	assert_equal(0, st.hl[0])

	# Into the submenu and back out.
	ui_test_nav(ctx, GFX_NAV_DOWN)
	ui_test_nav(ctx, GFX_NAV_DOWN)
	ui_test_nav(ctx, GFX_NAV_RIGHT)
	rich_frame(ctx, &st, &rs)
	assert_equal(2, st.sub[0])
	assert_equal(1, st.kb_level)
	assert_equal(0, st.hl[1])
	assert_equal(1, st.live[1])
	ui_test_nav(ctx, GFX_NAV_LEFT)
	rich_frame(ctx, &st, &rs)
	assert_equal(0 - 1, st.sub[0])
	assert_equal(0, st.kb_level)
	ui_test_nav(ctx, GFX_NAV_RIGHT)
	rich_frame(ctx, &st, &rs)
	ui_test_char(ctx, 27)
	rich_frame(ctx, &st, &rs)
	assert_equal(1, st.open)
	assert_equal(0, st.kb_level)

	# Return in the submenu picks "Size".
	ui_test_nav(ctx, GFX_NAV_RIGHT)
	rich_frame(ctx, &st, &rs)
	# CHAR and NAV queue separately, so keys whose order matters go in
	# separate frames.
	ui_test_nav(ctx, GFX_NAV_DOWN)
	rich_frame(ctx, &st, &rs)
	assert_equal(1, st.hl[1])
	ui_test_char(ctx, 13)
	rich_frame(ctx, &st, &rs)
	assert_equal(1, rs.sort)
	assert_equal(0, st.open)
	ui_render_destroy(&fx.r)


# Escape on the root level closes the menu, and Return on a plain item
# chooses it.
void test_return_chooses_and_escape_closes():
	ui_fixture fx
	ui_context* ctx = ui_fixture_init(&fx)
	ui_menu_state st
	ui_menu_init(&st, 140.0)
	rich_state rs
	rich_init(&rs)
	ui_menu_open_at(&st, 40.0, 40.0, 1)
	rich_frame(ctx, &st, &rs)
	ui_test_char(ctx, 13)
	rich_frame(ctx, &st, &rs)
	assert_equal(0, rs.chosen)
	assert_equal(0, st.open)

	ui_menu_open_at(&st, 40.0, 40.0, 1)
	rich_frame(ctx, &st, &rs)
	ui_test_char(ctx, 27)
	rich_frame(ctx, &st, &rs)
	assert_equal(0, st.open)
	assert_equal(0, ctx.popup_depth)
	ui_render_destroy(&fx.r)


# Typing a letter that only one item marks with '&' chooses that item;
# a letter several items start with only moves the highlight.
void test_mnemonics_and_typeahead():
	ui_fixture fx
	ui_context* ctx = ui_fixture_init(&fx)
	ui_menu_state st
	ui_menu_init(&st, 140.0)
	rich_state rs
	rich_init(&rs)
	ui_menu_open_at(&st, 40.0, 40.0, 1)
	rich_frame(ctx, &st, &rs)

	# 'p' is no mnemonic, but "Paste" starts with it — and Paste is
	# disabled, so nothing moves.
	ui_test_char(ctx, 'p')
	rich_frame(ctx, &st, &rs)
	assert_equal(0, st.hl[0])
	assert_equal(1, st.open)

	# 'o' is Sort's mnemonic: it opens the submenu.
	ui_test_char(ctx, 'o')
	rich_frame(ctx, &st, &rs)
	rich_frame(ctx, &st, &rs)
	assert_equal(2, st.sub[0])
	assert_equal(1, st.kb_level)
	ui_test_char(ctx, 27)
	rich_frame(ctx, &st, &rs)

	# 'D' (either case) is Delete's: it is chosen.
	ui_test_char(ctx, 'D')
	rich_frame(ctx, &st, &rs)
	rich_frame(ctx, &st, &rs)
	assert_equal(1, rs.chosen)
	assert_equal(0, st.open)
	ui_render_destroy(&fx.r)


# The menu reserves the same id block open or closed, so a widget issued
# after it keeps its id when the menu opens.
void test_ids_after_the_menu_do_not_shift():
	ui_fixture fx
	ui_context* ctx = ui_fixture_init(&fx)
	ui_menu_state st
	ui_menu_init(&st, 140.0)
	rich_state rs
	rich_init(&rs)
	rich_frame(ctx, &st, &rs)
	int closed_next = ctx.next_id
	ui_menu_open_at(&st, 40.0, 40.0, 0)
	rich_frame(ctx, &st, &rs)
	assert_equal(closed_next, ctx.next_id)
	ui_render_destroy(&fx.r)


# Chord matching: the letter or its control code, case-insensitive,
# with the modifier bits compared exactly.
void test_shortcut_matching_and_format():
	assert_equal(1, ui_shortcut_matches('s', GFX_MOD_CTRL, GFX_MOD_CTRL, 's'))
	assert_equal(1, ui_shortcut_matches(19, GFX_MOD_CTRL, GFX_MOD_CTRL, 's'))
	assert_equal(1, ui_shortcut_matches('S', GFX_MOD_CTRL | GFX_MOD_SHIFT, GFX_MOD_CTRL | GFX_MOD_SHIFT, 's'))
	assert_equal(0, ui_shortcut_matches('s', GFX_MOD_CTRL | GFX_MOD_SHIFT, GFX_MOD_CTRL, 's'))
	assert_equal(0, ui_shortcut_matches('s', 0, GFX_MOD_CTRL, 's'))
	assert_equal(0, ui_shortcut_matches(19, GFX_MOD_ALT, GFX_MOD_ALT, 's'))
	char[32] buf
	ui_shortcut_format(&buf[0], 32, GFX_MOD_CTRL | GFX_MOD_SHIFT, 'z')
	assert_equal(0, strcmp(&buf[0], c"Ctrl+Shift+Z"))
	assert_equal(1, ui_menu_mnemonic(c"&Save") == 's')
	assert_equal(1, ui_menu_mnemonic(c"Save &As") == 'a')
	assert_equal(0, ui_menu_mnemonic(c"Fish && Chips"))
	char[32] out
	assert_equal(2, ui_menu_strip(c"Op&en", &out[0], 32))
	assert_equal(0, strcmp(&out[0], c"Open"))


# A submenu that would run off the right edge opens to the left.
void test_a_submenu_flips_left_at_the_edge():
	ui_rect parent = ui_rect_new(380.0, 40.0, 140.0, 200.0)
	ui_rect row = ui_rect_new(384.0, 100.0, 132.0, 26.0)
	ui_rect r = ui_menu_place_sub(parent, row, 8.0, 120.0, 80.0, 560.0, 320.0)
	asserts(c"flipped to the left", r.x + r.w <= parent.x)
	ui_rect s = ui_menu_place_sub(ui_rect_new(10.0, 40.0, 140.0, 200.0), row, 8.0, 120.0, 80.0, 560.0, 320.0)
	asserts(c"right when there is room", s.x == 150.0)
	ui_rect t = ui_menu_place_sub(parent, ui_rect_new(384.0, 300.0, 132.0, 26.0), 8.0, 120.0, 80.0, 560.0, 320.0)
	asserts(c"shifted up to stay on screen", t.y + t.h <= 320.0)
