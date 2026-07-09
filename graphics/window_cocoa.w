/*
graphics.window_cocoa: a double-buffered OpenGL window on AppKit — the
arm64_darwin backend behind graphics.window (see that module for the
API contract shared by every backend).

Nib-less and delegate-free: one fixed-size NSWindow (styleMask
titled|closable|miniaturizable), an NSOpenGLContext with a 3.2-core
pixel format (GL 4.1 in practice; gfx_shader_header is "#version 150"),
and a manual event pump — gfx_window_poll drains
nextEventMatchingMask:untilDate:inMode:dequeue: into sendEvent: under a
per-frame autorelease pool. Closing is detected by polling isVisible
(setReleasedWhenClosed:NO keeps the window object queryable after the
red button), so no delegate is needed.

Runs in a real GUI session only; with no WindowServer the pixel format
init returns nil and gfx_window_open returns 0, which consumers treat
as SKIP. Mouse fields stay 0 in v1 (last_keycode is tracked).
*/
import lib.lib
import graphics.cocoa
import graphics.gl


struct gfx_window:
	# public surface, shared by every backend
	int32 width
	int32 height
	int32 should_close
	int32 mouse_x
	int32 mouse_y
	int32 mouse_buttons
	int32 last_keycode
	# Cocoa handles (word-sized objc ids)
	int app
	int window
	int glctx
	int pool
	int run_mode
	int distant_past
	# hot-path selectors, registered once in open
	int sel_next_event
	int sel_send_event
	int sel_type
	int sel_key_code
	int sel_update
	int sel_is_visible
	int sel_flush_buffer
	int sel_close


# The Mac backend hands out 3.2-core contexts, where GLSL 130 no longer
# exists: shader sources join their bodies with 150.
char* gfx_shader_header():
	return c"#version 150\n"


# Open a titled fixed-size window with a double-buffered 3.2-core GL
# context made current. Returns 0 (with a message on stderr) when no
# usable pixel format exists — e.g. outside a GUI session.
gfx_window* gfx_window_open(char* title, int width, int height):
	int pool = objc_autoreleasePoolPush()

	int app = objc_msg0(objc_getClass(c"NSApplication"), sel_registerName(c"sharedApplication"))
	# NSApplicationActivationPolicyRegular: dock icon + key windows.
	objc_msg1(app, sel_registerName(c"setActivationPolicy:"), 0)

	# [[NSWindow alloc] initWithContentRect:r styleMask:7 backing:2 defer:NO]
	# styleMask 7 = titled | closable | miniaturizable (fixed size).
	int window = objc_msg0(objc_getClass(c"NSWindow"), sel_registerName(c"alloc"))
	window = objc_msg_rect3(window, sel_registerName(c"initWithContentRect:styleMask:backing:defer:"), 0.0, 0.0, cast(float64, width), cast(float64, height), 7, 2, 0)
	# The close button releases the window by default; keep the object
	# alive so the poll loop can still ask isVisible afterwards.
	objc_msg1(window, sel_registerName(c"setReleasedWhenClosed:"), 0)
	int title_str = objc_msg1(objc_getClass(c"NSString"), sel_registerName(c"stringWithUTF8String:"), cast(int, title))
	objc_msg1(window, sel_registerName(c"setTitle:"), title_str)
	objc_msg1(window, sel_registerName(c"makeKeyAndOrderFront:"), 0)
	objc_msg1(app, sel_registerName(c"activateIgnoringOtherApps:"), 1)

	# NSOpenGLPixelFormat: double-buffered, 24-bit color, 16-bit depth,
	# 3.2-core profile (0x3200 = NSOpenGLProfileVersion3_2Core).
	int32[10] attrs
	attrs[0] = 5       /* NSOpenGLPFADoubleBuffer */
	attrs[1] = 8       /* NSOpenGLPFAColorSize */
	attrs[2] = 24
	attrs[3] = 12      /* NSOpenGLPFADepthSize */
	attrs[4] = 16
	attrs[5] = 99      /* NSOpenGLPFAOpenGLProfile */
	attrs[6] = 0x3200  /* NSOpenGLProfileVersion3_2Core */
	attrs[7] = 0
	int pf = objc_msg0(objc_getClass(c"NSOpenGLPixelFormat"), sel_registerName(c"alloc"))
	pf = objc_msg1(pf, sel_registerName(c"initWithAttributes:"), cast(int, &attrs[0]))
	if (pf == 0):
		print_error(c"graphics.window: no usable NSOpenGLPixelFormat (no GUI session?)\n")
		objc_msg0(window, sel_registerName(c"close"))
		objc_autoreleasePoolPop(pool)
		return 0

	int glctx = objc_msg0(objc_getClass(c"NSOpenGLContext"), sel_registerName(c"alloc"))
	glctx = objc_msg2(glctx, sel_registerName(c"initWithFormat:shareContext:"), pf, 0)
	objc_msg1(glctx, sel_registerName(c"setView:"), objc_msg0(window, sel_registerName(c"contentView")))
	objc_msg0(glctx, sel_registerName(c"makeCurrentContext"))
	objc_msg0(app, sel_registerName(c"finishLaunching"))

	# The core profile mandates a bound vertex array object before any
	# attribute setup or draw; one VAO for the window's lifetime.
	int32 vao = 0
	glGenVertexArrays(1, &vao)
	glBindVertexArray(vao)
	glViewport(0, 0, width, height)

	gfx_window* win = new gfx_window()
	win.width = width
	win.height = height
	win.should_close = 0
	win.mouse_x = 0
	win.mouse_y = 0
	win.mouse_buttons = 0
	win.last_keycode = 0
	win.app = app
	win.window = window
	win.glctx = glctx
	win.pool = pool
	# NSDefaultRunLoopMode is the literal string "kCFRunLoopDefaultMode"
	# (binding the constant would need an extern data object, which arm64
	# targets reject). Created in the open pool, so it lives until destroy.
	win.run_mode = objc_msg1(objc_getClass(c"NSString"), sel_registerName(c"stringWithUTF8String:"), cast(int, c"kCFRunLoopDefaultMode"))
	win.distant_past = objc_msg0(objc_getClass(c"NSDate"), sel_registerName(c"distantPast"))
	win.sel_next_event = sel_registerName(c"nextEventMatchingMask:untilDate:inMode:dequeue:")
	win.sel_send_event = sel_registerName(c"sendEvent:")
	win.sel_type = sel_registerName(c"type")
	win.sel_key_code = sel_registerName(c"keyCode")
	win.sel_update = sel_registerName(c"update")
	win.sel_is_visible = sel_registerName(c"isVisible")
	win.sel_flush_buffer = sel_registerName(c"flushBuffer")
	win.sel_close = sel_registerName(c"close")
	return win


# Drain pending AppKit events. Returns 1 while the window should stay
# open (0 once the red button closed it).
int gfx_window_poll(gfx_window* win):
	if (win.should_close):
		return 0
	int pool = objc_autoreleasePoolPush()
	while (1):
		# mask -1 = NSEventMaskAny; distantPast = poll without blocking.
		int event = objc_msg4(win.app, win.sel_next_event, 0 - 1, win.distant_past, win.run_mode, 1)
		if (event == 0):
			break
		# NSEventTypeKeyDown = 10; keyCode is an unsigned short.
		if ((objc_msg0(event, win.sel_type) & 0xffff) == 10):
			win.last_keycode = objc_msg0(event, win.sel_key_code) & 0xffff
		objc_msg1(win.app, win.sel_send_event, event)
	# Track window moves (the GL surface follows the view).
	objc_msg0(win.glctx, win.sel_update)
	# isVisible is a BOOL: only the low byte is defined.
	if ((objc_msg0(win.window, win.sel_is_visible) & 0xff) == 0):
		win.should_close = 1
	objc_autoreleasePoolPop(pool)
	if (win.should_close):
		return 0
	return 1


void gfx_window_swap(gfx_window* win):
	objc_msg0(win.glctx, win.sel_flush_buffer)


void gfx_window_destroy(gfx_window* win):
	objc_msg0(objc_getClass(c"NSOpenGLContext"), sel_registerName(c"clearCurrentContext"))
	objc_msg0(win.window, win.sel_close)
	objc_autoreleasePoolPop(win.pool)
	free(win)
