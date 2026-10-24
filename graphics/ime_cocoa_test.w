# wbuild: name=graphics_ime_cocoa_darwin arch_only=arm64_darwin
/*
The NSTextInputClient bridge (graphics.ime_cocoa) end to end. Cross-
compiled in Linux CI; on a Mac run tools/mac/build_text_input.sh, copy
bin/libwtextinput.dylib beside this binary and run it in a GUI session.
Synthetic key-downs (built as in graphics/cocoa_input_test.w) go through
interpretKeyEvents: once a field is focused: plain typing commits through
insertText: exactly once, arrows and Backspace come back as commands and
keep the window's own translation, and a focus change ends the preview
of the old field. insertText:replacementRange: is also sent directly,
as an input method would.

Prints "graphics ime cocoa OK", or a SKIP line when no window can be
opened (no GUI session).
*/
import lib.lib
import lib.assert
import lib.ci_skip
import graphics.cocoa
import graphics.window
import graphics.event
import graphics.ime_cocoa
import graphics.__arch__.text_input

c_lib "/System/Library/Frameworks/ApplicationServices.framework/Versions/A/ApplicationServices"
extern int CGEventCreateKeyboardEvent(int source, int keycode, int down)
extern void CGEventKeyboardSetUnicodeString(int event, int length, int16* text)
extern void CFRelease(int object)

c_lib "/usr/lib/libobjc.A.dylib"
extern int objc_msg3(int receiver, int selector, int a, int b, int c) = "objc_msgSend"


void post_key(int keycode, int16* text, int length):
	int cg = CGEventCreateKeyboardEvent(0, keycode, 1)
	CGEventKeyboardSetUnicodeString(cg, length, text)
	int app = objc_msg0(objc_getClass(c"NSApplication"), sel_registerName(c"sharedApplication"))
	int event = objc_msg1(objc_getClass(c"NSEvent"), sel_registerName(c"eventWithCGEvent:"), cg)
	objc_msg2(app, sel_registerName(c"postEvent:atStart:"), event, 0)
	CFRelease(cg)


void expect_event(gfx_window* win, int kind, int code):
	gfx_event e
	assert_equal(1, gfx_window_next_event(win, &e))
	assert_equal(kind, e.kind)
	assert_equal(code, e.code)


void test_event_mapping(gfx_window* win):
	# Bridge entries become window events addressed to the focused field.
	gfx_cocoa_text_input_event(win, GFX_COCOA_TEXTIN_PREEDIT_BEGIN, 1, 0)
	gfx_cocoa_text_input_event(win, GFX_COCOA_TEXTIN_PREEDIT_TEXT, 0x4e2d, 0)
	gfx_cocoa_text_input_event(win, GFX_COCOA_TEXTIN_PREEDIT_END, 0, 0)
	gfx_cocoa_text_input_event(win, GFX_COCOA_TEXTIN_COMMIT, 0xe9, GFX_MOD_ALT | GFX_MOD_CTRL)
	gfx_event e
	assert_equal(1, gfx_window_next_event(win, &e))
	assert_equal(GFX_EVENT_PREEDIT_BEGIN, e.kind)
	assert_equal(5, e.x)
	assert_equal(1, e.y)
	expect_event(win, GFX_EVENT_PREEDIT_TEXT, 0x4e2d)
	expect_event(win, GFX_EVENT_PREEDIT_END, 0)
	assert_equal(1, gfx_window_next_event(win, &e))
	assert_equal(GFX_EVENT_CHAR, e.kind)
	assert_equal(0xe9, e.code)
	# Option stays (it typed the character); Control is dropped.
	assert_equal(GFX_MOD_ALT, e.mods)


int main(int argc, int argv):
	gfx_window* win = gfx_window_open(c"IME bridge smoke", 300, 200)
	if (win == 0):
		test_skip(c"graphics ime cocoa SKIP: no Cocoa GUI session")
		return 0
	assert_equal(1, gfx_cocoa_text_input_enable(win))
	assert_equal(1, gfx_cocoa_text_input_enable(win))
	gfx_text_input(1, 0, 10, 20, 100, 24, 5)
	assert_equal(5, win.text_focus)
	test_event_mapping(win)

	int16[2] text
	text[0] = 'a'
	post_key(0, &text[0], 1)
	text[0] = 127
	post_key(51, &text[0], 1)
	text[0] = cast(int16, 0xf702)
	post_key(123, &text[0], 1)
	gfx_window_poll(win)
	expect_event(win, GFX_EVENT_KEY_DOWN, 0)
	expect_event(win, GFX_EVENT_CHAR, 'a')
	expect_event(win, GFX_EVENT_KEY_DOWN, 51)
	expect_event(win, GFX_EVENT_CHAR, 8)
	expect_event(win, GFX_EVENT_KEY_DOWN, 123)
	# The NAV waits behind this frame's text until the next poll.
	gfx_event none
	assert_equal(0, gfx_window_next_event(win, &none))
	gfx_window_poll(win)
	expect_event(win, GFX_EVENT_NAV, GFX_NAV_LEFT)
	assert_equal(0, gfx_window_next_event(win, &none))

	# An input method's commit: one CHAR per scalar, astral included.
	int str = objc_msg1(objc_getClass(c"NSString"), sel_registerName(c"stringWithUTF8String:"), cast(int, c"\xe4\xb8\xad\xf0\x9f\x98\x80"))
	# NSNotFound (NSIntegerMax) as the replacement range's location.
	int not_found = ((1 << 62) - 1) + (1 << 62)
	objc_msg3(win.text_bridge, sel_registerName(c"insertText:replacementRange:"), str, not_found, 0)
	gfx_window_poll(win)
	expect_event(win, GFX_EVENT_CHAR, 0x4e2d)
	expect_event(win, GFX_EVENT_CHAR, 0x1f600)

	# Leaving the field ends its preview; with no field, keys bypass the
	# bridge and translate as before.
	gfx_text_input(0, 0, 0, 0, 0, 0, 5)
	assert_equal(0, win.text_focus)
	gfx_event e
	assert_equal(1, gfx_window_next_event(win, &e))
	assert_equal(GFX_EVENT_PREEDIT_END, e.kind)
	assert_equal(5, e.x)
	text[0] = 'b'
	post_key(11, &text[0], 1)
	gfx_window_poll(win)
	expect_event(win, GFX_EVENT_KEY_DOWN, 11)
	expect_event(win, GFX_EVENT_CHAR, 'b')

	gfx_cocoa_text_input_disable(win)
	assert_equal(0, win.text_bridge)
	gfx_window_destroy(win)
	print(c"graphics ime cocoa OK\n")
	return 0
