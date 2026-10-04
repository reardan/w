# Headless unit tests for the menu bar: opening and switching menus by
# pointer and keyboard, press-drag-release, shortcuts that work while
# the menu is closed, and keeping keys away from a focused field behind
# an open menu (docs/projects/ui_widgets.md §12). No GL context or
# display.
# x64-only: the widget set imports graphics.gl/graphics.window, which
# link libGL/libX11 on the 64-bit Linux targets.
# wbuild: name=graphics_ui_menubar_test arch_only=x64
import lib.testing
import graphics.event
import graphics.ui.rect
import graphics.ui.theme
import graphics.ui.font
import graphics.ui.render
import graphics.ui.widgets
import graphics.ui.testing


struct app:
	ui_menubar_state bar
	ui_textbox_state field
	int32 chosen           # 1 New, 2 Save, 3 Print, 4 PDF, 5 Undo; 0 none
	int32 wrap


void app_init(app* a):
	ui_menubar_init(&a.bar)
	ui_textbox_init(&a.field)
	a.chosen = 0
	a.wrap = 0


# One frame: a File and an Edit menu over a text field.
void app_frame(ui_context* ctx, app* a):
	a.chosen = 0
	ui_menu_state* m = &a.bar.menu
	ui_begin(ctx, 480, 320)
	ui_menubar_begin(ctx, &a.bar, ui_rect_new(0.0, 0.0, 480.0, 28.0))
	if (ui_menubar_menu(ctx, &a.bar, c"&File")):
		if (ui_menu_item_key(ctx, m, c"&New", GFX_MOD_CTRL, 'n', 1)): a.chosen = 1
		if (ui_menu_item_key(ctx, m, c"&Save", GFX_MOD_CTRL, 's', 1)): a.chosen = 2
		if (ui_menu_item_key(ctx, m, c"&Print", GFX_MOD_CTRL, 'p', 0)): a.chosen = 3
		if (ui_menu_begin_sub(ctx, m, c"&Export", 1)):
			if (ui_menu_item_key(ctx, m, c"&PDF", GFX_MOD_CTRL | GFX_MOD_SHIFT, 'e', 1)): a.chosen = 4
			ui_menu_end_sub(ctx, m)
		ui_menubar_menu_end(ctx, &a.bar)
	if (ui_menubar_menu(ctx, &a.bar, c"&Edit")):
		if (ui_menu_item(ctx, m, c"&Undo", 1)): a.chosen = 5
		ui_menu_check(ctx, m, c"&Wrap", &a.wrap, 1)
		ui_menubar_menu_end(ctx, &a.bar)
	ui_menubar_end(ctx, &a.bar)
	ui_region_push(ctx, ui_rect_new(0.0, 200.0, 480.0, 120.0))
	ui_textbox(ctx, 200.0, &a.field)
	ui_region_pop(ctx)
	ui_end(ctx)


int title_x(ui_context* ctx, int index):
	float32 x = 4.0 + ui_menubar_title_pad()
	if (index > 0): x = x + cast(float32, ui_text_width(c"File", ctx.theme.text_scale)) + ui_menubar_title_pad() * 2.0
	return cast(int, x + 4.0)


int item_px(app* a):
	return cast(int, a.bar.menu.surface[0].x + 30.0)


int item_py(ui_context* ctx, app* a, int level, int index):
	return cast(int, a.bar.menu.surface[level].y + cast(float32, ctx.theme.pad) + ui_menu_item_height() * (cast(float32, index) + 0.5))


void press(ui_context* ctx, int x, int y):
	ui_test_event(ctx, GFX_EVENT_MOUSE_DOWN, 1, x, y, 0)


void release(ui_context* ctx, int x, int y):
	ui_test_event(ctx, GFX_EVENT_MOUSE_UP, 1, x, y, 0)


# Clicking a title opens its menu below the bar; clicking it again
# closes it.
void test_clicking_a_title_opens_and_closes_its_menu():
	ui_fixture fx
	ui_context* ctx = ui_fixture_init(&fx)
	app a
	app_init(&a)
	app_frame(ctx, &a)
	assert_equal(0 - 1, a.bar.open_index)

	ui_test_click(ctx, title_x(ctx, 0), 14)
	app_frame(ctx, &a)
	app_frame(ctx, &a)
	assert_equal(0, a.bar.open_index)
	assert_equal(1, a.bar.menu.open)
	asserts(c"the menu hangs below the bar", a.bar.menu.surface[0].y >= 28.0)
	asserts(c"and draws on the popup layer", fx.r.layer_vert_count[UI_LAYER_POPUP] > 0)
	assert_equal(1, ctx.popup_depth)

	ui_test_click(ctx, title_x(ctx, 0), 14)
	app_frame(ctx, &a)
	app_frame(ctx, &a)
	assert_equal(0 - 1, a.bar.open_index)
	assert_equal(0, ctx.popup_depth)
	assert_equal(0, ctx.bracket_depth)
	ui_render_destroy(&fx.r)


# With one menu open, pointing at another title switches to it.
void test_hovering_another_title_switches_menus():
	ui_fixture fx
	ui_context* ctx = ui_fixture_init(&fx)
	app a
	app_init(&a)
	ui_test_click(ctx, title_x(ctx, 0), 14)
	app_frame(ctx, &a)
	app_frame(ctx, &a)
	ctx.input.mouse_x = title_x(ctx, 1)
	ctx.input.mouse_y = 14
	app_frame(ctx, &a)
	app_frame(ctx, &a)
	assert_equal(1, a.bar.open_index)
	assert_equal(1, a.bar.menu.open)
	ui_render_destroy(&fx.r)


# Press on a title, drag down, release on an item: chosen, as on every
# desktop.
void test_press_drag_release_chooses():
	ui_fixture fx
	ui_context* ctx = ui_fixture_init(&fx)
	app a
	app_init(&a)
	press(ctx, title_x(ctx, 0), 14)
	app_frame(ctx, &a)
	app_frame(ctx, &a)
	assert_equal(0, a.bar.open_index)
	int x = item_px(&a)
	int y = item_py(ctx, &a, 0, 1)
	ctx.input.mouse_x = x
	ctx.input.mouse_y = y
	app_frame(ctx, &a)
	release(ctx, x, y)
	app_frame(ctx, &a)
	assert_equal(2, a.chosen)
	assert_equal(0, a.bar.menu.open)
	app_frame(ctx, &a)
	assert_equal(0 - 1, a.bar.open_index)
	assert_equal(0, ctx.popup_depth)
	ui_render_destroy(&fx.r)


# A shortcut fires its item with every menu closed — as the control
# code the native backends send, and as the letter the web host sends —
# reaching into submenus too. A disabled item's shortcut does nothing.
void test_shortcuts_work_with_the_menu_closed():
	ui_fixture fx
	ui_context* ctx = ui_fixture_init(&fx)
	app a
	app_init(&a)
	app_frame(ctx, &a)

	ui_test_event(ctx, GFX_EVENT_CHAR, 19, 0, 0, GFX_MOD_CTRL)
	app_frame(ctx, &a)
	assert_equal(2, a.chosen)
	assert_equal(0, a.bar.menu.open)

	ui_test_event(ctx, GFX_EVENT_CHAR, 'n', 0, 0, GFX_MOD_CTRL)
	app_frame(ctx, &a)
	assert_equal(1, a.chosen)

	ui_test_event(ctx, GFX_EVENT_CHAR, 'E', 0, 0, GFX_MOD_CTRL | GFX_MOD_SHIFT)
	app_frame(ctx, &a)
	assert_equal(4, a.chosen)

	ui_test_event(ctx, GFX_EVENT_CHAR, 16, 0, 0, GFX_MOD_CTRL)
	app_frame(ctx, &a)
	assert_equal(0, a.chosen)
	assert_equal(0, ctx.popup_depth)
	ui_render_destroy(&fx.r)


# Alt+mnemonic opens a menu with its first item highlighted; Right and
# Left move between menus; Escape closes.
void test_the_keyboard_drives_the_bar():
	ui_fixture fx
	ui_context* ctx = ui_fixture_init(&fx)
	app a
	app_init(&a)
	app_frame(ctx, &a)

	ui_test_event(ctx, GFX_EVENT_CHAR, 'f', 0, 0, GFX_MOD_ALT)
	app_frame(ctx, &a)
	app_frame(ctx, &a)
	assert_equal(0, a.bar.open_index)
	assert_equal(0, a.bar.menu.hl[0])

	ui_test_nav(ctx, GFX_NAV_RIGHT)
	app_frame(ctx, &a)
	app_frame(ctx, &a)
	assert_equal(1, a.bar.open_index)
	assert_equal(0, a.bar.menu.hl[0])
	# Right wraps around to the first menu again.
	ui_test_nav(ctx, GFX_NAV_RIGHT)
	app_frame(ctx, &a)
	app_frame(ctx, &a)
	assert_equal(0, a.bar.open_index)
	ui_test_nav(ctx, GFX_NAV_LEFT)
	app_frame(ctx, &a)
	app_frame(ctx, &a)
	assert_equal(1, a.bar.open_index)

	# Down to Wrap and Return: the check flips and the menu closes.
	ui_test_nav(ctx, GFX_NAV_DOWN)
	app_frame(ctx, &a)
	ui_test_char(ctx, 13)
	app_frame(ctx, &a)
	assert_equal(1, a.wrap)
	app_frame(ctx, &a)
	assert_equal(0 - 1, a.bar.open_index)

	ui_test_event(ctx, GFX_EVENT_CHAR, 'e', 0, 0, GFX_MOD_ALT)
	app_frame(ctx, &a)
	app_frame(ctx, &a)
	assert_equal(1, a.bar.open_index)
	ui_test_char(ctx, 27)
	app_frame(ctx, &a)
	app_frame(ctx, &a)
	assert_equal(0 - 1, a.bar.open_index)
	assert_equal(0, ctx.popup_depth)
	ui_render_destroy(&fx.r)


# A focused text field keeps its focus while a menu is open, but the
# keys go to the menu; and a Ctrl chord is a shortcut, never typing.
void test_a_focused_field_behind_the_menu_gets_no_keys():
	ui_fixture fx
	ui_context* ctx = ui_fixture_init(&fx)
	app a
	app_init(&a)
	ui_test_click(ctx, 40, 210)
	app_frame(ctx, &a)
	ui_test_text(ctx, c"ab")
	app_frame(ctx, &a)
	assert_equal(2, a.field.length)
	int focused = ctx.focus

	ui_test_event(ctx, GFX_EVENT_CHAR, 's', 0, 0, GFX_MOD_CTRL)
	app_frame(ctx, &a)
	assert_equal(2, a.chosen)
	assert_equal(2, a.field.length)

	ui_test_event(ctx, GFX_EVENT_CHAR, 'f', 0, 0, GFX_MOD_ALT)
	app_frame(ctx, &a)
	app_frame(ctx, &a)
	assert_equal(0, a.bar.open_index)
	ui_test_text(ctx, c"xy")
	app_frame(ctx, &a)
	assert_equal(2, a.field.length)
	assert_equal(focused, ctx.focus)
	ui_render_destroy(&fx.r)


# A press outside the bar and the menu closes the menu and is consumed:
# the field under it does not take focus from that press.
void test_an_outside_press_closes_and_is_consumed():
	ui_fixture fx
	ui_context* ctx = ui_fixture_init(&fx)
	app a
	app_init(&a)
	ui_test_click(ctx, title_x(ctx, 0), 14)
	app_frame(ctx, &a)
	app_frame(ctx, &a)
	ui_test_click(ctx, 40, 210)
	app_frame(ctx, &a)
	app_frame(ctx, &a)
	assert_equal(0 - 1, a.bar.open_index)
	assert_equal(0, ctx.focus)
	ui_render_destroy(&fx.r)


# Pointing at a submenu item opens it; choosing inside it reports once.
void test_a_submenu_in_a_bar_menu():
	ui_fixture fx
	ui_context* ctx = ui_fixture_init(&fx)
	app a
	app_init(&a)
	ui_test_click(ctx, title_x(ctx, 0), 14)
	app_frame(ctx, &a)
	app_frame(ctx, &a)
	ctx.input.mouse_x = item_px(&a)
	ctx.input.mouse_y = item_py(ctx, &a, 0, 3)
	app_frame(ctx, &a)
	assert_equal(1, a.bar.menu.live[1])
	int x = cast(int, a.bar.menu.surface[1].x + 30.0)
	ui_test_click(ctx, x, item_py(ctx, &a, 1, 0))
	app_frame(ctx, &a)
	assert_equal(4, a.chosen)
	app_frame(ctx, &a)
	assert_equal(0, a.chosen)
	assert_equal(0, ctx.popup_depth)
	ui_render_destroy(&fx.r)


# The bar's ids are reserved up front, so a widget after it keeps its id
# whether a menu is open or not.
void test_ids_after_the_bar_do_not_shift():
	ui_fixture fx
	ui_context* ctx = ui_fixture_init(&fx)
	app a
	app_init(&a)
	app_frame(ctx, &a)
	int closed_next = ctx.next_id
	ui_test_click(ctx, title_x(ctx, 0), 14)
	app_frame(ctx, &a)
	app_frame(ctx, &a)
	assert_equal(closed_next, ctx.next_id)
	ui_render_destroy(&fx.r)
