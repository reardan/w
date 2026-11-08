/*
graphics.window: a double-buffered OpenGL window, dispatched to the
target's native backend through the __arch__ import path:

	x64 / arm64     -> graphics.window_x11   (X11/GLX)
	arm64_darwin    -> graphics.window_cocoa (AppKit/NSOpenGL, M5)
	wasm            -> graphics.window_web   (browser canvas + WebGL2)
	win64           -> graphics.window_win32 (Win32/WGL)
	x86             -> graphics.window_stub  (open reports and fails)

The happy path is four calls, identical on every backend:

	gfx_window* win = gfx_window_open(c"demo", 640, 480)
	while (gfx_window_poll(win)):
		# ... glClear / draw ...
		gfx_window_swap(win)
	gfx_window_destroy(win)

gfx_window_poll drains the platform event queue, tracks resize / close /
basic input state, and returns 0 once the user closed the window.

Every backend also implements the clipboard seam
(docs/projects/ui_clipboard.md, graphics/clipboard_store.w):

	int   gfx_clipboard_set(gfx_window* win, char* text)  # copy, synchronous
	void  gfx_clipboard_request(gfx_window* win)          # start a paste
	char* gfx_clipboard_take(gfx_window* win)             # 0 until it arrives

	int   gfx_clipboard_set_rich(gfx_window* win, char* text, char* html, char* png, int png_length)
	int   gfx_primary_set(gfx_window* win, char* text)   # the selection
	void  gfx_primary_request(gfx_window* win)           # middle-click paste
	char* gfx_primary_take(gfx_window* win)

X11 serves the CLIPBOARD selection (with INCR for large text, and
text/html and image/png beside the text after a rich copy) and PRIMARY,
win64 uses CF_UNICODETEXT (plus "HTML Format" and "PNG"), arm64_darwin
NSPasteboard (plus public.html and public.png), and wasm the browser's
asynchronous navigator.clipboard (ClipboardItem for rich copies); the
x86 stub and a null window keep an in-process clipboard, and every
backend but X11 an in-process PRIMARY. MOUSE_DOWN events carry their
click count (graphics.event gfx_event_clicks) from every backend. take returns malloc'd UTF-8 with LF line ends
once, "" for a refused or empty read. graphics.ui widgets reach it
through ui_begin_window, which pumps it every frame.

Every backend also provides gfx_shader_header(), the "#version" line
portable shader sources are joined with (130 on GLX contexts, 150 on
the Mac's 3.2-core contexts).

Design notes: docs/projects/graphics.md
*/
import graphics.__arch__.window_native
