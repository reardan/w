/*
graphics.window_stub: the no-backend fallback behind graphics.window on
targets without a native windowing layer (x86, win64). Defines the same
gfx_window surface as the real backends; gfx_window_open reports the
gap and returns 0, which consumers already treat as "no display" (the
gl smoke test SKIPs, the demo exits).
*/
import lib.lib


struct gfx_window:
	int32 width
	int32 height
	int32 should_close
	int32 mouse_x
	int32 mouse_y
	int32 mouse_buttons
	int32 last_keycode


char* gfx_shader_header():
	return c"#version 130\n"


gfx_window* gfx_window_open(char* title, int width, int height):
	print_error(c"graphics.window: no native backend for this target\n")
	return 0


int gfx_window_poll(gfx_window* win):
	return 0


void gfx_window_swap(gfx_window* win):
	return


void gfx_window_destroy(gfx_window* win):
	return
