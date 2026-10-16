# Headless grapheme editing and IME preview/commit regression tests.
# wbuild: name=graphics_ui_text_input_test arch_only=x64
import lib.testing
import graphics.ui.testing
import graphics.ui.grapheme
import graphics.input_queue


void test_grapheme_editing():
	ui_textarea_state st
	ui_textarea_init(&st)
	# Decomposed accent, emoji ZWJ family, regional-indicator flag.
	char* cluster = c"a\xcc\x81"
	ui_textarea_set(&st, cluster)
	ui_textarea_set_caret(&st, 3)
	ui_textarea_nav(&st, GFX_NAV_LEFT, 0, 1)
	assert_equal(0, ui_textarea_caret_offset(&st))
	ui_textarea_nav(&st, GFX_NAV_RIGHT, GFX_MOD_SHIFT, 1)
	assert_equal(3, ui_textarea_caret_offset(&st))
	assert_equal(0, st.sel_anchor)
	ui_textarea_nav(&st, GFX_NAV_DELETE, 0, 1)
	assert_equal(0, st.buf.length)
	ui_textarea_set(&st, c"\xf0\x9f\x91\xa9\xe2\x80\x8d\xf0\x9f\x91\xa7x")
	ui_textarea_set_caret(&st, 11)
	ui_textarea_backspace(&st)
	assert_equal(1, st.buf.length)
	assert_equal('x', st.buf.data[0])
	ui_textarea_set(&st, c"\xf0\x9f\x87\xba\xf0\x9f\x87\xb8!")
	ui_textarea_set_caret(&st, 0)
	ui_textarea_nav(&st, GFX_NAV_DELETE, 0, 1)
	assert_equal(1, st.buf.length)
	ui_textarea_free(&st)


void test_vertical_motion_stays_on_grapheme_boundary():
	ui_textarea_state st
	ui_textarea_init(&st)
	ui_textarea_set(&st, c"xy\na\xcc\x81z")
	ui_textarea_set_caret(&st, 2)
	st.caret_goal_col = 2
	ui_textarea_nav(&st, GFX_NAV_DOWN, 0, 1)
	assert_equal(0, st.caret_col)
	ui_textarea_free(&st)


void test_textbox_truncates_whole_graphemes():
	ui_textbox_state st
	ui_textbox_init(&st)
	char[132] value
	for i in range(126): value[i] = 'a'
	value[126] = 'e'
	value[127] = 204
	value[128] = 129
	value[129] = 0
	ui_textbox_set(&st, &value[0])
	assert_equal(126, st.length)
	ui_textbox_set(&st, c"a\xcc\x81")
	ui_textbox_backspace(&st)
	assert_equal(0, st.length)


void test_preedit_is_separate_from_committed_text():
	ui_fixture fx
	ui_context* ctx = ui_fixture_init(&fx)
	ui_textbox_state st
	ui_textbox_init(&st)
	ui_textbox_set(&st, c"a")
	ctx.focus = 1
	ui_test_event(ctx, GFX_EVENT_PREEDIT_BEGIN, 0, 1, 0, 0)
	ui_test_event(ctx, GFX_EVENT_PREEDIT_TEXT, 0x4e2d, 1, 0, 0)
	ui_begin(ctx, 320, 200)
	ui_textbox(ctx, 200.0, &st)
	ui_end(ctx)
	assert_equal(1, st.length)
	assert_equal(3, ctx.preedit_length)
	assert_equal(1, ctx.preedit_active)
	# Snapshot replacement doesn't accumulate obsolete preedit.
	ui_test_event(ctx, GFX_EVENT_PREEDIT_BEGIN, 0, 1, 0, 0)
	ui_test_event(ctx, GFX_EVENT_PREEDIT_TEXT, 0x1f600, 1, 0, 0)
	assert_equal(4, ctx.preedit_length)
	ui_test_event(ctx, GFX_EVENT_PREEDIT_END, 0, 1, 0, 0)
	ui_test_char(ctx, 0x4e2d)
	ui_begin(ctx, 320, 200)
	ui_textbox(ctx, 200.0, &st)
	ui_end(ctx)
	assert_equal(4, st.length)
	assert_equal(0, ctx.preedit_length)
	assert_equal(0, ctx.preedit_active)
	ui_render_destroy(&fx.r)


void test_preedit_focus_and_invalid_scalars():
	ui_fixture fx
	ui_context* ctx = ui_fixture_init(&fx)
	ctx.focus = 1
	ui_test_event(ctx, GFX_EVENT_PREEDIT_BEGIN, 0, 1, 0, 0)
	ui_test_event(ctx, GFX_EVENT_PREEDIT_TEXT, 0xd800, 1, 0, 0)
	ui_test_event(ctx, GFX_EVENT_PREEDIT_TEXT, 0x110000, 1, 0, 0)
	ui_test_event(ctx, GFX_EVENT_PREEDIT_TEXT, 'x', 2, 0, 0)
	assert_equal(0, ctx.preedit_length)
	ui_test_event(ctx, GFX_EVENT_PREEDIT_TEXT, 'a', 1, 0, 0)
	ui_test_event(ctx, GFX_EVENT_PREEDIT_END, 0, 2, 0, 0)
	assert_equal(1, ctx.preedit_length)
	ctx.focus = 2
	ui_begin(ctx, 320, 200)
	ui_end(ctx)
	assert_equal(0, ctx.preedit_active)
	ui_render_destroy(&fx.r)


void test_navigation_then_typing_uses_updated_caret():
	ui_fixture fx
	ui_context* ctx = ui_fixture_init(&fx)
	ui_textbox_state st
	ui_textbox_init(&st)
	ui_textbox_set(&st, c"ab")
	ctx.focus = 1
	gfx_input_queue queue
	gfx_input_queue_init(&queue)
	gfx_input_queue_push(&queue, GFX_EVENT_NAV, GFX_NAV_LEFT, 0, 0, 0)
	gfx_input_queue_push(&queue, GFX_EVENT_CHAR, 'X', 0, 0, 0)
	for frame in range(2):
		gfx_input_queue_begin(&queue)
		gfx_event event
		while (gfx_input_queue_next(&queue, &event)): ui_feed_event(ctx, &event)
		ui_begin(ctx, 320, 200)
		ui_textbox(ctx, 200.0, &st)
		ui_end(ctx)
	assert_strings_equal(c"aXb", &st.text[0])
	assert_equal(2, st.caret)
	gfx_input_queue_free(&queue)
	ui_render_destroy(&fx.r)


# Solid 2px-wide quads (u0 == u1) on the base layer: the drawn carets.
# Glyph quads sample a texture span and the preedit underline is 1px tall.
int caret_quads(ui_renderer* r, float32* out_x):
	int found = 0
	float32* v = r.layer_verts[UI_LAYER_BASE]
	int quad = 0
	while (quad * 6 < r.layer_vert_count[UI_LAYER_BASE]):
		float32* q = &v[quad * 48]
		float32 w = q[8] - q[0]
		float32 h = q[17] - q[1]
		if ((w == 2.0) && (h > 1.0) && (q[2] == q[10])):
			out_x[0] = q[0]
			found = found + 1
		quad = quad + 1
	return found


# The preedit underline: a solid 1px-tall quad; returns its right edge.
float32 underline_end(ui_renderer* r):
	float32* v = r.layer_verts[UI_LAYER_BASE]
	int quad = 0
	while (quad * 6 < r.layer_vert_count[UI_LAYER_BASE]):
		float32* q = &v[quad * 48]
		if (((q[17] - q[1]) == 1.0) && (q[2] == q[10]) && (q[8] > q[0])): return q[8]
		quad = quad + 1
	return 0.0 - 1.0


# A composing word shows one caret, after the preview (as Android and iOS
# fields do), not a stale caret under its first letter.
void test_preedit_carries_the_caret():
	ui_fixture fx
	ui_context* ctx = ui_fixture_init(&fx)
	ui_textbox_state st
	ui_textbox_init(&st)
	ui_textbox_set(&st, c"a")
	ctx.focus = 1
	float32 x = 0.0
	ui_begin(ctx, 320, 200)
	ui_textbox(ctx, 200.0, &st)
	ui_end(ctx)
	assert_equal(1, caret_quads(&fx.r, &x))
	float32 committed_x = x
	ui_test_event(ctx, GFX_EVENT_PREEDIT_BEGIN, 0, 1, 0, 0)
	ui_test_event(ctx, GFX_EVENT_PREEDIT_TEXT, 'x', 1, 0, 0)
	ui_test_event(ctx, GFX_EVENT_PREEDIT_TEXT, 'y', 1, 0, 0)
	ui_begin(ctx, 320, 200)
	ui_textbox(ctx, 200.0, &st)
	ui_end(ctx)
	assert_equal(1, caret_quads(&fx.r, &x))
	asserts(c"textbox caret follows the preedit", x > committed_x + 4.0)
	asserts(c"textbox caret at the preedit end", x == underline_end(&fx.r))
	ui_test_event(ctx, GFX_EVENT_PREEDIT_END, 0, 1, 0, 0)
	ui_begin(ctx, 320, 200)
	ui_textbox(ctx, 200.0, &st)
	ui_end(ctx)
	assert_equal(1, caret_quads(&fx.r, &x))
	asserts(c"caret returns once the preedit ends", x == committed_x)
	ui_textarea_state ta
	ui_textarea_init(&ta)
	ui_textarea_set(&ta, c"a")
	ui_rect area = ui_rect_new(0.0, 0.0, 300.0, 120.0)
	ui_test_event(ctx, GFX_EVENT_PREEDIT_BEGIN, 0, 1, 0, 0)
	ui_test_event(ctx, GFX_EVENT_PREEDIT_TEXT, 'x', 1, 0, 0)
	ui_begin(ctx, 320, 200)
	ui_textarea(ctx, area, &ta)
	ui_end(ctx)
	assert_equal(1, caret_quads(&fx.r, &x))
	asserts(c"textarea caret at the preedit end", x == underline_end(&fx.r))
	ui_textarea_free(&ta)
	ui_render_destroy(&fx.r)
