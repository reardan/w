# wbuild: name=graphics_cocoa_input_darwin arch_only=arm64_darwin
/*
Cocoa input translation (#462), run natively on a Mac by
tools/mac/run_darwin_tests.sh. First the pure helpers (character, nav
and scroll-notch translation, UTF-8 decoding); then, in a GUI session,
synthetic NSEvents posted to the application queue with
[NSApp postEvent:atStart:] and read back through gfx_window_poll and
gfx_window_next_event, which checks the whole path: locationInWindow via
key-value coding, the y flip, button state, [event characters] decoding
and scrollingDeltaY. Mouse events come from
mouseEventWithType:location:...; key and scroll events are built with
CoreGraphics and wrapped by [NSEvent eventWithCGEvent:], because
keyEventWithType:... needs more integer arguments than the arm64_darwin
FFI passes and CGEventCreateScrollWheelEvent is variadic.

Prints "graphics cocoa input OK", or a SKIP line when no window can be
opened (no GUI session).
*/
import lib.lib
import lib.assert
import graphics.cocoa
import graphics.window
import graphics.event

c_lib "/System/Library/Frameworks/ApplicationServices.framework/Versions/A/ApplicationServices"
extern int CGEventCreate(int source)
extern int CGEventCreateKeyboardEvent(int source, int keycode, int down)
extern void CGEventKeyboardSetUnicodeString(int event, int length, int16* text)
extern void CGEventSetType(int event, int type)
extern void CGEventSetIntegerValueField(int event, int field, int value)
extern void CGEventSetDoubleValueField(int event, int field, float64 value)
extern void CFRelease(int object)

c_lib "/usr/lib/libobjc.A.dylib"
extern int objc_msg_mouse(int receiver, int selector, int type, float64 x, float64 y, int flags, float64 timestamp, int window_number, int context, int event_number, int clicks, float32 pressure) = "objc_msgSend"


void test_char_translation():
	assert_equal('a', gfx_cocoa_char('a'))
	assert_equal(233, gfx_cocoa_char(233))
	assert_equal(0x4e2d, gfx_cocoa_char(0x4e2d))
	# backspace sends DEL, keypad enter ETX, shift-tab BACKTAB
	assert_equal(8, gfx_cocoa_char(127))
	assert_equal(13, gfx_cocoa_char(3))
	assert_equal(9, gfx_cocoa_char(25))
	assert_equal(13, gfx_cocoa_char(13))
	assert_equal(27, gfx_cocoa_char(27))
	assert_equal(0, gfx_cocoa_char(1))
	assert_equal(0, gfx_cocoa_char(0xf702))
	assert_equal(GFX_NAV_LEFT, gfx_cocoa_nav(0xf702))
	assert_equal(GFX_NAV_RIGHT, gfx_cocoa_nav(0xf703))
	assert_equal(GFX_NAV_UP, gfx_cocoa_nav(0xf700))
	assert_equal(GFX_NAV_DOWN, gfx_cocoa_nav(0xf701))
	assert_equal(GFX_NAV_HOME, gfx_cocoa_nav(0xf729))
	assert_equal(GFX_NAV_END, gfx_cocoa_nav(0xf72b))
	assert_equal(GFX_NAV_PAGE_UP, gfx_cocoa_nav(0xf72c))
	assert_equal(GFX_NAV_PAGE_DOWN, gfx_cocoa_nav(0xf72d))
	assert_equal(GFX_NAV_DELETE, gfx_cocoa_nav(0xf728))
	assert_equal(0, gfx_cocoa_nav('a'))


void test_utf8_next():
	# "a", U+00E9, U+4E2D, U+1F600, then a stray continuation byte
	char* s = c"a\xc3\xa9\xe4\xb8\xad\xf0\x9f\x98\x80\x80"
	int cp = 0
	int i = gfx_cocoa_utf8_next(s, 0, &cp)
	assert_equal('a', cp)
	i = gfx_cocoa_utf8_next(s, i, &cp)
	assert_equal(0xe9, cp)
	i = gfx_cocoa_utf8_next(s, i, &cp)
	assert_equal(0x4e2d, cp)
	i = gfx_cocoa_utf8_next(s, i, &cp)
	assert_equal(0x1f600, cp)
	assert_equal(10, i)
	i = gfx_cocoa_utf8_next(s, i, &cp)
	assert_equal(0x80, cp)
	assert_equal(11, i)


void test_scroll_notches():
	int accum = 0
	# line deltas: one notch per line, fractions carried
	assert_equal(1, gfx_cocoa_scroll_notches(&accum, 100, 0))
	assert_equal(0, gfx_cocoa_scroll_notches(&accum, 60, 0))
	assert_equal(1, gfx_cocoa_scroll_notches(&accum, 60, 0))
	assert_equal(20, accum)
	# reversing drops the leftover
	assert_equal(0 - 2, gfx_cocoa_scroll_notches(&accum, 0 - 250, 0))
	assert_equal(0 - 50, accum)
	# precise (trackpad) deltas: one notch per 24 points
	accum = 0
	assert_equal(0, gfx_cocoa_scroll_notches(&accum, 1000, 1))
	assert_equal(1, gfx_cocoa_scroll_notches(&accum, 1500, 1))
	assert_equal(100, accum)


int ns_app():
	return objc_msg0(objc_getClass(c"NSApplication"), sel_registerName(c"sharedApplication"))


void post(int event):
	objc_msg2(ns_app(), sel_registerName(c"postEvent:atStart:"), event, 0)


void post_cg(int cg):
	post(objc_msg1(objc_getClass(c"NSEvent"), sel_registerName(c"eventWithCGEvent:"), cg))
	CFRelease(cg)


# A mouse event at window point (x, y), origin bottom-left as AppKit
# reports it.
void post_mouse(gfx_window* win, int type, float64 x, float64 y, int flags):
	int number = objc_msg0(win.window, sel_registerName(c"windowNumber"))
	post(objc_msg_mouse(objc_getClass(c"NSEvent"), sel_registerName(c"mouseEventWithType:location:modifierFlags:timestamp:windowNumber:context:eventNumber:clickCount:pressure:"), type, x, y, flags, 0.0, number, 0, 0, 1, cast(float32, 1.0)))


void post_key(int keycode, int16* text, int length):
	int cg = CGEventCreateKeyboardEvent(0, keycode, 1)
	CGEventKeyboardSetUnicodeString(cg, length, text)
	post_cg(cg)


# A line-based wheel event of `lines` notches: kCGEventScrollWheel (22)
# with kCGScrollWheelEventDeltaAxis1 (11), its fixed-point twin (93)
# and kCGScrollWheelEventIsContinuous (88) cleared.
void post_scroll(int lines):
	int cg = CGEventCreate(0)
	CGEventSetType(cg, 22)
	CGEventSetIntegerValueField(cg, 88, 0)
	CGEventSetIntegerValueField(cg, 11, lines)
	CGEventSetDoubleValueField(cg, 93, cast(float64, lines))
	post_cg(cg)


# Posted events are rebuilt by AppKit through screen coordinates, which
# on a scaled display moves a synthesized location by up to a couple of
# points (30.0 comes back as 28.571), so positions are checked to within
# this many points. Real hardware events are not rebuilt this way.
int near(int want, int got):
	int d = want - got
	if (d < 0):
		d = 0 - d
	return d <= 3


void assert_near(int want, int got):
	if (near(want, got) == 0):
		assert_equal(want, got)


# Pop the next event and check its kind/code (and position when x >= 0).
void expect_event(gfx_window* win, int kind, int code, int x, int y, int mods):
	gfx_event e
	assert_equal(1, gfx_window_next_event(win, &e))
	assert_equal(kind, e.kind)
	assert_equal(code, e.code)
	if (x >= 0):
		assert_near(x, e.x)
		assert_near(y, e.y)
	if (mods >= 0):
		assert_equal(mods, e.mods)


void drain(gfx_window* win):
	gfx_event e
	while (gfx_window_next_event(win, &e)):
		e.kind = 0


int test_window_events():
	gfx_window* win = gfx_window_open(c"cocoa input test", 200, 150)
	if (win == 0):
		return 0
	gfx_window_poll(win)
	drain(win)

	# Left button at AppKit (30, 110) = top-left (30, 40), shift held.
	post_mouse(win, 1, 30.0, 110.0, 0x20000)
	gfx_window_poll(win)
	expect_event(win, GFX_EVENT_MOUSE_DOWN, 1, 30, 40, GFX_MOD_SHIFT)
	assert_equal(1, win.mouse_buttons)
	assert_near(30, win.mouse_x)
	assert_near(40, win.mouse_y)

	# Drag, release, then a right click elsewhere.
	post_mouse(win, 6, 50.5, 100.0, 0)
	post_mouse(win, 2, 50.5, 100.0, 0)
	post_mouse(win, 3, 10.0, 140.0, 0)
	post_mouse(win, 4, 10.0, 140.0, 0)
	gfx_window_poll(win)
	expect_event(win, GFX_EVENT_MOUSE_UP, 1, 50, 50, 0)
	expect_event(win, GFX_EVENT_MOUSE_DOWN, 3, 10, 10, 0)
	expect_event(win, GFX_EVENT_MOUSE_UP, 3, 10, 10, 0)
	assert_equal(0, win.mouse_buttons)

	# Motion without a button only moves the pointer.
	post_mouse(win, 5, 120.0, 75.0, 0)
	gfx_window_poll(win)
	gfx_event none
	assert_equal(0, gfx_window_next_event(win, &none))
	assert_near(120, win.mouse_x)
	assert_near(75, win.mouse_y)

	# Typing: KEY_DOWN then CHAR per character, including non-ASCII.
	int16[2] text
	text[0] = 'a'
	post_key(0, &text[0], 1)
	text[0] = cast(int16, 0x4e2d)
	post_key(0, &text[0], 1)
	# macOS backspace (keycode 51) sends DEL
	text[0] = 127
	post_key(51, &text[0], 1)
	# left arrow (keycode 123) sends NSLeftArrowFunctionKey
	text[0] = cast(int16, 0xf702)
	post_key(123, &text[0], 1)
	gfx_window_poll(win)
	expect_event(win, GFX_EVENT_KEY_DOWN, 0, 0 - 1, 0, 0 - 1)
	expect_event(win, GFX_EVENT_CHAR, 'a', 0 - 1, 0, 0 - 1)
	expect_event(win, GFX_EVENT_KEY_DOWN, 0, 0 - 1, 0, 0 - 1)
	expect_event(win, GFX_EVENT_CHAR, 0x4e2d, 0 - 1, 0, 0 - 1)
	expect_event(win, GFX_EVENT_KEY_DOWN, 51, 0 - 1, 0, 0 - 1)
	expect_event(win, GFX_EVENT_CHAR, 8, 0 - 1, 0, 0 - 1)
	expect_event(win, GFX_EVENT_KEY_DOWN, 123, 0 - 1, 0, 0 - 1)
	expect_event(win, GFX_EVENT_NAV, GFX_NAV_LEFT, 0 - 1, 0, 0 - 1)
	assert_equal(123, win.last_keycode)

	# Two wheel notches away from the user, then one back.
	post_scroll(2)
	post_scroll(0 - 1)
	gfx_window_poll(win)
	expect_event(win, GFX_EVENT_SCROLL, 1, 0 - 1, 0, 0 - 1)
	expect_event(win, GFX_EVENT_SCROLL, 1, 0 - 1, 0, 0 - 1)
	expect_event(win, GFX_EVENT_SCROLL, 0 - 1, 0 - 1, 0, 0 - 1)
	assert_equal(0, gfx_window_next_event(win, &none))

	gfx_window_destroy(win)
	return 1


int main(int argc, int argv):
	test_char_translation()
	test_utf8_next()
	test_scroll_notches()
	if (test_window_events() == 0):
		println(c"graphics cocoa input SKIP: no window (no GUI session)")
		return 0
	println(c"graphics cocoa input OK")
	return 0
