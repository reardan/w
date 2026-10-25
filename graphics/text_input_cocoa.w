# gfx_text_input for the Cocoa backend. A focus change cancels any preview
# for the old field; the optional NSTextInputClient bridge
# (graphics.ime_cocoa) hears every call through the window's focus_hook
# to place its candidate window and discard composition.
import graphics.window_cocoa


void gfx_text_input(int active, int multiline, int x, int y, int width, int height, int focus_id):
	gfx_window* win = gfx_cocoa_active
	if (win == 0): return
	int next_focus = 0
	if (active): next_focus = focus_id
	if (win.text_focus != next_focus):
		gfx_input_queue_push(&win.input_queue, GFX_EVENT_PREEDIT_END, 0, win.text_focus, 0, 0)
		win.text_focus = next_focus
	if (win.focus_hook != 0): win.focus_hook(win, next_focus, multiline, x, y, width, height)


void gfx_pointer_mode(int mode):
	return
