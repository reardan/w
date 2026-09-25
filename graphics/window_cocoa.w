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
as SKIP.

Input: key, character, navigation, mouse and scroll events all reach
the per-frame ring (graphics.event). No struct-returning selector is
bound (graphics.cocoa's hard rule): the NSPoint of locationInWindow is
read through key-value coding instead — valueForKey: boxes it in an
NSValue (an object id), and getValue:size: copies its two doubles into
W memory — so both calls stay integer-register-only. CHAR codes are
full Unicode codepoints decoded from [event characters]; AppKit's
private-use function-key characters (U+F700..) become NAV codes. There
is no NSTextInputClient yet, so dead keys and IME composition do not
compose (#459).
*/
import lib.lib
import graphics.cocoa
import graphics.gl
import graphics.event


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
	int sel_modifier_flags
	int sel_update
	int sel_is_visible
	int sel_flush_buffer
	int sel_close
	int sel_characters
	int sel_utf8_string
	int sel_value_for_key
	int sel_get_value_size
	int sel_button_number
	int sel_scrolling_delta_y
	int sel_has_precise_deltas
	int key_location
	# scroll delta carried between events, in hundredths of a
	# notch unit (lines, or points for trackpads)
	int32 scroll_accum
	# per-frame event ring (graphics.event)
	int32 event_head
	int32 event_tail
	int32[320] event_ring


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
	# Pointer motion without a held button is only delivered on request.
	objc_msg1(window, sel_registerName(c"setAcceptsMouseMovedEvents:"), 1)
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
	win.sel_modifier_flags = sel_registerName(c"modifierFlags")
	win.sel_update = sel_registerName(c"update")
	win.sel_is_visible = sel_registerName(c"isVisible")
	win.sel_flush_buffer = sel_registerName(c"flushBuffer")
	win.sel_close = sel_registerName(c"close")
	win.sel_characters = sel_registerName(c"characters")
	win.sel_utf8_string = sel_registerName(c"UTF8String")
	win.sel_value_for_key = sel_registerName(c"valueForKey:")
	win.sel_get_value_size = sel_registerName(c"getValue:size:")
	win.sel_button_number = sel_registerName(c"buttonNumber")
	win.sel_scrolling_delta_y = sel_registerName(c"scrollingDeltaY")
	win.sel_has_precise_deltas = sel_registerName(c"hasPreciseScrollingDeltas")
	# Like run_mode: made in the open pool, so it lives until destroy.
	win.key_location = objc_msg1(objc_getClass(c"NSString"), sel_registerName(c"stringWithUTF8String:"), cast(int, c"locationInWindow"))
	win.scroll_accum = 0
	win.event_head = 0
	win.event_tail = 0
	return win


# Translate an NSEvent modifierFlags mask into gfx_mod bits:
# NSEventModifierFlagShift 1<<17, Control 1<<18, Option 1<<19,
# Command 1<<20. Command maps to SUPER, matching the JS host's metaKey.
int gfx_cocoa_mods(int flags):
	int mods = 0
	if (flags & 0x20000):
		mods = mods | GFX_MOD_SHIFT
	if (flags & 0x40000):
		mods = mods | GFX_MOD_CTRL
	if (flags & 0x80000):
		mods = mods | GFX_MOD_ALT
	if (flags & 0x100000):
		mods = mods | GFX_MOD_SUPER
	return mods


# The NAV code for an AppKit function-key character (NSUpArrowFunctionKey
# U+F700 and its private-use neighbours), or 0.
int gfx_cocoa_nav(int cp):
	switch (cp):
		case 0xf702: return GFX_NAV_LEFT
		case 0xf703: return GFX_NAV_RIGHT
		case 0xf700: return GFX_NAV_UP
		case 0xf701: return GFX_NAV_DOWN
		case 0xf729: return GFX_NAV_HOME
		case 0xf72b: return GFX_NAV_END
		case 0xf72c: return GFX_NAV_PAGE_UP
		case 0xf72d: return GFX_NAV_PAGE_DOWN
		case 0xf728: return GFX_NAV_DELETE
		default: return 0


# The GFX_EVENT_CHAR code for one character of a key event, or 0 when it
# is not text. The Mac's backspace key sends DEL (127) and the keypad
# enter key ETX (3); they map to the contract's 8 and 13. Shift-tab
# arrives as BACKTAB (25). The function-key block and other control
# characters are not text.
int gfx_cocoa_char(int cp):
	if (cp == 127):
		return 8
	if (cp == 3):
		return 13
	if (cp == 25):
		return 9
	if ((cp == 8) || (cp == 9) || (cp == 13) || (cp == 27)):
		return cp
	if (cp < 32):
		return 0
	if ((cp >= 0xf700) && (cp <= 0xf8ff)):
		return 0
	return cp


# Decode the UTF-8 codepoint at s[i] into cp[0]; returns the index of the
# next one. Malformed bytes decode as themselves, one byte at a time.
int gfx_cocoa_utf8_next(char* s, int i, int* cp):
	int n = utf8_scan(s + i, 4, cp)
	if (n == 0):
		cp[0] = s[i] & 255
		return i + 1
	return i + n


# Fold one scroll delta (hundredths of a line, or of a point when the
# device reports precise deltas) into *accum and return the whole
# notches it completes: +n toward the top of the content, matching
# GFX_EVENT_SCROLL. A trackpad notch is 24 points; a direction change
# drops the leftover so reversing responds at once.
int gfx_cocoa_scroll_notches(int* accum, int delta, int precise):
	int unit = 100
	if (precise):
		unit = 2400
	if (((accum[0] > 0) && (delta < 0)) || ((accum[0] < 0) && (delta > 0))):
		accum[0] = 0
	accum[0] = accum[0] + delta
	int notches = accum[0] / unit
	accum[0] = accum[0] - notches * unit
	return notches


# Read an event's locationInWindow into win.mouse_x/mouse_y, flipped to
# the top-left origin every backend reports.
void gfx_cocoa_track_mouse(gfx_window* win, int event):
	int boxed = objc_msg1(event, win.sel_value_for_key, win.key_location)
	if (boxed == 0):
		return
	float64[2] pt
	objc_msg2(boxed, win.sel_get_value_size, cast(int, &pt[0]), 16)
	win.mouse_x = cast(int, pt[0])
	win.mouse_y = cast(int, cast(float64, win.height) - pt[1])


void gfx_cocoa_push(gfx_window* win, int kind, int code, int mods):
	gfx_event_ring_push(&win.event_ring[0], &win.event_head, &win.event_tail, kind, code, win.mouse_x, win.mouse_y, mods)


# One key-down event: KEY_DOWN, then a CHAR or NAV per character.
# Returns 1 when AppKit should also see the event (command-key
# shortcuts); plain typing is kept from sendEvent:, where no responder
# takes it and AppKit would beep once per keystroke.
int gfx_cocoa_key_down(gfx_window* win, int event, int mods):
	win.last_keycode = objc_msg0(event, win.sel_key_code) & 0xffff
	gfx_cocoa_push(win, GFX_EVENT_KEY_DOWN, win.last_keycode, mods)
	if (mods & GFX_MOD_SUPER):
		return 1
	int text = objc_msg0(event, win.sel_characters)
	if (text == 0):
		return 0
	char* s = cast(char*, objc_msg0(text, win.sel_utf8_string))
	if (s == 0):
		return 0
	int i = 0
	while (s[i] != 0):
		int cp = 0
		i = gfx_cocoa_utf8_next(s, i, &cp)
		int nav = gfx_cocoa_nav(cp)
		if (nav != 0):
			gfx_cocoa_push(win, GFX_EVENT_NAV, nav, mods)
		else:
			int ch = gfx_cocoa_char(cp)
			if (ch != 0):
				gfx_cocoa_push(win, GFX_EVENT_CHAR, ch, mods)
	return 0


# Queue the ring events for one NSEvent. Returns 1 when the event should
# also be forwarded to [NSApp sendEvent:].
int gfx_cocoa_translate(gfx_window* win, int event):
	# NSEventType values; keyCode is an unsigned short (a raw HID
	# scancode, not a character).
	int event_type = objc_msg0(event, win.sel_type) & 0xffff
	int mods = gfx_cocoa_mods(objc_msg0(event, win.sel_modifier_flags))
	if (event_type == 10):
		return gfx_cocoa_key_down(win, event, mods)
	if (event_type == 11):
		gfx_cocoa_push(win, GFX_EVENT_KEY_UP, objc_msg0(event, win.sel_key_code) & 0xffff, mods)
		return mods & GFX_MOD_SUPER
	# Mouse buttons: left 1/2, right 3/4, other 25/26 (buttonNumber 2 is
	# the middle button). Moved 5 and dragged 6/7/27 only track.
	int button = 0
	int down = 0
	if ((event_type == 1) || (event_type == 2)):
		button = 1
		down = event_type == 1
	else if ((event_type == 3) || (event_type == 4)):
		button = 3
		down = event_type == 3
	else if ((event_type == 25) || (event_type == 26)):
		if (objc_msg0(event, win.sel_button_number) == 2):
			button = 2
		down = event_type == 25
	if ((event_type == 5) || (event_type == 6) || (event_type == 7) || (event_type == 27)):
		gfx_cocoa_track_mouse(win, event)
	else if (button != 0):
		gfx_cocoa_track_mouse(win, event)
		int bit = 1 << (button - 1)
		if (down):
			win.mouse_buttons = win.mouse_buttons | bit
			gfx_cocoa_push(win, GFX_EVENT_MOUSE_DOWN, button, mods)
		else:
			# no bitwise-not operator: -1 - mask == ~mask
			win.mouse_buttons = win.mouse_buttons & (0 - 1 - bit)
			gfx_cocoa_push(win, GFX_EVENT_MOUSE_UP, button, mods)
	else if (event_type == 22):
		gfx_cocoa_track_mouse(win, event)
		float64 dy = objc_msg_f64(event, win.sel_scrolling_delta_y)
		int precise = objc_msg0(event, win.sel_has_precise_deltas) & 0xff
		int accum = win.scroll_accum
		int notches = gfx_cocoa_scroll_notches(&accum, cast(int, dy * 100.0), precise)
		win.scroll_accum = accum
		while (notches > 0):
			gfx_cocoa_push(win, GFX_EVENT_SCROLL, 1, mods)
			notches = notches - 1
		while (notches < 0):
			gfx_cocoa_push(win, GFX_EVENT_SCROLL, 0 - 1, mods)
			notches = notches + 1
	return 1


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
		if (gfx_cocoa_translate(win, event)):
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


# Pop the oldest queued input event (graphics.event); returns 1 while
# events remain from the polls since the last drain.
int gfx_window_next_event(gfx_window* win, gfx_event* out):
	return gfx_event_ring_next(&win.event_ring[0], &win.event_head, &win.event_tail, out)


void gfx_window_swap(gfx_window* win):
	objc_msg0(win.glctx, win.sel_flush_buffer)


void gfx_window_destroy(gfx_window* win):
	objc_msg0(objc_getClass(c"NSOpenGLContext"), sel_registerName(c"clearCurrentContext"))
	objc_msg0(win.window, win.sel_close)
	objc_autoreleasePoolPop(win.pool)
	free(win)
