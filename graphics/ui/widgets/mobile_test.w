# wbuild: name=graphics_ui_mobile_test arch_only=x64
# Mobile event semantics, clipped hit tests, text focus and viewport shrink.
import lib.testing
import graphics.ui.testing
import graphics.ui.mobile_demo_shared


void mobile_scroll_frame(ui_context* ctx, ui_scroll_state* st):
	ui_begin(ctx, 320, 240)
	ui_scroll_begin(ctx, ui_rect_new(8.0, 8.0, 280.0, 100.0), st)
	for i in range(10): ui_label(ctx, c"Row")
	ui_scroll_end(ctx, st)
	ui_end(ctx)


void test_mobile_cancel_never_clicks():
	ui_fixture fx
	ui_context* ctx = ui_fixture_init(&fx)
	ui_test_event(ctx, GFX_EVENT_MOUSE_DOWN, 1, 20, 20, 0)
	ui_begin(ctx, 320, 240)
	ui_button(ctx, c"Save")
	ui_end(ctx)
	ui_test_event(ctx, GFX_EVENT_POINTER_CANCEL, 0, 20, 20, 0)
	ui_test_event(ctx, GFX_EVENT_MOUSE_UP, 1, 20, 20, 0)
	ui_begin(ctx, 320, 240)
	assert_equal(0, ui_button(ctx, c"Save"))
	assert_equal(0, ctx.input.mouse_down)
	ui_end(ctx)
	ui_render_destroy(&fx.r)


void test_mobile_pixel_scroll_and_clamp():
	ui_fixture fx
	ui_context* ctx = ui_fixture_init(&fx)
	ui_scroll_state st
	ui_scroll_init(&st)
	mobile_scroll_frame(ctx, &st)
	ui_test_event(ctx, GFX_EVENT_SCROLL_PIXELS, 17, 40, 40, 0)
	mobile_scroll_frame(ctx, &st)
	asserts(c"pixel scrolling is not notch-scaled", st.offset_y == 17.0)
	ui_test_event(ctx, GFX_EVENT_SCROLL_PIXELS, 0 - 40, 40, 40, 0)
	mobile_scroll_frame(ctx, &st)
	asserts(c"top clamps", st.offset_y == 0.0)
	assert_equal(0, ctx.input.scroll_pixels_y)
	ui_render_destroy(&fx.r)


void test_mobile_clipped_field_cannot_focus():
	ui_fixture fx
	ui_context* ctx = ui_fixture_init(&fx)
	ui_textbox_state st
	ui_textbox_init(&st)
	ui_test_click(ctx, 20, 20)
	ui_begin(ctx, 320, 240)
	ui_clip_push(&fx.r, ui_rect_new(100.0, 100.0, 100.0, 100.0))
	ui_textbox(ctx, 200.0, &st)
	ui_clip_pop(&fx.r)
	assert_equal(0, ctx.focus)
	assert_equal(0, ctx.text_input_id)
	ui_end(ctx)
	ui_render_destroy(&fx.r)


void test_mobile_editor_declared_and_disabled():
	ui_fixture fx
	ui_context* ctx = ui_fixture_init(&fx)
	ui_textbox_state st
	ui_textbox_init(&st)
	ui_test_click(ctx, 20, 20)
	ui_begin(ctx, 320, 240)
	ui_textbox(ctx, 200.0, &st)
	assert_equal(ctx.focus, ctx.text_input_id)
	assert_equal(0, ctx.text_input_multiline)
	ui_end(ctx)
	ui_test_char(ctx, 233)
	ui_begin(ctx, 320, 240)
	ui_disable(ctx, 1)
	ui_textbox(ctx, 200.0, &st)
	assert_equal(0, st.length)
	assert_equal(0, ctx.text_input_id)
	ui_end(ctx)
	ui_render_destroy(&fx.r)


void test_mobile_keyboard_resize_reveals_field():
	ui_fixture fx
	ui_context* ctx = ui_fixture_init(&fx)
	ui_mobile_demo_state st
	ui_mobile_demo_init(&st)
	ctx.theme = &st.theme
	# Email is at y=252..300 with the touch theme. Focus on a tall screen.
	ui_test_click(ctx, 30, 270)
	ui_begin(ctx, 390, 720)
	ui_mobile_demo_body(ctx, &st)
	asserts(c"email focused", ctx.text_input_id != 0)
	ui_end(ctx)
	ui_begin(ctx, 390, 250)
	ui_mobile_demo_body(ctx, &st)
	asserts(c"keyboard viewport scrolls focused field into view", st.page.offset_y > 0.0)
	ui_end(ctx)
	ui_textarea_free(&st.notes)
	ui_render_destroy(&fx.r)


void test_mobile_textarea_scroll_does_not_snap_back():
	ui_fixture fx
	ui_context* ctx = ui_fixture_init(&fx)
	ui_textarea_state st
	ui_textarea_init(&st)
	ui_textarea_set(&st, c"a\nb\nc\nd\ne\nf\ng\nh\ni\nj\nk\nl\n")
	ui_rect area = ui_rect_new(8.0, 8.0, 280.0, 100.0)
	ui_begin(ctx, 320, 240)
	ui_textarea(ctx, area, &st)
	ui_end(ctx)
	ui_test_event(ctx, GFX_EVENT_SCROLL_PIXELS, 40, 30, 30, 0)
	ui_begin(ctx, 320, 240)
	ui_textarea(ctx, area, &st)
	ui_end(ctx)
	ui_begin(ctx, 320, 240)
	ui_textarea(ctx, area, &st)
	asserts(c"scroll remains away from caret", st.scroll.offset_y == 40.0)
	ui_end(ctx)
	ui_textarea_free(&st)
	ui_render_destroy(&fx.r)


void test_mobile_batched_cancel_discards_press():
	ui_fixture fx
	ui_context* ctx = ui_fixture_init(&fx)
	ui_test_click(ctx, 20, 20)
	ui_test_event(ctx, GFX_EVENT_POINTER_CANCEL, 0, 20, 20, 0)
	ui_begin(ctx, 320, 240)
	assert_equal(0, ui_button(ctx, c"Save"))
	assert_equal(0, ctx.active)
	ui_end(ctx)
	ui_render_destroy(&fx.r)


void test_mobile_popup_blocks_editor_bridge():
	ui_fixture fx
	ui_context* ctx = ui_fixture_init(&fx)
	ui_textbox_state st
	ui_textbox_init(&st)
	ui_test_click(ctx, 20, 20)
	ui_begin(ctx, 320, 240)
	ui_textbox(ctx, 200.0, &st)
	assert_equal(1, ui_text_input_active(ctx))
	# Popup opens after the field was issued in the same frame.
	ui_popup_open(ctx, 900)
	assert_equal(0, ui_text_input_active(ctx))
	ui_end(ctx)
	ui_begin(ctx, 320, 240)
	ui_textbox(ctx, 200.0, &st)
	assert_equal(0, ctx.text_input_id)
	# A popup's own field still gets the keyboard after its scope ends.
	ui_popup_begin(ctx, 900, ui_rect_new(20.0, 20.0, 240.0, 160.0), UI_LAYER_POPUP)
	ctx.focus = ctx.next_id
	ui_textbox(ctx, 200.0, &st)
	ui_popup_end(ctx)
	assert_equal(1, ui_text_input_active(ctx))
	ui_end(ctx)
	ui_render_destroy(&fx.r)


void test_mobile_nested_scroll_claims_once():
	ui_fixture fx
	ui_context* ctx = ui_fixture_init(&fx)
	ui_scroll_state outer
	ui_scroll_state inner
	ui_scroll_init(&outer)
	ui_scroll_init(&inner)
	for frame in range(2):
		if (frame == 1): ui_test_event(ctx, GFX_EVENT_SCROLL_PIXELS, 23, 40, 40, 0)
		ui_begin(ctx, 320, 240)
		ui_scroll_begin(ctx, ui_rect_new(8.0, 8.0, 280.0, 160.0), &outer)
		ui_scroll_begin(ctx, ui_rect_new(16.0, 16.0, 240.0, 100.0), &inner)
		for i in range(10): ui_label(ctx, c"Inner row")
		ui_scroll_end(ctx, &inner)
		for i in range(10): ui_label(ctx, c"Outer row")
		ui_scroll_end(ctx, &outer)
		ui_end(ctx)
	asserts(c"inner claims exact pixels", inner.offset_y == 23.0)
	asserts(c"outer cannot consume twice", outer.offset_y == 0.0)
	ui_render_destroy(&fx.r)


void test_mobile_cancel_clears_inert_scroll_drag():
	ui_fixture fx
	ui_context* ctx = ui_fixture_init(&fx)
	ui_scroll_state st
	ui_scroll_init(&st)
	mobile_scroll_frame(ctx, &st)
	# The scrollbar is at x=280..286; its first thumb starts at y=8.
	ui_test_event(ctx, GFX_EVENT_MOUSE_DOWN, 1, 283, 16, 0)
	mobile_scroll_frame(ctx, &st)
	asserts(c"thumb has capture", st.drag_id != 0)
	ui_test_event(ctx, GFX_EVENT_POINTER_CANCEL, 0, 283, 16, 0)
	ui_disable(ctx, 1)
	mobile_scroll_frame(ctx, &st)
	assert_equal(0, st.drag_id)
	ui_disable(ctx, 0)
	ui_test_event(ctx, GFX_EVENT_MOUSE_DOWN, 1, 20, 80, 0)
	mobile_scroll_frame(ctx, &st)
	assert_equal(0, st.drag_id)
	assert_equal(0, ctx.pointer_mode)
	ui_render_destroy(&fx.r)
