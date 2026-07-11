/*
graphics.window_web: the browser-canvas backend behind graphics.window on
the wasm target. The "window" is a <canvas> with a WebGL2 context, owned
by the JS host glue (tools/web/webgl_env.mjs); the gfx_host_* imports
below are the whole host surface.

The four-call happy path works unchanged EXCEPT that a browser cannot
block: control must return to the event loop for the canvas to present,
so the render loop is driven by the host (requestAnimationFrame) instead
of a W while-loop. Programs structure as setup + frame and hand the frame
function to gfx_window_run:

	int frame():
		if (gfx_window_poll(win) == 0):
			return 0
		# ... glClear / draw ...
		gfx_window_swap(win)
		return 1

	int main(...):
		win = gfx_window_open(c"demo", 640, 480)
		gfx_window_run(win, frame)
		return 0

main returns, and the host calls frame once per animation frame — for as
long as frame returns 1 (the return value travels in the module's
exported $ax global). gfx_window_poll is non-blocking (the host has
already drained its events; it just refreshes the input snapshot), and
gfx_window_swap is a no-op: the browser composites the canvas when the
frame callback returns.

Design notes: docs/projects/wasm_webgl.md
*/
import lib.lib
import graphics.gl


struct gfx_window:
	int32 width
	int32 height
	int32 should_close
	int32 mouse_x
	int32 mouse_y
	int32 mouse_buttons
	int32 last_keycode


# The frame callback contract: return 1 to keep the loop running, 0 to
# stop (the host then stops scheduling frames).
type gfx_frame_fn = fn() -> int


# The host side of the window: canvas setup, an input-state snapshot
# refresh, and the frame-callback registration. All in the same "env"
# import module as the GL surface.
c_lib "env"

extern int gfx_host_canvas_init(char* title, int width, int height)
# Writes the 7 int32 gfx_window fields (width, height, should_close,
# mouse_x, mouse_y, mouse_buttons, last_keycode) at the given pointer.
extern void gfx_host_poll_state(gfx_window* win)
extern void gfx_host_set_frame_callback(int table_index)


# "#version" line for shader sources that should compile on every
# backend: WebGL2 contexts speak GLSL ES 3.00, which additionally needs
# an explicit default float precision (a no-op for the desktop dialects,
# which never see this header).
char* gfx_shader_header():
	return c"#version 300 es\nprecision highp float;\n"


# Bind the host canvas and make its WebGL2 context current. Returns 0
# (with a message on stderr) when the host has no canvas — e.g. the
# module is running under a plain WASI runtime instead of the web glue.
gfx_window* gfx_window_open(char* title, int width, int height):
	if (gfx_host_canvas_init(title, width, height) == 0):
		print_error(c"graphics.window: host has no canvas (not running under tools/web glue?)\n")
		return 0
	gfx_window* win = new gfx_window()
	win.width = width
	win.height = height
	win.should_close = 0
	win.mouse_x = 0
	win.mouse_y = 0
	win.mouse_buttons = 0
	win.last_keycode = 0
	glViewport(0, 0, width, height)
	return win


# Refresh the input/size snapshot from the host. Non-blocking; returns 1
# while the canvas should stay live.
int gfx_window_poll(gfx_window* win):
	gfx_host_poll_state(win)
	if (win.should_close):
		return 0
	return 1


# The browser composites the canvas when the frame callback returns;
# there is no buffer swap to issue.
void gfx_window_swap(gfx_window* win):
	return


# Hand the frame function to the host: it is called once per animation
# frame after main returns, until it returns 0 (or the page goes away).
void gfx_window_run(gfx_window* win, gfx_frame_fn* frame):
	gfx_host_set_frame_callback(cast(int, frame))


void gfx_window_destroy(gfx_window* win):
	free(win)
