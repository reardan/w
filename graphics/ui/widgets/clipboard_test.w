# Headless tests for text selection and the clipboard in ui_textbox and
# ui_textarea (docs/projects/ui_clipboard.md, issue #850): Shift+arrows,
# Home/End, Ctrl/Cmd+A, mouse drag and Shift+click selection, copy/cut/
# paste through the context's clipboard, the deferred paste pump over the
# in-process clipboard (a null window), and the shared store's line-end
# normalization. No GL context or display.
# x64-only: the widget set imports graphics.gl/graphics.window, which
# link libGL/libX11 on the 64-bit Linux targets.
# wbuild: name=graphics_ui_clipboard_test arch_only=x64
import lib.testing
import graphics.event
import graphics.clipboard_store
import graphics.ui.rect
import graphics.ui.theme
import graphics.ui.render
import graphics.ui.widgets
import graphics.ui.testing


# A 200-wide textbox claims (8,8,200,32); its text starts at x=16.
int box_frame(ui_context* ctx, ui_textbox_state* st):
	ui_begin(ctx, 320, 240)
	int submitted = ui_textbox(ctx, 200.0, st)
	ui_end(ctx)
	return submitted


int box_x(char* text, int bytes):
	return 16 + ui_text_prefix_width(text, bytes, 2)


ui_rect area():
	return ui_rect_new(10.0, 10.0, 260.0, 160.0)


int area_frame(ui_context* ctx, ui_textarea_state* st):
	ui_begin(ctx, 320, 240)
	int changed = ui_textarea(ctx, area(), st)
	ui_end(ctx)
	return changed


void command(ui_context* ctx, int code, int mods):
	ui_test_event(ctx, GFX_EVENT_CHAR, code, 0, 0, mods)


char* box_text(ui_textbox_state* st):
	return &st.text[0]


void test_textbox_shift_navigation_selects():
	ui_fixture fx
	ui_context* ctx = ui_fixture_init(&fx)
	ui_textbox_state st
	ui_textbox_init(&st)
	ui_textbox_set(&st, c"hello world")
	ctx.focus = 1
	ui_test_key(ctx, GFX_NAV_LEFT, GFX_MOD_SHIFT)
	ui_test_key(ctx, GFX_NAV_LEFT, GFX_MOD_SHIFT)
	box_frame(ctx, &st)
	assert_equal(1, ui_textbox_has_selection(&st))
	assert_equal(9, ui_textbox_sel_start(&st))
	assert_equal(11, ui_textbox_sel_end(&st))
	# Shift+Home extends from the same anchor to the start.
	ui_test_key(ctx, GFX_NAV_HOME, GFX_MOD_SHIFT)
	box_frame(ctx, &st)
	assert_equal(0, ui_textbox_sel_start(&st))
	assert_equal(11, ui_textbox_sel_end(&st))
	# Shift+End collapses back onto the anchor.
	ui_test_key(ctx, GFX_NAV_END, GFX_MOD_SHIFT)
	box_frame(ctx, &st)
	assert_equal(0, ui_textbox_has_selection(&st))
	# Shift+Home, then a plain arrow drops the selection.
	ui_test_key(ctx, GFX_NAV_HOME, GFX_MOD_SHIFT)
	ui_test_nav(ctx, GFX_NAV_RIGHT)
	box_frame(ctx, &st)
	assert_equal(0, ui_textbox_has_selection(&st))
	assert_equal(1, st.caret)
	ui_render_destroy(&fx.r)


void test_textbox_typing_backspace_and_delete_replace_selection():
	ui_fixture fx
	ui_context* ctx = ui_fixture_init(&fx)
	ui_textbox_state st
	ui_textbox_init(&st)
	ui_textbox_set(&st, c"hello world")
	ctx.focus = 1
	# Select "world" and type over it.
	ui_test_key(ctx, GFX_NAV_HOME, 0)
	for i in range(6): ui_test_nav(ctx, GFX_NAV_RIGHT)
	ui_test_key(ctx, GFX_NAV_END, GFX_MOD_SHIFT)
	box_frame(ctx, &st)
	ui_test_char(ctx, 'W')
	box_frame(ctx, &st)
	assert_strings_equal(c"hello W", box_text(&st))
	assert_equal(7, st.caret)
	assert_equal(1, st.edited)
	# Backspace removes a selection whole.
	ui_test_key(ctx, GFX_NAV_LEFT, GFX_MOD_SHIFT)
	ui_test_key(ctx, GFX_NAV_LEFT, GFX_MOD_SHIFT)
	box_frame(ctx, &st)
	ui_test_char(ctx, 8)
	box_frame(ctx, &st)
	assert_strings_equal(c"hello", box_text(&st))
	# Delete removes the character after the caret, or the selection.
	ui_test_nav(ctx, GFX_NAV_HOME)
	ui_test_nav(ctx, GFX_NAV_DELETE)
	box_frame(ctx, &st)
	assert_strings_equal(c"ello", box_text(&st))
	ui_test_key(ctx, GFX_NAV_END, GFX_MOD_SHIFT)
	ui_test_nav(ctx, GFX_NAV_DELETE)
	box_frame(ctx, &st)
	assert_strings_equal(c"", box_text(&st))
	ui_render_destroy(&fx.r)


# CHAR and NAV events queue separately and a widget drains CHARs first,
# so a test that mixes them runs the motions in a frame of their own.
# Ctrl+A / Ctrl+C / Ctrl+X / Ctrl+V as each backend reports them: X11 and
# Win32 send the control code with Ctrl, the web host the letter with
# Ctrl, Cocoa the letter with Command (Super).
void test_textbox_clipboard_commands_on_every_backend_encoding():
	list[int] all = list[int]{1, 'a', 'A'}
	list[int] copy = list[int]{3, 'c', 'C'}
	list[int] cut = list[int]{24, 'x', 'x'}
	list[int] paste = list[int]{22, 'v', 'V'}
	list[int] mods = list[int]{GFX_MOD_CTRL, GFX_MOD_CTRL, GFX_MOD_SUPER}
	for k in range(3):
		ui_fixture fx
		ui_context* ctx = ui_fixture_init(&fx)
		ui_textbox_state st
		ui_textbox_init(&st)
		ui_textbox_set(&st, c"Café crème")
		ctx.focus = 1
		command(ctx, all[k], mods[k])
		command(ctx, copy[k], mods[k])
		box_frame(ctx, &st)
		assert_strings_equal(c"Café crème", ui_clipboard_copied(ctx))
		assert_equal(0, cast(int, ui_clipboard_copied(ctx)))
		assert_equal(0, st.edited)
		# Cut: copy then remove the selection.
		ui_test_nav(ctx, GFX_NAV_END)
		ui_test_key(ctx, GFX_NAV_LEFT, GFX_MOD_SHIFT)
		ui_test_key(ctx, GFX_NAV_LEFT, GFX_MOD_SHIFT)
		ui_test_key(ctx, GFX_NAV_LEFT, GFX_MOD_SHIFT)
		ui_test_key(ctx, GFX_NAV_LEFT, GFX_MOD_SHIFT)
		ui_test_key(ctx, GFX_NAV_LEFT, GFX_MOD_SHIFT)
		box_frame(ctx, &st)
		command(ctx, cut[k], mods[k])
		box_frame(ctx, &st)
		assert_strings_equal(c"crème", ui_clipboard_copied(ctx))
		assert_strings_equal(c"Café ", box_text(&st))
		assert_equal(1, st.edited)
		# Paste is deferred: nothing until the platform answers.
		command(ctx, paste[k], mods[k])
		box_frame(ctx, &st)
		assert_equal(1, ctx.clip_paste_id)
		assert_strings_equal(c"Café ", box_text(&st))
		ui_clipboard_deliver(ctx, c"naïve\nline")
		box_frame(ctx, &st)
		# A single line turns the newline into a space.
		assert_strings_equal(c"Café naïve line", box_text(&st))
		assert_equal(0, ctx.clip_paste_id)
		# Copy without a selection leaves the clipboard alone.
		command(ctx, copy[k], mods[k])
		box_frame(ctx, &st)
		assert_equal(0, cast(int, ui_clipboard_copied(ctx)))
		# Ctrl+Alt (AltGr) is typing, not a command: the letter inserts.
		command(ctx, 'c', GFX_MOD_CTRL | GFX_MOD_ALT)
		box_frame(ctx, &st)
		assert_strings_equal(c"Café naïve linec", box_text(&st))
		ui_render_destroy(&fx.r)
	__w_list_free(cast(__w_list*, all))
	__w_list_free(cast(__w_list*, copy))
	__w_list_free(cast(__w_list*, cut))
	__w_list_free(cast(__w_list*, paste))
	__w_list_free(cast(__w_list*, mods))


void test_textbox_paste_truncates_at_capacity():
	ui_textbox_state st
	ui_textbox_init(&st)
	ui_textbox_set(&st, c"ab")
	st.caret = 1
	char[300] long_text
	for i in range(299):
		long_text[i] = 'x'
		if (i % 2): long_text[i] = 7
	long_text[299] = 0
	ui_textbox_insert_text(&st, &long_text[0])
	# The bell characters are dropped; the x's fill to capacity.
	assert_equal(ui_textbox_capacity, st.length)
	assert_equal('a', st.text[0])
	assert_equal('b', st.text[st.length - 1])
	assert_equal(st.length - 1, st.caret)


void test_textbox_drag_and_shift_click_select():
	ui_fixture fx
	ui_context* ctx = ui_fixture_init(&fx)
	ui_textbox_state st
	ui_textbox_init(&st)
	ui_textbox_set(&st, c"select me")
	char* t = c"select me"
	# Press at boundary 1, drag to boundary 6, release there.
	ui_test_event(ctx, GFX_EVENT_MOUSE_DOWN, 1, box_x(t, 1), 20, 0)
	box_frame(ctx, &st)
	assert_equal(1, st.caret)
	assert_equal(0, ui_textbox_has_selection(&st))
	ctx.input.mouse_x = box_x(t, 6)
	box_frame(ctx, &st)
	assert_equal(1, ctx.pointer_mode)
	assert_equal(1, ui_textbox_sel_start(&st))
	assert_equal(6, ui_textbox_sel_end(&st))
	ui_test_event(ctx, GFX_EVENT_MOUSE_UP, 1, box_x(t, 6), 20, 0)
	box_frame(ctx, &st)
	assert_equal(6, ui_textbox_sel_end(&st))
	# Dragging past the left edge clamps to the start.
	ui_test_event(ctx, GFX_EVENT_MOUSE_DOWN, 1, box_x(t, 3), 20, 0)
	box_frame(ctx, &st)
	ctx.input.mouse_x = 0
	box_frame(ctx, &st)
	assert_equal(0, ui_textbox_sel_start(&st))
	assert_equal(3, ui_textbox_sel_end(&st))
	ui_test_event(ctx, GFX_EVENT_MOUSE_UP, 1, 0, 20, 0)
	box_frame(ctx, &st)
	# A plain click collapses the selection.
	ui_test_click(ctx, box_x(t, 2), 20)
	box_frame(ctx, &st)
	assert_equal(0, ui_textbox_has_selection(&st))
	assert_equal(2, st.caret)
	# Shift+click extends from the caret.
	ui_test_event(ctx, GFX_EVENT_MOUSE_DOWN, 1, box_x(t, 9), 20, GFX_MOD_SHIFT)
	ui_test_event(ctx, GFX_EVENT_MOUSE_UP, 1, box_x(t, 9), 20, GFX_MOD_SHIFT)
	box_frame(ctx, &st)
	assert_equal(2, ui_textbox_sel_start(&st))
	assert_equal(9, ui_textbox_sel_end(&st))
	ui_render_destroy(&fx.r)


# The selection draws a highlight quad behind the glyphs only while it
# exists and the field is focused.
void test_textbox_selection_highlight_draws():
	ui_fixture fx
	ui_context* ctx = ui_fixture_init(&fx)
	ui_textbox_state st
	ui_textbox_init(&st)
	ui_textbox_set(&st, c"abc")
	ctx.focus = 1
	box_frame(ctx, &st)
	int plain = fx.r.layer_vert_count[UI_LAYER_BASE]
	ui_textbox_select_all(&st)
	box_frame(ctx, &st)
	assert_equal(plain + 6, fx.r.layer_vert_count[UI_LAYER_BASE])
	ctx.focus = 0
	box_frame(ctx, &st)
	asserts(c"no highlight unfocused", fx.r.layer_vert_count[UI_LAYER_BASE] < plain + 6)
	ui_render_destroy(&fx.r)


void test_textbox_reports_selection_to_accessibility():
	ui_fixture fx
	ui_context* ctx = ui_fixture_init(&fx)
	ui_access_tree* tree = ui_access_tree_new(64, 65536)
	ui_access_capture(ctx, tree)
	ui_textbox_state st
	ui_textbox_init(&st)
	ui_textbox_set(&st, c"héllo")
	ctx.focus = 1
	ui_test_key(ctx, GFX_NAV_LEFT, GFX_MOD_SHIFT)
	ui_test_key(ctx, GFX_NAV_LEFT, GFX_MOD_SHIFT)
	box_frame(ctx, &st)
	ui_access_node* node = ui_access_find(tree, 1)
	asserts(c"textbox node", node != 0)
	# Character offsets: "hél|lo|" selects characters 3..5.
	assert_equal(3, node.selection_start)
	assert_equal(5, node.selection_end)
	ui_access_capture(ctx, 0)
	ui_access_tree_free(tree)
	ui_render_destroy(&fx.r)


void test_textarea_drag_selects_across_lines_and_copies():
	ui_fixture fx
	ui_context* ctx = ui_fixture_init(&fx)
	ui_textarea_state st
	ui_textarea_init(&st)
	ui_textarea_set(&st, c"first line\nsecond line\nthird")
	int line_h = ui_textarea_line_height(ctx)
	# The view starts at area + pad.
	int vx = 10 + ctx.theme.pad
	int vy = 10 + ctx.theme.pad
	int x6 = vx + ui_text_prefix_width(c"first line", 6, 2)
	int x3 = vx + ui_text_prefix_width(c"second line", 3, 2)
	ui_test_event(ctx, GFX_EVENT_MOUSE_DOWN, 1, x6, vy + line_h / 2, 0)
	area_frame(ctx, &st)
	assert_equal(1, ctx.focus)
	assert_equal(0, ui_textarea_has_selection(&st))
	ctx.input.mouse_x = x3
	ctx.input.mouse_y = vy + line_h + line_h / 2
	area_frame(ctx, &st)
	ui_test_event(ctx, GFX_EVENT_MOUSE_UP, 1, x3, vy + line_h + line_h / 2, 0)
	area_frame(ctx, &st)
	assert_equal(6, ui_textarea_sel_start(&st))
	assert_equal(14, ui_textarea_sel_end(&st))
	command(ctx, 3, GFX_MOD_CTRL)
	assert_equal(0, area_frame(ctx, &st))
	assert_strings_equal(c"line\nsec", ui_clipboard_copied(ctx))
	# Cut removes it and reports a change.
	command(ctx, 'x', GFX_MOD_SUPER)
	assert_equal(1, area_frame(ctx, &st))
	assert_strings_equal(c"line\nsec", ui_clipboard_copied(ctx))
	assert_strings_equal(c"first ond line\nthird", st.buf.data)
	# Shift+click extends from the caret to the click.
	ui_test_event(ctx, GFX_EVENT_MOUSE_DOWN, 1, vx + 200, vy + line_h / 2, GFX_MOD_SHIFT)
	ui_test_event(ctx, GFX_EVENT_MOUSE_UP, 1, vx + 200, vy + line_h / 2, GFX_MOD_SHIFT)
	area_frame(ctx, &st)
	assert_equal(6, ui_textarea_sel_start(&st))
	assert_equal(14, ui_textarea_sel_end(&st))
	ui_textarea_free(&st)
	ui_render_destroy(&fx.r)


# The pump over a null window: copy publishes to the in-process
# clipboard, paste requests it and the text lands a frame later, CR LF
# normalized.
void test_textarea_paste_through_the_pump():
	ui_fixture fx
	ui_context* ctx = ui_fixture_init(&fx)
	ui_textarea_state st
	ui_textarea_init(&st)
	ui_textarea_set(&st, c"AB")
	ctx.focus = 1
	gfx_window* none = cast(gfx_window*, 0)
	gfx_clipboard_set(none, c"x\r\ny\rz")
	ui_test_nav(ctx, GFX_NAV_RIGHT)
	area_frame(ctx, &st)
	command(ctx, 22, GFX_MOD_CTRL)
	assert_equal(0, area_frame(ctx, &st))
	ui_clipboard_pump(ctx, none)
	assert_equal(1, area_frame(ctx, &st))
	assert_strings_equal(c"Ax\ny\nzB", st.buf.data)
	assert_equal(2, st.caret_line)
	assert_equal(1, st.caret_col)
	# Copy goes out through the pump to the same clipboard.
	command(ctx, 'a', GFX_MOD_CTRL)
	command(ctx, 'c', GFX_MOD_CTRL)
	area_frame(ctx, &st)
	ui_clipboard_pump(ctx, none)
	gfx_clipboard_request(none)
	char* back = gfx_clipboard_take(none)
	assert_strings_equal(c"Ax\ny\nzB", back)
	free(back)
	assert_equal(0, cast(int, gfx_clipboard_take(none)))
	# A paste whose field lost focus is abandoned.
	command(ctx, 'v', GFX_MOD_CTRL)
	area_frame(ctx, &st)
	ctx.focus = 0
	ui_clipboard_pump(ctx, none)
	assert_equal(0, ctx.clip_paste_id)
	ui_textarea_free(&st)
	ui_render_destroy(&fx.r)


void test_store_normalizes_line_ends_across_chunks():
	gfx_clipboard_store s
	gfx_clipboard_store_init(&s)
	assert_equal(0, cast(int, gfx_clipboard_store_take(&s)))
	gfx_clipboard_store_begin(&s, GFX_CLIPBOARD_INCR)
	gfx_clipboard_store_append(&s, c"a\r", 2)
	gfx_clipboard_store_append(&s, c"\nb\r\r\n", 5)
	char[3] with_nul
	with_nul[0] = 'c'
	with_nul[1] = 0
	with_nul[2] = 'd'
	gfx_clipboard_store_append(&s, &with_nul[0], 3)
	assert_equal(0, cast(int, gfx_clipboard_store_take(&s)))
	gfx_clipboard_store_arrive(&s)
	char* text = gfx_clipboard_store_take(&s)
	assert_strings_equal(c"a\nb\n\ncd", text)
	free(text)
	# An empty read still arrives, as "".
	gfx_clipboard_store_begin(&s, GFX_CLIPBOARD_REQUESTED)
	gfx_clipboard_store_arrive(&s)
	text = gfx_clipboard_store_take(&s)
	assert_strings_equal(c"", text)
	free(text)
	gfx_clipboard_store_free(&s)
