# wbuild: name=graphics_win32_input_test arch_only=win64 expect_stdout="graphics win32 input"
/*
Win32 input translation (#463). First the pure helpers (WM_CHAR UTF-16
decoding with surrogate pairs, virtual-key nav codes, signed LPARAM
halves); then, with a real window, messages posted to it with
PostMessageW and read back through gfx_window_poll and
gfx_window_next_event, which runs the whole path: the message pump,
the window procedure behind its win_callback thunk, and the event ring.
Resize and close go through the same procedure.

Prints "graphics win32 input OK", or a SKIP line when no window can be
opened (no desktop session, e.g. headless Wine).
*/
import lib.lib
import lib.assert
import graphics.window
import graphics.event

c_lib "user32.dll"
extern int PostMessageW(int hwnd, int msg, int wparam, int lparam)


void test_char_translation():
	int32[1] pending
	pending[0] = 0
	assert_equal('a', gfx_win32_char(&pending[0], 'a'))
	assert_equal(233, gfx_win32_char(&pending[0], 233))
	assert_equal(0x4e2d, gfx_win32_char(&pending[0], 0x4e2d))
	assert_equal(8, gfx_win32_char(&pending[0], 8))
	assert_equal(9, gfx_win32_char(&pending[0], 9))
	assert_equal(13, gfx_win32_char(&pending[0], 13))
	assert_equal(27, gfx_win32_char(&pending[0], 27))
	assert_equal(0, gfx_win32_char(&pending[0], 1))
	assert_equal(0, gfx_win32_char(&pending[0], 127))
	# U+1F600 arrives as the pair D83D DE00
	assert_equal(0, gfx_win32_char(&pending[0], 0xd83d))
	assert_equal(0x1f600, gfx_win32_char(&pending[0], 0xde00))
	# a lone low surrogate is dropped
	assert_equal(0, gfx_win32_char(&pending[0], 0xde00))


void test_nav_and_coordinates():
	assert_equal(GFX_NAV_LEFT, gfx_win32_nav(37))
	assert_equal(GFX_NAV_UP, gfx_win32_nav(38))
	assert_equal(GFX_NAV_RIGHT, gfx_win32_nav(39))
	assert_equal(GFX_NAV_DOWN, gfx_win32_nav(40))
	assert_equal(GFX_NAV_HOME, gfx_win32_nav(36))
	assert_equal(GFX_NAV_END, gfx_win32_nav(35))
	assert_equal(GFX_NAV_PAGE_UP, gfx_win32_nav(33))
	assert_equal(GFX_NAV_PAGE_DOWN, gfx_win32_nav(34))
	assert_equal(GFX_NAV_DELETE, gfx_win32_nav(46))
	assert_equal(0, gfx_win32_nav('A'))
	assert_equal(10, gfx_win32_lo16((20 << 16) | 10))
	assert_equal(20, gfx_win32_hi16((20 << 16) | 10))
	assert_equal(0 - 5, gfx_win32_lo16(65531))
	assert_equal(0 - 120, gfx_win32_hi16(65416 << 16))


void expect_event(gfx_window* win, int kind, int code):
	gfx_event event
	asserts(c"an event is queued", gfx_window_next_event(win, &event))
	assert_equal(kind, event.kind)
	assert_equal(code, event.code)


int main(int argc, int argv):
	test_char_translation()
	test_nav_and_coordinates()

	gfx_window* win = gfx_window_open(c"w win32 input \xc3\xa9", 200, 150)
	if (win == 0):
		println(c"graphics win32 input SKIP (no window)")
		return 0
	gfx_window_poll(win)
	# Drain whatever the shell sent while the window appeared.
	gfx_event stale
	while (gfx_window_next_event(win, &stale)):
		stale.kind = 0

	int hwnd = win.hwnd
	PostMessageW(hwnd, 256, 37, 0)                     # WM_KEYDOWN VK_LEFT
	PostMessageW(hwnd, 257, 37, 0)                     # WM_KEYUP
	PostMessageW(hwnd, 258, 'a', 0)                    # WM_CHAR
	PostMessageW(hwnd, 258, 0xd83d, 0)                 # WM_CHAR high surrogate
	PostMessageW(hwnd, 258, 0xde00, 0)                 # WM_CHAR low surrogate
	PostMessageW(hwnd, 512, 0, (40 << 16) | 30)        # WM_MOUSEMOVE (30, 40)
	PostMessageW(hwnd, 513, 1, (20 << 16) | 10)        # WM_LBUTTONDOWN (10, 20)
	PostMessageW(hwnd, 514, 0, (21 << 16) | 11)        # WM_LBUTTONUP (11, 21)
	PostMessageW(hwnd, 516, 2, (20 << 16) | 10)        # WM_RBUTTONDOWN
	PostMessageW(hwnd, 517, 0, (20 << 16) | 10)        # WM_RBUTTONUP
	PostMessageW(hwnd, 522, 240 << 16, 0)              # WM_MOUSEWHEEL +2 notches
	PostMessageW(hwnd, 522, 65416 << 16, 0)            # WM_MOUSEWHEEL -1 notch
	asserts(c"window still open", gfx_window_poll(win))

	expect_event(win, GFX_EVENT_KEY_DOWN, 37)
	expect_event(win, GFX_EVENT_NAV, GFX_NAV_LEFT)
	expect_event(win, GFX_EVENT_KEY_UP, 37)
	expect_event(win, GFX_EVENT_CHAR, 'a')
	expect_event(win, GFX_EVENT_CHAR, 0x1f600)
	gfx_event down
	asserts(c"mouse down queued", gfx_window_next_event(win, &down))
	assert_equal(GFX_EVENT_MOUSE_DOWN, down.kind)
	assert_equal(1, down.code)
	assert_equal(10, down.x)
	assert_equal(20, down.y)
	expect_event(win, GFX_EVENT_MOUSE_UP, 1)
	expect_event(win, GFX_EVENT_MOUSE_DOWN, 3)
	expect_event(win, GFX_EVENT_MOUSE_UP, 3)
	expect_event(win, GFX_EVENT_SCROLL, 1)
	expect_event(win, GFX_EVENT_SCROLL, 1)
	expect_event(win, GFX_EVENT_SCROLL, 0 - 1)
	gfx_event none
	assert_equal(0, gfx_window_next_event(win, &none))
	assert_equal(0, win.mouse_buttons)

	PostMessageW(hwnd, 5, 0, (90 << 16) | 120)         # WM_SIZE 120 x 90
	gfx_window_poll(win)
	assert_equal(120, win.width)
	assert_equal(90, win.height)

	PostMessageW(hwnd, 16, 0, 0)                       # WM_CLOSE
	assert_equal(0, gfx_window_poll(win))
	gfx_window_destroy(win)
	println(c"graphics win32 input OK")
	return 0
