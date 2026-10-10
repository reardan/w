import graphics.window_win32


void gfx_text_input(int active, int multiline, int x, int y, int width, int height, int focus_id):
	gfx_window* win = gfx_win32_active
	if (win == 0): return
	int im = ImmGetContext(win.hwnd)
	int next_focus = 0
	if (active): next_focus = focus_id
	if (win.text_focus != next_focus):
		# Cancel before changing the ID: old preedit must never commit to
		# the new control. NI_COMPOSITIONSTR, CPS_CANCEL.
		if (im != 0): ImmNotifyIME(im, 21, 4, 0)
		gfx_input_queue_push(&win.input_queue, GFX_EVENT_PREEDIT_END, 0, win.text_focus, 0, 0)
		win.pending_surrogate = 0
		win.text_focus = next_focus
	if (im != 0):
		if (active):
			int32[7] form
			form[0] = 2 # CFS_POINT; native candidate/composition window
			form[1] = x
			form[2] = y + height
			for i in range(4): form[i + 3] = 0
			ImmSetCompositionWindow(im, &form[0])
		ImmReleaseContext(win.hwnd, im)


void gfx_pointer_mode(int mode):
	return
