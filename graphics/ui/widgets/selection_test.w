# Headless tests for issue #910's selection and clipboard additions
# (docs/projects/ui_clipboard.md §6): double-click word and triple-click
# line selection in ui_textbox and ui_textarea (UAX #29 boundaries from
# lib/unicode_text.w) and dragging by words or lines after them, the
# PRIMARY selection (published on every selection change, pasted by a
# middle-click) through the pump over a null window, rich clipboard
# flavors, the CF_HTML wrapper and the backends' click counting.
# x64-only, like graphics_ui_clipboard_test: the widget set imports
# graphics.gl/graphics.window, which link libGL/libX11 on 64-bit Linux.
# wbuild: name=graphics_ui_selection_test arch_only=x64
import lib.testing
import lib.str
import graphics.event
import graphics.clipboard_store
import graphics.ui.rect
import graphics.ui.theme
import graphics.ui.render
import graphics.ui.widgets
import graphics.ui.testing


# A 300-wide textbox claims (8,8,300,32); its text starts at x=16.
void box_frame(ui_context* ctx, ui_textbox_state* st):
	ui_begin(ctx, 400, 240)
	ui_textbox(ctx, 300.0, st)
	ui_end(ctx)


# The middle of the glyph at byte offset i (of a byte wide), in window
# pixels.
int box_mid(char* text, int i, int bytes):
	return 16 + (ui_text_prefix_width(text, i, 2) + ui_text_prefix_width(text, i + bytes, 2)) / 2


int box_x_at(char* text, int bytes):
	return 16 + ui_text_prefix_width(text, bytes, 2)


void press(ui_context* ctx, int x, int y, int clicks):
	ui_test_event(ctx, GFX_EVENT_MOUSE_DOWN, 1, x, y, gfx_mods_with_clicks(0, clicks))


void release(ui_context* ctx, int x, int y):
	ui_test_event(ctx, GFX_EVENT_MOUSE_UP, 1, x, y, 0)


ui_rect area():
	return ui_rect_new(10.0, 10.0, 360.0, 160.0)


void area_frame(ui_context* ctx, ui_textarea_state* st):
	ui_begin(ctx, 400, 240)
	ui_textarea(ctx, area(), st)
	ui_end(ctx)


# The middle of byte i on textarea line `line` (text is that line).
int area_x(ui_context* ctx, char* text, int i):
	return 10 + ctx.theme.pad + (ui_text_prefix_width(text, i, 2) + ui_text_prefix_width(text, i + 1, 2)) / 2


int area_y(ui_context* ctx, int line):
	return 10 + ctx.theme.pad + line * ui_textarea_line_height(ctx) + ui_textarea_line_height(ctx) / 2


void test_click_counts_ride_in_mods():
	assert_equal(1, gfx_event_clicks(GFX_MOD_SHIFT))
	int mods = gfx_mods_with_clicks(GFX_MOD_SHIFT | GFX_MOD_CTRL, 3)
	assert_equal(3, gfx_event_clicks(mods))
	assert_equal(GFX_MOD_SHIFT | GFX_MOD_CTRL, mods & gfx_mod_keys)
	assert_equal(15, gfx_event_clicks(gfx_mods_with_clicks(0, 40)))
	assert_equal(1, gfx_event_clicks(gfx_mods_with_clicks(0, 0)))
	# The context keeps the count and hands widgets the keys alone.
	ui_fixture fx
	ui_context* ctx = ui_fixture_init(&fx)
	ui_test_event(ctx, GFX_EVENT_MOUSE_DOWN, 1, 5, 5, mods)
	assert_equal(3, ctx.input.clicks)
	assert_equal(GFX_MOD_SHIFT | GFX_MOD_CTRL, ctx.input.mods)
	ui_test_event(ctx, GFX_EVENT_MOUSE_DOWN, 2, 7, 9, 0)
	assert_equal(1, ctx.input.mouse_middle_pressed)
	assert_equal(7, ctx.input.middle_x)
	assert_equal(9, ctx.input.middle_y)
	ui_test_event(ctx, GFX_EVENT_POINTER_CANCEL, 0, 0, 0, 0)
	assert_equal(0, ctx.input.mouse_middle_pressed)
	ui_render_destroy(&fx.r)


void test_click_tracker_counts_runs():
	gfx_click_tracker t
	gfx_click_tracker_init(&t)
	assert_equal(1, gfx_click_tracker_press(&t, 1, 1000, 50, 50, 500, 4))
	assert_equal(2, gfx_click_tracker_press(&t, 1, 1300, 52, 49, 500, 4))
	assert_equal(3, gfx_click_tracker_press(&t, 1, 1700, 51, 51, 500, 4))
	# Too slow, too far, another button, or a clock that went backwards
	# each start a new run.
	assert_equal(1, gfx_click_tracker_press(&t, 1, 2300, 51, 51, 500, 4))
	assert_equal(1, gfx_click_tracker_press(&t, 1, 2400, 70, 51, 500, 4))
	assert_equal(1, gfx_click_tracker_press(&t, 3, 2500, 70, 51, 500, 4))
	assert_equal(1, gfx_click_tracker_press(&t, 3, 2000, 70, 51, 500, 4))
	assert_equal(2, gfx_click_tracker_press(&t, 3, 2100, 70, 51, 500, 4))


void test_textbox_double_click_selects_word_and_triple_the_line():
	ui_fixture fx
	ui_context* ctx = ui_fixture_init(&fx)
	ui_textbox_state st
	ui_textbox_init(&st)
	char* t = c"hello brave_new world!"
	ui_textbox_set(&st, t)
	# Single click on the 'r' of brave, then the second click of a double.
	press(ctx, box_mid(t, 7, 1), 20, 1)
	release(ctx, box_mid(t, 7, 1), 20)
	box_frame(ctx, &st)
	assert_equal(0, ui_textbox_has_selection(&st))
	press(ctx, box_mid(t, 7, 1), 20, 2)
	release(ctx, box_mid(t, 7, 1), 20)
	box_frame(ctx, &st)
	# "brave_new": ExtendNumLet joins the letters (UAX #29 WB13a/b).
	assert_equal(6, ui_textbox_sel_start(&st))
	assert_equal(15, ui_textbox_sel_end(&st))
	assert_strings_equal(c"brave_new", ui_primary_published(ctx))
	assert_equal(0, cast(int, ui_primary_published(ctx)))
	# The right half of the last letter still hits that letter's word.
	press(ctx, box_mid(t, 20, 1) + 2, 20, 2)
	release(ctx, box_mid(t, 20, 1) + 2, 20)
	box_frame(ctx, &st)
	assert_equal(16, ui_textbox_sel_start(&st))
	assert_equal(21, ui_textbox_sel_end(&st))
	# Punctuation and spaces are segments of their own.
	press(ctx, box_mid(t, 21, 1), 20, 2)
	release(ctx, box_mid(t, 21, 1), 20)
	box_frame(ctx, &st)
	assert_equal(21, ui_textbox_sel_start(&st))
	assert_equal(22, ui_textbox_sel_end(&st))
	# Triple-click: the whole line.
	press(ctx, box_mid(t, 2, 1), 20, 3)
	release(ctx, box_mid(t, 2, 1), 20)
	box_frame(ctx, &st)
	assert_equal(0, ui_textbox_sel_start(&st))
	assert_equal(22, ui_textbox_sel_end(&st))
	assert_strings_equal(t, ui_primary_published(ctx))
	# Copy after a double-click copies the word.
	press(ctx, box_mid(t, 1, 1), 20, 2)
	release(ctx, box_mid(t, 1, 1), 20)
	box_frame(ctx, &st)
	ui_test_event(ctx, GFX_EVENT_CHAR, 3, 0, 0, GFX_MOD_CTRL)
	box_frame(ctx, &st)
	assert_strings_equal(c"hello", ui_clipboard_copied(ctx))
	ui_render_destroy(&fx.r)


void test_textbox_double_click_keeps_multibyte_words_whole():
	ui_fixture fx
	ui_context* ctx = ui_fixture_init(&fx)
	ui_textbox_state st
	ui_textbox_init(&st)
	# "naïve café 3.14": ï and é are two bytes each.
	char* t = c"na\xc3\xafve caf\xc3\xa9 3.14"
	ui_textbox_set(&st, t)
	press(ctx, box_mid(t, 10, 2), 20, 2)
	box_frame(ctx, &st)
	assert_equal(7, ui_textbox_sel_start(&st))
	assert_equal(12, ui_textbox_sel_end(&st))
	release(ctx, box_mid(t, 10, 2), 20)
	box_frame(ctx, &st)
	# A decimal number is one word (WB11/WB12).
	press(ctx, box_mid(t, 15, 1), 20, 2)
	release(ctx, box_mid(t, 15, 1), 20)
	box_frame(ctx, &st)
	assert_equal(13, ui_textbox_sel_start(&st))
	assert_equal(17, ui_textbox_sel_end(&st))
	ui_render_destroy(&fx.r)


void test_textbox_drag_after_double_click_extends_by_words():
	ui_fixture fx
	ui_context* ctx = ui_fixture_init(&fx)
	ui_textbox_state st
	ui_textbox_init(&st)
	char* t = c"one two three four"
	ui_textbox_set(&st, t)
	press(ctx, box_mid(t, 5, 1), 20, 2)
	box_frame(ctx, &st)
	assert_equal(4, ui_textbox_sel_start(&st))
	assert_equal(7, ui_textbox_sel_end(&st))
	# Dragging into "three" grows to its end, never mid-word.
	ctx.input.mouse_x = box_mid(t, 9, 1)
	box_frame(ctx, &st)
	assert_equal(4, st.anchor)
	assert_equal(13, st.caret)
	# Back over "one": the anchor moves to the far end of "two".
	ctx.input.mouse_x = box_mid(t, 1, 1)
	box_frame(ctx, &st)
	assert_equal(7, st.anchor)
	assert_equal(0, st.caret)
	assert_strings_equal(c"one two", ui_primary_published(ctx))
	release(ctx, box_mid(t, 1, 1), 20)
	box_frame(ctx, &st)
	# A single click afterwards drags by characters again.
	press(ctx, box_x_at(t, 14), 20, 1)
	box_frame(ctx, &st)
	ctx.input.mouse_x = box_x_at(t, 16)
	box_frame(ctx, &st)
	assert_equal(14, ui_textbox_sel_start(&st))
	assert_equal(16, ui_textbox_sel_end(&st))
	release(ctx, box_x_at(t, 16), 20)
	box_frame(ctx, &st)
	ui_render_destroy(&fx.r)


void test_textarea_double_and_triple_click():
	ui_fixture fx
	ui_context* ctx = ui_fixture_init(&fx)
	ui_textarea_state st
	ui_textarea_init(&st)
	ui_textarea_set(&st, c"first line\nsecond  word\nlast")
	char* second = c"second  word"
	press(ctx, area_x(ctx, second, 9), area_y(ctx, 1), 2)
	release(ctx, area_x(ctx, second, 9), area_y(ctx, 1))
	area_frame(ctx, &st)
	assert_equal(19, ui_textarea_sel_start(&st))
	assert_equal(23, ui_textarea_sel_end(&st))
	assert_strings_equal(c"word", ui_primary_published(ctx))
	# The two spaces are one segment (WB3d).
	press(ctx, area_x(ctx, second, 6), area_y(ctx, 1), 2)
	release(ctx, area_x(ctx, second, 6), area_y(ctx, 1))
	area_frame(ctx, &st)
	assert_equal(17, ui_textarea_sel_start(&st))
	assert_equal(19, ui_textarea_sel_end(&st))
	# Triple-click takes the line with its line break; the last line
	# has none.
	press(ctx, area_x(ctx, second, 2), area_y(ctx, 1), 3)
	release(ctx, area_x(ctx, second, 2), area_y(ctx, 1))
	area_frame(ctx, &st)
	assert_equal(11, ui_textarea_sel_start(&st))
	assert_equal(24, ui_textarea_sel_end(&st))
	assert_strings_equal(c"second  word\n", ui_primary_published(ctx))
	press(ctx, area_x(ctx, c"last", 1), area_y(ctx, 2), 3)
	area_frame(ctx, &st)
	assert_equal(24, ui_textarea_sel_start(&st))
	assert_equal(28, ui_textarea_sel_end(&st))
	# A drag up from there extends by whole lines.
	ctx.input.mouse_x = area_x(ctx, c"first line", 3)
	ctx.input.mouse_y = area_y(ctx, 0)
	area_frame(ctx, &st)
	assert_equal(28, st.sel_anchor)
	assert_equal(0, ui_textarea_caret_offset(&st))
	release(ctx, area_x(ctx, c"first line", 3), area_y(ctx, 0))
	area_frame(ctx, &st)
	# A double-click drag across lines stops at word ends.
	press(ctx, area_x(ctx, c"first line", 1), area_y(ctx, 0), 2)
	area_frame(ctx, &st)
	ctx.input.mouse_x = area_x(ctx, second, 2)
	ctx.input.mouse_y = area_y(ctx, 1)
	area_frame(ctx, &st)
	assert_equal(0, ui_textarea_sel_start(&st))
	assert_equal(17, ui_textarea_sel_end(&st))
	release(ctx, area_x(ctx, second, 2), area_y(ctx, 1))
	area_frame(ctx, &st)
	ui_textarea_free(&st)
	ui_render_destroy(&fx.r)


# Selecting publishes PRIMARY through the pump; a middle-click pastes it
# at the pointer, a frame later, without touching the clipboard.
void test_primary_selection_and_middle_click_paste():
	ui_fixture fx
	ui_context* ctx = ui_fixture_init(&fx)
	gfx_window* none = cast(gfx_window*, 0)
	gfx_clipboard_set(none, c"CLIPBOARD")
	ui_textbox_state box
	ui_textbox_init(&box)
	ui_textbox_set(&box, c"pick me")
	ctx.focus = 1
	ui_test_key(ctx, GFX_NAV_LEFT, GFX_MOD_SHIFT)
	ui_test_key(ctx, GFX_NAV_LEFT, GFX_MOD_SHIFT)
	box_frame(ctx, &box)
	ui_clipboard_pump(ctx, none)
	gfx_primary_request(none)
	char* got = gfx_primary_take(none)
	assert_strings_equal(c"me", got)
	free(got)
	# A frame that leaves the selection alone publishes nothing new.
	box_frame(ctx, &box)
	assert_equal(0, cast(int, ui_primary_published(ctx)))
	# Middle-click in a textarea: the caret moves to the pointer and the
	# PRIMARY text lands there.
	ui_textarea_state st
	ui_textarea_init(&st)
	ui_textarea_set(&st, c"ab cd")
	ui_test_event(ctx, GFX_EVENT_MOUSE_DOWN, 2, area_x(ctx, c"ab cd", 2) + 1, area_y(ctx, 0), 0)
	ui_test_event(ctx, GFX_EVENT_MOUSE_UP, 2, area_x(ctx, c"ab cd", 2) + 1, area_y(ctx, 0), 0)
	area_frame(ctx, &st)
	assert_equal(1, ctx.focus)
	assert_equal(1, ctx.clip_paste_primary)
	ui_clipboard_pump(ctx, none)
	area_frame(ctx, &st)
	assert_strings_equal(c"ab mecd", st.buf.data)
	# The textbox takes a middle-click the same way.
	ui_textbox_set(&box, c"xy")
	ui_test_event(ctx, GFX_EVENT_MOUSE_DOWN, 2, box_x_at(c"xy", 1), 20, 0)
	box_frame(ctx, &box)
	ui_clipboard_pump(ctx, none)
	box_frame(ctx, &box)
	assert_strings_equal(c"xmey", &box.text[0])
	# Ctrl+V still reads the clipboard, not PRIMARY.
	ui_test_event(ctx, GFX_EVENT_CHAR, 22, 0, 0, GFX_MOD_CTRL)
	box_frame(ctx, &box)
	assert_equal(0, ctx.clip_paste_primary)
	ui_clipboard_pump(ctx, none)
	box_frame(ctx, &box)
	assert_strings_equal(c"xmeCLIPBOARDy", &box.text[0])
	ui_textarea_free(&st)
	ui_render_destroy(&fx.r)


void test_rich_copy_reaches_the_store_and_plain_copy_drops_it():
	ui_fixture fx
	ui_context* ctx = ui_fixture_init(&fx)
	gfx_window* none = cast(gfx_window*, 0)
	char[6] png
	png[0] = 137
	png[1] = 'P'
	png[2] = 'N'
	png[3] = 'G'
	png[4] = 0
	png[5] = 7
	ui_clipboard_copy_rich(ctx, c"graph LR", c"<b>graph</b>", &png[0], 6)
	ui_clipboard_pump(ctx, none)
	assert_strings_equal(c"graph LR", gfx_clipboard_local.owned)
	assert_strings_equal(c"<b>graph</b>", gfx_clipboard_local.html)
	assert_equal(6, gfx_clipboard_local.png_length)
	assert_equal(0, gfx_clipboard_local.png[4])
	assert_equal(7, gfx_clipboard_local.png[5])
	# A paste of a rich copy reads its text.
	gfx_clipboard_request(none)
	char* text = gfx_clipboard_take(none)
	assert_strings_equal(c"graph LR", text)
	free(text)
	# A later plain copy offers text alone.
	ui_clipboard_copy(ctx, c"plain", 5)
	ui_clipboard_pump(ctx, none)
	assert_equal(0, cast(int, gfx_clipboard_local.html))
	assert_equal(0, cast(int, gfx_clipboard_local.png))
	assert_equal(0, cast(int, ctx.clip_out_html))
	# HTML alone is fine too.
	ui_clipboard_copy_rich(ctx, c"t", c"<i>t</i>", cast(char*, 0), 0)
	ui_clipboard_pump(ctx, none)
	assert_strings_equal(c"<i>t</i>", gfx_clipboard_local.html)
	assert_equal(0, cast(int, gfx_clipboard_local.png))
	ui_render_destroy(&fx.r)


int cf_offset(char* html, char* label):
	int at = index_of(html, label)
	asserts(label, at >= 0)
	return atoi(&html[at + strlen(label)])


void test_cf_html_offsets_point_at_the_fragment():
	char* fragment = c"<p>caf\xc3\xa9</p>"
	char* html = gfx_clipboard_cf_html(fragment)
	int start_html = cf_offset(html, c"StartHTML:")
	int end_html = cf_offset(html, c"EndHTML:")
	int start = cf_offset(html, c"StartFragment:")
	int end = cf_offset(html, c"EndFragment:")
	assert_equal(strlen(html), end_html)
	asserts(c"<html> at StartHTML", starts_with(&html[start_html], c"<html>"))
	assert_equal(strlen(fragment), end - start)
	asserts(c"fragment at StartFragment", starts_with(&html[start], fragment))
	asserts(c"EndFragment comment follows", starts_with(&html[end], c"<!--EndFragment-->"))
	free(html)
