# Headless unit tests for the multi-line edit surface: typing, caret
# motion, goal-column behavior, shift-selection and line virtualization
# (docs/projects/ui_widgets.md §5). No GL context or display.
# x64-only: the widget set imports graphics.gl/graphics.window, which
# link libGL/libX11 on the 64-bit Linux targets.
# wbuild: name=graphics_ui_textarea_test arch_only=x64
import lib.testing
import graphics.event
import graphics.ui.rect
import graphics.ui.theme
import graphics.ui.render
import graphics.ui.widgets


ui_rect area():
	return ui_rect_new(10.0, 10.0, 200.0, 120.0)


void setup(ui_renderer* r, ui_theme* theme, ui_context* ctx):
	ui_render_init_headless(r)
	ui_theme_light(theme)
	ui_context_init(ctx, r, theme)


void feed_click(ui_context* ctx, int x, int y):
	gfx_event press
	press.kind = GFX_EVENT_MOUSE_DOWN
	press.code = 1
	press.x = x
	press.y = y
	press.mods = 0
	ui_feed_event(ctx, &press)
	gfx_event release
	release.kind = GFX_EVENT_MOUSE_UP
	release.code = 1
	release.x = x
	release.y = y
	release.mods = 0
	ui_feed_event(ctx, &release)


void feed_char(ui_context* ctx, int code):
	gfx_event e
	e.kind = GFX_EVENT_CHAR
	e.code = code
	e.x = 0
	e.y = 0
	e.mods = 0
	ui_feed_event(ctx, &e)


void feed_nav(ui_context* ctx, int code, int mods):
	gfx_event e
	e.kind = GFX_EVENT_NAV
	e.code = code
	e.x = 0
	e.y = 0
	e.mods = mods
	ui_feed_event(ctx, &e)


int area_frame(ui_context* ctx, ui_textarea_state* st):
	ui_begin(ctx, 320, 240)
	int changed = ui_textarea(ctx, area(), st)
	ui_end(ctx)
	return changed


# Click inside the field to focus it, leaving the caret at 0,0.
void focus(ui_context* ctx, ui_textarea_state* st):
	feed_click(ctx, 20, 20)
	area_frame(ctx, st)
	st.caret_line = 0
	st.caret_col = 0
	st.caret_goal_col = 0


void test_typing_inserts_and_reports_change():
	ui_renderer r
	ui_theme theme
	ui_context ctx
	setup(&r, &theme, &ctx)
	ui_textarea_state st
	ui_textarea_init(&st)
	focus(&ctx, &st)

	# An unfocused frame with no input reports no change.
	assert_equal(0, area_frame(&ctx, &st))

	feed_char(&ctx, 'h')
	feed_char(&ctx, 'i')
	assert_equal(1, area_frame(&ctx, &st))
	assert_equal(2, st.buf.length)
	assert_equal(0, strcmp(st.buf.data, c"hi"))
	assert_equal(2, st.caret_col)
	ui_textarea_free(&st)
	ui_render_destroy(&r)


void test_return_inserts_a_newline():
	ui_renderer r
	ui_theme theme
	ui_context ctx
	setup(&r, &theme, &ctx)
	ui_textarea_state st
	ui_textarea_init(&st)
	focus(&ctx, &st)

	feed_char(&ctx, 'a')
	feed_char(&ctx, 13)
	feed_char(&ctx, 'b')
	area_frame(&ctx, &st)
	# A multi-line field has no submit edge to steal return for.
	assert_equal(0, strcmp(st.buf.data, c"a\nb"))
	assert_equal(2, st.buf.line_count)
	assert_equal(1, st.caret_line)
	assert_equal(1, st.caret_col)
	ui_textarea_free(&st)
	ui_render_destroy(&r)


void test_backspace_joins_lines():
	ui_renderer r
	ui_theme theme
	ui_context ctx
	setup(&r, &theme, &ctx)
	ui_textarea_state st
	ui_textarea_init(&st)
	ui_textarea_set(&st, c"ab\ncd")
	focus(&ctx, &st)
	st.caret_line = 1
	st.caret_col = 0

	feed_char(&ctx, 8)
	assert_equal(1, area_frame(&ctx, &st))
	assert_equal(0, strcmp(st.buf.data, c"abcd"))
	assert_equal(1, st.buf.line_count)
	assert_equal(2, st.caret_col)

	# Backspace at the very start does nothing but is harmless.
	st.caret_line = 0
	st.caret_col = 0
	feed_char(&ctx, 8)
	area_frame(&ctx, &st)
	assert_equal(0, strcmp(st.buf.data, c"abcd"))
	ui_textarea_free(&st)
	ui_render_destroy(&r)


void test_arrow_and_line_motion():
	ui_renderer r
	ui_theme theme
	ui_context ctx
	setup(&r, &theme, &ctx)
	ui_textarea_state st
	ui_textarea_init(&st)
	ui_textarea_set(&st, c"alpha\nbeta\ngamma")
	focus(&ctx, &st)

	feed_nav(&ctx, GFX_NAV_RIGHT, 0)
	feed_nav(&ctx, GFX_NAV_RIGHT, 0)
	area_frame(&ctx, &st)
	assert_equal(2, st.caret_col)

	feed_nav(&ctx, GFX_NAV_DOWN, 0)
	area_frame(&ctx, &st)
	assert_equal(1, st.caret_line)
	assert_equal(2, st.caret_col)

	feed_nav(&ctx, GFX_NAV_END, 0)
	area_frame(&ctx, &st)
	assert_equal(4, st.caret_col)

	feed_nav(&ctx, GFX_NAV_HOME, 0)
	area_frame(&ctx, &st)
	assert_equal(0, st.caret_col)

	# Left at the start of a line steps back over the newline.
	feed_nav(&ctx, GFX_NAV_LEFT, 0)
	area_frame(&ctx, &st)
	assert_equal(0, st.caret_line)
	assert_equal(5, st.caret_col)

	# Motion at the buffer's ends clamps rather than wrapping.
	feed_nav(&ctx, GFX_NAV_UP, 0)
	feed_nav(&ctx, GFX_NAV_UP, 0)
	area_frame(&ctx, &st)
	assert_equal(0, st.caret_line)
	ui_textarea_free(&st)
	ui_render_destroy(&r)


void test_ctrl_home_and_end_reach_the_buffer_ends():
	ui_renderer r
	ui_theme theme
	ui_context ctx
	setup(&r, &theme, &ctx)
	ui_textarea_state st
	ui_textarea_init(&st)
	ui_textarea_set(&st, c"alpha\nbeta\ngamma")
	focus(&ctx, &st)

	feed_nav(&ctx, GFX_NAV_END, GFX_MOD_CTRL)
	area_frame(&ctx, &st)
	assert_equal(2, st.caret_line)
	assert_equal(5, st.caret_col)

	feed_nav(&ctx, GFX_NAV_HOME, GFX_MOD_CTRL)
	area_frame(&ctx, &st)
	assert_equal(0, st.caret_line)
	assert_equal(0, st.caret_col)
	ui_textarea_free(&st)
	ui_render_destroy(&r)


void test_goal_column_survives_a_short_line():
	ui_renderer r
	ui_theme theme
	ui_context ctx
	setup(&r, &theme, &ctx)
	ui_textarea_state st
	ui_textarea_init(&st)
	# A long line, a short one, a long one.
	ui_textarea_set(&st, c"abcdefgh\nxy\nabcdefgh")
	focus(&ctx, &st)

	feed_nav(&ctx, GFX_NAV_END, 0)
	area_frame(&ctx, &st)
	assert_equal(8, st.caret_col)

	# Down onto the short line: the caret clamps to its end...
	feed_nav(&ctx, GFX_NAV_DOWN, 0)
	area_frame(&ctx, &st)
	assert_equal(1, st.caret_line)
	assert_equal(2, st.caret_col)

	# ...but the goal column is remembered, so continuing down returns
	# to where the caret started.
	feed_nav(&ctx, GFX_NAV_DOWN, 0)
	area_frame(&ctx, &st)
	assert_equal(2, st.caret_line)
	assert_equal(8, st.caret_col)

	# A horizontal move resets the goal to where the caret actually is.
	feed_nav(&ctx, GFX_NAV_LEFT, 0)
	feed_nav(&ctx, GFX_NAV_UP, 0)
	feed_nav(&ctx, GFX_NAV_UP, 0)
	area_frame(&ctx, &st)
	assert_equal(0, st.caret_line)
	assert_equal(7, st.caret_col)
	ui_textarea_free(&st)
	ui_render_destroy(&r)


void test_shift_motion_extends_a_selection():
	ui_renderer r
	ui_theme theme
	ui_context ctx
	setup(&r, &theme, &ctx)
	ui_textarea_state st
	ui_textarea_init(&st)
	ui_textarea_set(&st, c"abcdef")
	focus(&ctx, &st)
	assert_equal(0, ui_textarea_has_selection(&st))

	feed_nav(&ctx, GFX_NAV_RIGHT, GFX_MOD_SHIFT)
	feed_nav(&ctx, GFX_NAV_RIGHT, GFX_MOD_SHIFT)
	feed_nav(&ctx, GFX_NAV_RIGHT, GFX_MOD_SHIFT)
	area_frame(&ctx, &st)
	assert_equal(1, ui_textarea_has_selection(&st))
	assert_equal(0, ui_textarea_sel_start(&st))
	assert_equal(3, ui_textarea_sel_end(&st))

	# Motion without shift drops it.
	feed_nav(&ctx, GFX_NAV_RIGHT, 0)
	area_frame(&ctx, &st)
	assert_equal(0, ui_textarea_has_selection(&st))
	ui_textarea_free(&st)
	ui_render_destroy(&r)


void test_typing_replaces_the_selection():
	ui_renderer r
	ui_theme theme
	ui_context ctx
	setup(&r, &theme, &ctx)
	ui_textarea_state st
	ui_textarea_init(&st)
	ui_textarea_set(&st, c"abcdef")
	focus(&ctx, &st)

	feed_nav(&ctx, GFX_NAV_RIGHT, GFX_MOD_SHIFT)
	feed_nav(&ctx, GFX_NAV_RIGHT, GFX_MOD_SHIFT)
	feed_nav(&ctx, GFX_NAV_RIGHT, GFX_MOD_SHIFT)
	area_frame(&ctx, &st)
	feed_char(&ctx, 'Z')
	assert_equal(1, area_frame(&ctx, &st))
	assert_equal(0, strcmp(st.buf.data, c"Zdef"))
	assert_equal(0, ui_textarea_has_selection(&st))
	assert_equal(1, st.caret_col)
	ui_textarea_free(&st)
	ui_render_destroy(&r)


void test_delete_key_removes_forward_and_removes_selections():
	ui_renderer r
	ui_theme theme
	ui_context ctx
	setup(&r, &theme, &ctx)
	ui_textarea_state st
	ui_textarea_init(&st)
	ui_textarea_set(&st, c"abcdef")
	focus(&ctx, &st)

	feed_nav(&ctx, GFX_NAV_DELETE, 0)
	assert_equal(1, area_frame(&ctx, &st))
	assert_equal(0, strcmp(st.buf.data, c"bcdef"))
	assert_equal(0, st.caret_col)

	feed_nav(&ctx, GFX_NAV_RIGHT, GFX_MOD_SHIFT)
	feed_nav(&ctx, GFX_NAV_RIGHT, GFX_MOD_SHIFT)
	area_frame(&ctx, &st)
	feed_nav(&ctx, GFX_NAV_DELETE, 0)
	area_frame(&ctx, &st)
	assert_equal(0, strcmp(st.buf.data, c"def"))

	# Delete at the end of the buffer does nothing.
	feed_nav(&ctx, GFX_NAV_END, GFX_MOD_CTRL)
	area_frame(&ctx, &st)
	feed_nav(&ctx, GFX_NAV_DELETE, 0)
	area_frame(&ctx, &st)
	assert_equal(0, strcmp(st.buf.data, c"def"))
	ui_textarea_free(&st)
	ui_render_destroy(&r)


void test_unfocused_field_ignores_input():
	ui_renderer r
	ui_theme theme
	ui_context ctx
	setup(&r, &theme, &ctx)
	ui_textarea_state st
	ui_textarea_init(&st)
	ui_textarea_set(&st, c"abc")

	feed_char(&ctx, 'x')
	feed_nav(&ctx, GFX_NAV_RIGHT, 0)
	assert_equal(0, area_frame(&ctx, &st))
	assert_equal(0, strcmp(st.buf.data, c"abc"))
	assert_equal(0, st.caret_col)

	# Escape drops focus, and typing stops landing.
	focus(&ctx, &st)
	feed_char(&ctx, 27)
	area_frame(&ctx, &st)
	feed_char(&ctx, 'y')
	assert_equal(0, area_frame(&ctx, &st))
	assert_equal(0, strcmp(st.buf.data, c"abc"))
	ui_textarea_free(&st)
	ui_render_destroy(&r)


void test_only_visible_lines_are_drawn():
	ui_renderer r
	ui_theme theme
	ui_context ctx
	setup(&r, &theme, &ctx)
	ui_textarea_state st
	ui_textarea_init(&st)

	# 400 identical lines in a field about six lines tall.
	ui_text_buffer_set(&st.buf, c"x")
	int i = 0
	while (i < 400):
		ui_text_buffer_insert_text(&st.buf, st.buf.length, c"\nx")
		i = i + 1
	assert_equal(401, st.buf.line_count)

	area_frame(&ctx, &st)
	int drawn = r.layer_vert_count[UI_LAYER_BASE]
	# One glyph is 6 vertices; a whole 401-line document would be 2406
	# plus the field's own geometry. Only the visible band is issued.
	asserts(c"drew something", drawn > 0)
	asserts(c"did not draw every line", drawn < 401 * 6)
	# The scroll region still knows the document's full height.
	asserts(c"full height measured", ui_scroll_overflows(&st.scroll) == 1)
	ui_textarea_free(&st)
	ui_render_destroy(&r)


void test_caret_motion_scrolls_it_into_view():
	ui_renderer r
	ui_theme theme
	ui_context ctx
	setup(&r, &theme, &ctx)
	ui_textarea_state st
	ui_textarea_init(&st)
	ui_text_buffer_set(&st.buf, c"x")
	int i = 0
	while (i < 200):
		ui_text_buffer_insert_text(&st.buf, st.buf.length, c"\nx")
		i = i + 1
	focus(&ctx, &st)
	asserts(c"starts at top", st.scroll.offset_y == 0.0)

	# Ctrl+End goes to the last line, which has to scroll into view.
	feed_nav(&ctx, GFX_NAV_END, GFX_MOD_CTRL)
	area_frame(&ctx, &st)
	assert_equal(200, st.caret_line)
	asserts(c"scrolled to the caret", st.scroll.offset_y > 0.0)

	# And back to the top.
	feed_nav(&ctx, GFX_NAV_HOME, GFX_MOD_CTRL)
	area_frame(&ctx, &st)
	asserts(c"scrolled back", st.scroll.offset_y == 0.0)
	ui_textarea_free(&st)
	ui_render_destroy(&r)
