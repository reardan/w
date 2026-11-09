/*
graphics.window_stub: the no-backend fallback behind graphics.window on
targets without a native windowing layer (x86). Defines the same
gfx_window surface as the real backends; gfx_window_open reports the
gap and returns 0, which consumers already treat as "no display" (the
gl smoke test SKIPs, the demo exits). With no window there is nothing
for graphics.control (W_GFX_CONTROL, docs/projects/wdrive.md) to drive,
so this backend does not connect to it.
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


int gfx_clipboard_set_rich(gfx_window* win, char* text, char* html, char* png, int png_length):
	return gfx_clipboard_local_set_rich(text, html, png, png_length)


int gfx_primary_set(gfx_window* win, char* text):
	return gfx_primary_local_set(text)


void gfx_primary_request(gfx_window* win):
	gfx_primary_local_request()


char* gfx_primary_take(gfx_window* win):
	return gfx_primary_local_take()


void gfx_window_destroy(gfx_window* win):
	return
