# The page tools/web/run_browser_clipboard.mjs drives in a real browser
# (issue #910, docs/projects/ui_clipboard.md §6): serve the repo and open
# /tools/web/?module=/bin/graphics_ui_clipboard.wasm.
#
# A textbox, a textarea and three buttons at fixed places. "Copy" and
# "Rich" copy outside any copy event (navigator.clipboard), "Paste" asks
# for the clipboard outside any paste event, and Ctrl+C with no field
# focused copies rich content (text/plain, text/html and image/png)
# inside the copy event. stdout reports what the test needs to see: the
# geometry once, then every change of the fields' text and of the
# pending paste.
# wbuild: target=graphics_ui_clipboard_web tag=tests_wasm dep=wv2 dep=ui_font_data
# wbuild: step="bin/wv2 wasm graphics/ui/clipboard_demo_web.w -o bin/graphics_ui_clipboard.wasm"
# Opt-in: headless Chromium through the preinstalled Playwright; prints
# SKIP when Playwright or its Chromium is missing.
# wbuild: target=web_clipboard_browser_test dep=graphics_ui_clipboard_web dep=wrun
# wbuild: step="bin/wrun node tools/web/run_browser_clipboard.mjs bin/graphics_ui_clipboard.wasm" expect_stdout="run_browser_clipboard"
import lib.lib
import graphics.window
import structures.string
import graphics.image.png
import graphics.ui.theme
import graphics.ui.render
import graphics.ui.widgets


gfx_window* demo_win
ui_renderer* demo_renderer
ui_context* demo_ctx
ui_theme demo_theme
ui_textbox_state demo_box
ui_textarea_state demo_area
char* demo_box_seen
char* demo_area_seen
int demo_pending
int demo_box_id
char* demo_png
int demo_png_length


# Print "<name>:<text>" as one line (a line feed in text as the two
# characters \n) when text differs from what was last printed.
char* demo_report(char* name, char* text, char* seen):
	if ((seen != 0) && (strcmp(seen, text) == 0)): return seen
	string_builder* line = string_from(name)
	string_append_char(line, ':')
	int i = 0
	while (text[i] != 0):
		if (text[i] == 10): string_append(line, c"\\n")
		else: string_append_char(line, text[i])
		i = i + 1
	string_append_char(line, 10)
	print(line.data)
	string_free(line)
	if (seen != 0): free(seen)
	return strclone(text)


void demo_copy_rich():
	ui_clipboard_copy_rich(demo_ctx, c"rich text", c"<b>rich</b> html", demo_png, demo_png_length)


int demo_frame():
	if (gfx_window_poll(demo_win) == 0): return 0
	ui_context* ctx = demo_ctx
	ui_begin_window(ctx, demo_win)
	# Ctrl+C with nothing focused: a rich copy, inside the copy event.
	if (ctx.focus == 0):
		for i in range(ctx.char_count):
			if (ui_clipboard_command(ctx.chars[i], ctx.char_mods[i]) == 'c'): demo_copy_rich()
	ui_region_push(ctx, ui_rect_new(20.0, 20.0, 400.0, 40.0))
	demo_box_id = ctx.next_id
	ui_textbox(ctx, 380.0, &demo_box)
	ui_region_pop(ctx)
	ui_textarea(ctx, ui_rect_new(20.0, 80.0, 400.0, 120.0), &demo_area)
	ui_region_push(ctx, ui_rect_new(20.0, 220.0, 120.0, 40.0))
	if (ui_button(ctx, c"Copy")): ui_clipboard_copy(ctx, &demo_box.text[0], demo_box.length)
	ui_region_pop(ctx)
	ui_region_push(ctx, ui_rect_new(160.0, 220.0, 120.0, 40.0))
	if (ui_button(ctx, c"Paste")):
		ctx.focus = demo_box_id
		ui_clipboard_paste_request(ctx, demo_box_id)
	ui_region_pop(ctx)
	ui_region_push(ctx, ui_rect_new(300.0, 220.0, 120.0, 40.0))
	if (ui_button(ctx, c"Rich")): demo_copy_rich()
	ui_region_pop(ctx)
	# Clicking empty space drops focus, so Ctrl+C reaches the rich copy.
	if (ctx.input.mouse_pressed && (ctx.input.press_y > 280)): ctx.focus = 0
	ui_end(ctx)
	gfx_window_swap(demo_win)
	demo_box_seen = demo_report(c"box", &demo_box.text[0], demo_box_seen)
	demo_area_seen = demo_report(c"area", demo_area.buf.data, demo_area_seen)
	int pending = ctx.clip_paste_id != 0
	if (pending != demo_pending):
		if (pending): print(c"pending:1\n")
		else: print(c"pending:0\n")
		demo_pending = pending
	return 1


int main():
	demo_win = gfx_window_open(c"W clipboard", 480, 320)
	if (demo_win == 0): return 1
	demo_renderer = new ui_renderer()
	if (ui_render_init(demo_renderer) == 0): return 1
	ui_theme_light(&demo_theme)
	demo_ctx = new ui_context()
	ui_context_init(demo_ctx, demo_renderer, &demo_theme)
	ui_textbox_init(&demo_box)
	ui_textbox_set(&demo_box, c"alpha beta gamma")
	ui_textarea_init(&demo_area)
	ui_textarea_set(&demo_area, c"one two\nthree")
	# A 2x1 PNG for the image flavor.
	char[8] rgba
	for i in range(8): rgba[i] = 255
	rgba[0] = 0
	string_builder* png = png_encode_rgba(2, 1, &rgba[0])
	demo_png = png.data
	demo_png_length = png.length
	# Geometry for the test, in canvas pixels: the textbox's text origin
	# and baseline row, the textarea's first-line origin and line height.
	int scale = demo_theme.text_scale
	print(f"geometry box_x={20 + demo_theme.pad} box_y={20 + demo_theme.widget_height / 2} area_x={20 + demo_theme.pad} area_y={80 + demo_theme.pad} line_h={ui_text_height(scale) + 2}\n")
	# x of "beta"'s middle and of "two"'s middle, from their text origins.
	int beta = (ui_text_prefix_width(c"alpha ", 6, scale) + ui_text_prefix_width(c"alpha beta", 10, scale)) / 2
	int two = (ui_text_prefix_width(c"one ", 4, scale) + ui_text_prefix_width(c"one two", 7, scale)) / 2
	print(f"widths beta={beta} two={two}\n")
	print(c"ready\n")
	gfx_window_run(demo_win, demo_frame)
	return 0
