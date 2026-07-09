/*
graphics.window: a double-buffered OpenGL window, dispatched to the
target's native backend through the __arch__ import path:

	x64 / arm64     -> graphics.window_x11   (X11/GLX)
	arm64_darwin    -> graphics.window_cocoa (AppKit/NSOpenGL, M5)
	x86 / win64     -> graphics.window_stub  (open reports and fails)

The happy path is four calls, identical on every backend:

	gfx_window* win = gfx_window_open(c"demo", 640, 480)
	while (gfx_window_poll(win)):
		# ... glClear / draw ...
		gfx_window_swap(win)
	gfx_window_destroy(win)

gfx_window_poll drains the platform event queue, tracks resize / close /
basic input state, and returns 0 once the user closed the window.

Every backend also provides gfx_shader_header(), the "#version" line
portable shader sources are joined with (130 on GLX contexts, 150 on
the Mac's 3.2-core contexts).

Design notes: docs/projects/graphics.md
*/
import graphics.__arch__.window_native
