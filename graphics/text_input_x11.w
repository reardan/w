import graphics.window_x11


void gfx_text_input(int active, int multiline, int x, int y, int width, int height, int focus_id):
	gfx_window* win = gfx_x11_active
	if (win == 0): return
	int next_focus = 0
	if (active): next_focus = focus_id
	if (win.text_focus != next_focus):
		if (win.input_context != 0):
			char* discarded = Xutf8ResetIC(win.input_context)
			if (discarded != 0): XFree(cast(int, discarded))
		win.text_focus = next_focus


void gfx_pointer_mode(int mode):
	return
