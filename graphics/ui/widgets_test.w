# Headless widget-interaction tests: scripted event frames against the
# GL-free renderer seam (ui_render_init_headless). Press-inside then
# release-inside clicks; release-outside does not; a press+release in
# ONE frame still clicks (the event queue's whole point); checkbox
# toggles caller state; drawing accumulates vertices without GL.
# Stage 2: textbox focus/typing/caret, radio groups, toggle, progress,
# dropdown popup scope + layer routing.
# x64-only: the widget module imports graphics.gl/graphics.window,
# which link libGL/libX11 on the 64-bit Linux targets.
# wbuild: name=graphics_ui_widgets_test arch_only=x64
import lib.testing
import graphics.event
import graphics.ui.rect
import graphics.ui.theme
import graphics.ui.font
import graphics.ui.render
import graphics.ui.widgets


# One scripted frame around a single button; feeds an optional event
# before the frame like ui_begin_window would. Returns the click.
int frame_with_button(ui_context* ctx, gfx_event* e):
	if (e != 0):
		ui_feed_event(ctx, e)
	ui_begin(ctx, 320, 240)
	int clicked = ui_button(ctx, c"Click")
	ui_end(ctx)
	return clicked


gfx_event make_event(int kind, int x, int y):
	gfx_event e
	e.kind = kind
	e.code = 1
	e.x = x
	e.y = y
	e.mods = 0
	return e


# A keyboard event: CHAR or NAV, position irrelevant.
gfx_event make_key(int kind, int code):
	gfx_event e
	e.kind = kind
	e.code = code
	e.x = 0
	e.y = 0
	e.mods = 0
	return e


# Click helper: feed a press+release pair at x,y before the next frame.
void feed_click(ui_context* ctx, int x, int y):
	gfx_event press = make_event(GFX_EVENT_MOUSE_DOWN, x, y)
	ui_feed_event(ctx, &press)
	gfx_event release = make_event(GFX_EVENT_MOUSE_UP, x, y)
	ui_feed_event(ctx, &release)


# Default metrics put the first widget row at (8,8); the "Click"
# button is 5 chars * 16px + 2*8 pad = 96 wide, 32 tall.
void test_press_release_inside_clicks():
	ui_renderer r
	ui_render_init_headless(&r)
	ui_theme theme
	ui_theme_light(&theme)
	ui_context ctx
	ui_context_init(&ctx, &r, &theme)

	assert_equal(0, frame_with_button(&ctx, 0))

	gfx_event press = make_event(GFX_EVENT_MOUSE_DOWN, 20, 20)
	assert_equal(0, frame_with_button(&ctx, &press))
	asserts(c"press claims active", ctx.active != 0)

	gfx_event release = make_event(GFX_EVENT_MOUSE_UP, 24, 22)
	assert_equal(1, frame_with_button(&ctx, &release))
	assert_equal(0, ctx.active)
	ui_render_destroy(&r)


void test_release_outside_does_not_click():
	ui_renderer r
	ui_render_init_headless(&r)
	ui_theme theme
	ui_theme_light(&theme)
	ui_context ctx
	ui_context_init(&ctx, &r, &theme)

	gfx_event press = make_event(GFX_EVENT_MOUSE_DOWN, 20, 20)
	assert_equal(0, frame_with_button(&ctx, &press))

	gfx_event release = make_event(GFX_EVENT_MOUSE_UP, 300, 200)
	assert_equal(0, frame_with_button(&ctx, &release))
	assert_equal(0, ctx.active)
	ui_render_destroy(&r)


void test_press_and_release_same_frame_clicks():
	ui_renderer r
	ui_render_init_headless(&r)
	ui_theme theme
	ui_theme_light(&theme)
	ui_context ctx
	ui_context_init(&ctx, &r, &theme)

	# Both events land in one poll cycle — the snapshot model lost
	# this; the queue must not.
	gfx_event press = make_event(GFX_EVENT_MOUSE_DOWN, 20, 20)
	ui_feed_event(&ctx, &press)
	gfx_event release = make_event(GFX_EVENT_MOUSE_UP, 20, 20)
	assert_equal(1, frame_with_button(&ctx, &release))
	ui_render_destroy(&r)


void test_checkbox_toggles_caller_state():
	ui_renderer r
	ui_render_init_headless(&r)
	ui_theme theme
	ui_theme_light(&theme)
	ui_context ctx
	ui_context_init(&ctx, &r, &theme)
	int32 checked = 0

	# Row at (8,8): box 16px + gap + text, 32 tall. Click the box.
	gfx_event press = make_event(GFX_EVENT_MOUSE_DOWN, 12, 24)
	ui_feed_event(&ctx, &press)
	gfx_event release = make_event(GFX_EVENT_MOUSE_UP, 12, 24)
	ui_feed_event(&ctx, &release)
	ui_begin(&ctx, 320, 240)
	assert_equal(1, ui_checkbox(&ctx, c"dark", &checked))
	ui_end(&ctx)
	assert_equal(1, checked)

	# No input: no toggle.
	ui_begin(&ctx, 320, 240)
	assert_equal(0, ui_checkbox(&ctx, c"dark", &checked))
	ui_end(&ctx)
	assert_equal(1, checked)

	# Second click pair flips it back.
	ui_feed_event(&ctx, &press)
	ui_feed_event(&ctx, &release)
	ui_begin(&ctx, 320, 240)
	assert_equal(1, ui_checkbox(&ctx, c"dark", &checked))
	ui_end(&ctx)
	assert_equal(0, checked)
	ui_render_destroy(&r)


void test_widgets_accumulate_vertices():
	ui_renderer r
	ui_render_init_headless(&r)
	ui_theme theme
	ui_theme_light(&theme)
	ui_context ctx
	ui_context_init(&ctx, &r, &theme)

	ui_begin(&ctx, 320, 240)
	ui_label(&ctx, c"W UI demo")
	int after_label = r.layer_vert_count[UI_LAYER_BASE]
	# 9 characters, 2 inkless spaces -> 7 glyph quads.
	asserts(c"label drew glyphs", after_label == 7 * 6)
	ui_button(&ctx, c"Click")
	int after_button = r.layer_vert_count[UI_LAYER_BASE]
	# button = pill rrect (7 quads) + 5 glyphs
	assert_equal(after_label + 12 * 6, after_button)
	int32 checked = 1
	ui_checkbox(&ctx, c"dark", &checked)
	# checked box = accent rrect (7 quads) + checkmark + 4 glyphs
	assert_equal(after_button + 12 * 6, r.layer_vert_count[UI_LAYER_BASE])
	ui_end(&ctx)
	ui_render_destroy(&r)


# Textbox state helpers, no frame needed.
void test_textbox_state_editing():
	ui_textbox_state st
	ui_textbox_init(&st)
	assert_equal(0, st.length)
	ui_textbox_set(&st, c"abc")
	assert_equal(3, st.length)
	assert_equal(3, st.caret)

	# Insert mid-string.
	st.caret = 1
	ui_textbox_insert(&st, 'X')
	asserts(c"insert", strcmp(&st.text[0], c"aXbc") == 0)
	assert_equal(2, st.caret)

	# Backspace removes before the caret.
	ui_textbox_backspace(&st)
	asserts(c"backspace", strcmp(&st.text[0], c"abc") == 0)
	assert_equal(1, st.caret)

	# The buffer caps at capacity; inserts past it are dropped.
	int i = 0
	while (i < 200):
		ui_textbox_insert(&st, 'z')
		i = i + 1
	assert_equal(ui_textbox_capacity(), st.length)


# Default metrics: a 200-wide textbox claims row (8,8,200,32); its
# text starts at x=16 and advances per glyph (proportional).
void test_textbox_focus_typing_and_submit():
	ui_renderer r
	ui_render_init_headless(&r)
	ui_theme theme
	ui_theme_light(&theme)
	ui_context ctx
	ui_context_init(&ctx, &r, &theme)
	ui_textbox_state st
	ui_textbox_init(&st)
	ui_textbox_set(&st, c"abc")

	# Unfocused: typing goes nowhere.
	gfx_event stray = make_key(GFX_EVENT_CHAR, 'q')
	ui_feed_event(&ctx, &stray)
	ui_begin(&ctx, 320, 240)
	assert_equal(0, ui_textbox(&ctx, 200.0, &st))
	ui_end(&ctx)
	assert_equal(0, ctx.focus)
	assert_equal(3, st.length)

	# A click just left of glyph boundary 2 focuses and snaps the
	# caret there (positions computed from the live metrics).
	feed_click(&ctx, 16 + ui_text_prefix_width(c"abc", 2, 2) - 1, 20)
	ui_begin(&ctx, 320, 240)
	ui_textbox(&ctx, 200.0, &st)
	ui_end(&ctx)
	asserts(c"focused", ctx.focus != 0)
	assert_equal(2, st.caret)

	# Typing inserts at the caret; nav keys move it.
	gfx_event ch = make_key(GFX_EVENT_CHAR, 'X')
	ui_feed_event(&ctx, &ch)
	gfx_event nav_end = make_key(GFX_EVENT_NAV, GFX_NAV_END)
	ui_feed_event(&ctx, &nav_end)
	ui_begin(&ctx, 320, 240)
	ui_textbox(&ctx, 200.0, &st)
	ui_end(&ctx)
	asserts(c"insert at caret", strcmp(&st.text[0], c"abXc") == 0)
	assert_equal(4, st.caret)

	# Backspace deletes; home/left clamp at 0.
	gfx_event bs = make_key(GFX_EVENT_CHAR, 8)
	ui_feed_event(&ctx, &bs)
	gfx_event nav_home = make_key(GFX_EVENT_NAV, GFX_NAV_HOME)
	ui_feed_event(&ctx, &nav_home)
	gfx_event nav_left = make_key(GFX_EVENT_NAV, GFX_NAV_LEFT)
	ui_feed_event(&ctx, &nav_left)
	ui_begin(&ctx, 320, 240)
	ui_textbox(&ctx, 200.0, &st)
	ui_end(&ctx)
	asserts(c"backspace end", strcmp(&st.text[0], c"abX") == 0)
	assert_equal(0, st.caret)

	# Return submits without changing the buffer.
	gfx_event cr = make_key(GFX_EVENT_CHAR, 13)
	ui_feed_event(&ctx, &cr)
	ui_begin(&ctx, 320, 240)
	assert_equal(1, ui_textbox(&ctx, 200.0, &st))
	ui_end(&ctx)
	asserts(c"submit keeps text", strcmp(&st.text[0], c"abX") == 0)

	# Escape drops focus; a click outside also would.
	gfx_event esc = make_key(GFX_EVENT_CHAR, 27)
	ui_feed_event(&ctx, &esc)
	ui_begin(&ctx, 320, 240)
	ui_textbox(&ctx, 200.0, &st)
	ui_end(&ctx)
	assert_equal(0, ctx.focus)
	ui_render_destroy(&r)


void test_radio_group_selects():
	ui_renderer r
	ui_render_init_headless(&r)
	ui_theme theme
	ui_theme_light(&theme)
	ui_context ctx
	ui_context_init(&ctx, &r, &theme)
	int32 selected = 0

	# Rows at y=8 and y=48; each radio box is 16px starting at x=8.
	feed_click(&ctx, 12, 60)
	ui_begin(&ctx, 320, 240)
	assert_equal(0, ui_radio(&ctx, c"first", 0, &selected))
	assert_equal(1, ui_radio(&ctx, c"second", 1, &selected))
	ui_end(&ctx)
	assert_equal(1, selected)

	# Clicking the already-selected option reports no change.
	feed_click(&ctx, 12, 60)
	ui_begin(&ctx, 320, 240)
	assert_equal(0, ui_radio(&ctx, c"first", 0, &selected))
	assert_equal(0, ui_radio(&ctx, c"second", 1, &selected))
	ui_end(&ctx)
	assert_equal(1, selected)
	ui_render_destroy(&r)


void test_toggle_flips():
	ui_renderer r
	ui_render_init_headless(&r)
	ui_theme theme
	ui_theme_light(&theme)
	ui_context ctx
	ui_context_init(&ctx, &r, &theme)
	int32 on = 0

	feed_click(&ctx, 20, 20)
	ui_begin(&ctx, 320, 240)
	assert_equal(1, ui_toggle(&ctx, c"wifi", &on))
	ui_end(&ctx)
	assert_equal(1, on)

	ui_begin(&ctx, 320, 240)
	assert_equal(0, ui_toggle(&ctx, c"wifi", &on))
	ui_end(&ctx)
	assert_equal(1, on)
	ui_render_destroy(&r)


void test_progress_vertices_and_clamp():
	ui_renderer r
	ui_render_init_headless(&r)
	ui_theme theme
	ui_theme_light(&theme)
	ui_context ctx
	ui_context_init(&ctx, &r, &theme)

	# Zero fraction: the track's rounded rect only (7 quads). Positive:
	# track + fill (14 quads). Over 1 clamps to the track width.
	ui_begin(&ctx, 320, 240)
	ui_progress(&ctx, 100.0, 0.0)
	assert_equal(42, r.layer_vert_count[UI_LAYER_BASE])
	ui_progress(&ctx, 100.0, 0.5)
	assert_equal(126, r.layer_vert_count[UI_LAYER_BASE])
	ui_progress(&ctx, 100.0, 7.0)
	assert_equal(210, r.layer_vert_count[UI_LAYER_BASE])
	# The clamped fill's right edge equals the track's right edge: no
	# vertex of the third widget's fill (the last 42) reaches past
	# x = 8 + 100.
	float32 max_x = 0.0
	int v = 168
	while (v < 210):
		if (r.layer_verts[UI_LAYER_BASE][v * 8] > max_x):
			max_x = r.layer_verts[UI_LAYER_BASE][v * 8]
		v = v + 1
	asserts(c"clamped fill width", max_x == 108.0)
	ui_end(&ctx)
	ui_render_destroy(&r)


# Dropdown: header row (8,8,160,32); open list rows at y=40,72,104.
void test_dropdown_opens_selects_and_blocks():
	ui_renderer r
	ui_render_init_headless(&r)
	ui_theme theme
	ui_theme_light(&theme)
	ui_context ctx
	ui_context_init(&ctx, &r, &theme)
	char** items = cast(char**, malloc(3 * __word_size__))
	items[0] = c"alpha"
	items[1] = c"beta"
	items[2] = c"gamma"
	int32 selected = 0
	int32 open = 0

	# Click the header: opens, claims the popup scope, draws the list on
	# the popup layer.
	feed_click(&ctx, 20, 20)
	ui_begin(&ctx, 320, 240)
	assert_equal(0, ui_dropdown(&ctx, 160.0, items, 3, &selected, &open))
	ui_end(&ctx)
	assert_equal(1, open)
	asserts(c"popup claimed", ctx.popup_depth == 1)
	asserts(c"popup layer drawn", r.layer_vert_count[UI_LAYER_POPUP] > 0)

	# While open, a button under the pointer is inert — and the press
	# that picks an item is consumed before later widgets run.
	feed_click(&ctx, 20, 77)
	ui_begin(&ctx, 320, 240)
	assert_equal(1, ui_dropdown(&ctx, 160.0, items, 3, &selected, &open))
	assert_equal(0, ui_button(&ctx, c"under"))
	ui_end(&ctx)
	assert_equal(1, selected)
	assert_equal(0, open)
	assert_equal(0, ctx.popup_depth)

	# Reopen, then click away: closes with no selection change.
	feed_click(&ctx, 20, 20)
	ui_begin(&ctx, 320, 240)
	ui_dropdown(&ctx, 160.0, items, 3, &selected, &open)
	ui_end(&ctx)
	assert_equal(1, open)
	feed_click(&ctx, 300, 200)
	ui_begin(&ctx, 320, 240)
	assert_equal(0, ui_dropdown(&ctx, 160.0, items, 3, &selected, &open))
	ui_end(&ctx)
	assert_equal(0, open)
	assert_equal(1, selected)

	# Closed again: no popup-layer geometry.
	ui_begin(&ctx, 320, 240)
	ui_dropdown(&ctx, 160.0, items, 3, &selected, &open)
	ui_end(&ctx)
	assert_equal(0, r.layer_vert_count[UI_LAYER_POPUP])
	ui_render_destroy(&r)


void test_disabled_scope_is_inert():
	ui_renderer r
	ui_render_init_headless(&r)
	ui_theme theme
	ui_theme_light(&theme)
	ui_context ctx
	ui_context_init(&ctx, &r, &theme)
	ui_textbox_state st
	ui_textbox_init(&st)

	# A click pair aimed at the button row does nothing while disabled.
	feed_click(&ctx, 20, 20)
	ui_begin(&ctx, 320, 240)
	ui_disable(&ctx, 1)
	assert_equal(0, ui_button(&ctx, c"Click"))
	assert_equal(0, ui_textbox(&ctx, 200.0, &st))
	ui_disable(&ctx, 0)
	ui_end(&ctx)
	assert_equal(0, ctx.active)
	assert_equal(0, ctx.focus)

	# The same click works once the scope is lifted.
	feed_click(&ctx, 20, 20)
	ui_begin(&ctx, 320, 240)
	assert_equal(1, ui_button(&ctx, c"Click"))
	ui_end(&ctx)
	ui_render_destroy(&r)


void test_same_line_layout():
	ui_renderer r
	ui_render_init_headless(&r)
	ui_theme theme
	ui_theme_light(&theme)
	ui_context ctx
	ui_context_init(&ctx, &r, &theme)

	ui_begin(&ctx, 320, 240)
	ui_button(&ctx, c"a")
	ui_layout* lo = ui_layout_top(&ctx)
	float32 first_right = lo.last_right
	ui_same_line(&ctx)
	ui_button(&ctx, c"b")
	# second button starts right of the first, on the same row
	asserts(c"same row", lo.last_top == 8.0)
	asserts(c"to the right", lo.last_right > first_right)
	ui_button(&ctx, c"c")
	# back to the stack: below both, at the left origin
	asserts(c"next row", lo.last_top > 8.0)
	ui_end(&ctx)
	ui_render_destroy(&r)
