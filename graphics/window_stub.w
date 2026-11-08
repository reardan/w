/*
graphics.window_stub: the no-backend fallback behind graphics.window on
targets without a native windowing layer (x86). Defines the same
gfx_window surface as the real backends; gfx_window_open reports the
gap and returns 0, which consumers already treat as "no display" (the
gl smoke test SKIPs, the demo exits).
*/
import lib.lib
import graphics.event
import graphics.clipboard_store


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


int gfx_window_next_event(gfx_window* win, gfx_event* out):
	return 0


void gfx_window_swap(gfx_window* win):
	return


# Device pixels per logical window pixel, for graphics.ui's crisp text
# (ui_render_set_pixel_scale). This backend draws 1:1.
float32 gfx_window_pixel_ratio(gfx_window* win):
	return 1.0


# No platform clipboard: every window (there are none) shares the
# in-process store, so copy and paste still round-trip inside one
# program.
int gfx_clipboard_set(gfx_window* win, char* text):
	return gfx_clipboard_local_set(text)


void gfx_clipboard_request(gfx_window* win):
	gfx_clipboard_local_request()


char* gfx_clipboard_take(gfx_window* win):
	return gfx_clipboard_local_take()


void gfx_window_destroy(gfx_window* win):
	return
