/*
graphics.window_win32: a double-buffered OpenGL window on Win32/WGL --
the win64 backend behind graphics.window (see that module for the API
contract shared by every backend).

gfx_window_open registers a window class whose window procedure is a W
function reached through a win_callback thunk (lib/__arch__/win64/
syscalls.w), creates an overlapped window, picks a double-buffered
RGBA8 + depth24 pixel format and makes a legacy wglCreateContext
context current -- on current drivers that is the highest
compatibility-profile version, where GLSL 130 compiles (so
gfx_shader_header matches GLX's). GL 2+ entry points resolve through
wglGetProcAddress (graphics.gl_win32).

gfx_window_poll pumps the thread's message queue (PeekMessage /
DispatchMessage); the window procedure turns messages into the shared
polling state and the graphics.event ring:

	WM_CLOSE / WM_DESTROY       should_close (the window is not destroyed
	                            until gfx_window_destroy)
	WM_SIZE                     width/height + glViewport
	WM_KEYDOWN / WM_KEYUP       KEY_DOWN / KEY_UP (code = the Win32
	                            virtual-key code), NAV for the arrows,
	                            Home/End, PgUp/PgDn and Delete
	WM_CHAR                     CHAR (any Unicode codepoint: the window
	                            class is a Unicode one, and UTF-16
	                            surrogate pairs are joined; the ASCII
	                            control set 8/9/13/27 passes, other
	                            controls are dropped)
	mouse buttons / motion      mouse_x/mouse_y/mouse_buttons +
	                            MOUSE_DOWN/MOUSE_UP (1 left, 2 middle,
	                            3 right)
	WM_MOUSEWHEEL               SCROLL, one event per 120-unit notch

One window at a time: the window procedure finds its gfx_window through
a module global (Win32 hands it only the HWND). The window title is
UTF-8, converted to UTF-16 for CreateWindowExW.

Design notes: docs/projects/graphics.md
*/
import lib.lib
import graphics.gl
import graphics.event


c_lib "user32.dll"
extern int RegisterClassExW(char* window_class)
extern int CreateWindowExW(int ex_style, char* class_name, char* title, int style, int x, int y, int width, int height, int parent, int menu, int instance, int param)
extern int ShowWindow(int hwnd, int show)
extern int PeekMessageW(char* msg, int hwnd, int filter_min, int filter_max, int remove)
extern int TranslateMessage(char* msg)
extern int DispatchMessageW(char* msg)
extern int DefWindowProcW(int hwnd, int msg, int wparam, int lparam)
extern int DestroyWindow(int hwnd)
extern int GetDC(int hwnd)
extern int ReleaseDC(int hwnd, int dc)
extern int LoadCursorA(int instance, int name)
extern int AdjustWindowRect(int32* rect, int style, int menu)
extern int GetKeyState(int virtual_key)
extern int ScreenToClient(int hwnd, int32* point)
extern int SetCapture(int hwnd)
extern int ReleaseCapture()

c_lib "gdi32.dll"
extern int ChoosePixelFormat(int dc, char* descriptor)
extern int SetPixelFormat(int dc, int format, char* descriptor)
extern int SwapBuffers(int dc)


struct gfx_window:
	int hwnd
	int dc
	int context
	int32 width
	int32 height
	int32 should_close
	# last known pointer position and button mask (bit 0 = left,
	# bit 1 = middle, bit 2 = right), and the most recent keycode
	int32 mouse_x
	int32 mouse_y
	int32 mouse_buttons
	int32 last_keycode
	# a WM_CHAR high surrogate waiting for its low half, or 0
	int32 pending_surrogate
	# per-frame event ring (graphics.event); drained by
	# gfx_window_next_event
	int32 event_head
	int32 event_tail
	int32[320] event_ring


gfx_window* gfx_win32_active    /* the window the procedure reports into */
int gfx_win32_class_registered


# Same GLSL dialect as the GLX backend: legacy WGL contexts are
# compatibility profile.
char* gfx_shader_header():
	return c"#version 130\n"


# Modifier state from GetKeyState: a SHORT whose high bit means "down"
# (only the low 16 bits of the return register are defined).
int gfx_win32_mods():
	int mods = 0
	if (GetKeyState(16) & 32768):      /* VK_SHIFT */
		mods = mods | GFX_MOD_SHIFT
	if (GetKeyState(17) & 32768):      /* VK_CONTROL */
		mods = mods | GFX_MOD_CTRL
	if (GetKeyState(18) & 32768):      /* VK_MENU (alt) */
		mods = mods | GFX_MOD_ALT
	if ((GetKeyState(91) & 32768) || (GetKeyState(92) & 32768)):  /* VK_LWIN, VK_RWIN */
		mods = mods | GFX_MOD_SUPER
	return mods


# Signed 16-bit halves of a packed LPARAM coordinate pair.
int gfx_win32_lo16(int v):
	int x = v & 65535
	if (x >= 32768):
		x = x - 65536
	return x


int gfx_win32_hi16(int v):
	return gfx_win32_lo16(v >> 16)


void gfx_win32_push(gfx_window* win, int kind, int code, int mods):
	gfx_event_ring_push(&win.event_ring[0], &win.event_head, &win.event_tail, kind, code, win.mouse_x, win.mouse_y, mods)


# Portable NAV code for a Win32 virtual-key code, or 0.
int gfx_win32_nav(int vk):
	if (vk == 37):
		return GFX_NAV_LEFT
	if (vk == 39):
		return GFX_NAV_RIGHT
	if (vk == 36):
		return GFX_NAV_HOME
	if (vk == 35):
		return GFX_NAV_END
	if (vk == 38):
		return GFX_NAV_UP
	if (vk == 40):
		return GFX_NAV_DOWN
	if (vk == 33):
		return GFX_NAV_PAGE_UP
	if (vk == 34):
		return GFX_NAV_PAGE_DOWN
	if (vk == 46):
		return GFX_NAV_DELETE
	return 0


void gfx_win32_button(gfx_window* win, int button, int down, int lparam):
	win.mouse_x = gfx_win32_lo16(lparam)
	win.mouse_y = gfx_win32_hi16(lparam)
	int bit = 1 << (button - 1)
	if (down):
		# Keep receiving the release when it happens outside the window.
		if (win.mouse_buttons == 0):
			SetCapture(win.hwnd)
		win.mouse_buttons = win.mouse_buttons | bit
		gfx_win32_push(win, GFX_EVENT_MOUSE_DOWN, button, gfx_win32_mods())
	else:
		# no bitwise-not operator: -1 - mask == ~mask
		win.mouse_buttons = win.mouse_buttons & (0 - 1 - bit)
		if (win.mouse_buttons == 0):
			ReleaseCapture()
		gfx_win32_push(win, GFX_EVENT_MOUSE_UP, button, gfx_win32_mods())


# The GFX_EVENT_CHAR code for one UTF-16 unit of WM_CHAR, or 0 when it
# is not a character yet (a high surrogate, stored in *pending) or not
# text at all (control characters outside 8/9/13/27, DEL, a lone low
# surrogate).
int gfx_win32_char(int32* pending, int unit):
	unit = unit & 65535
	if ((unit >= 55296) && (unit <= 56319)):           /* high surrogate */
		*pending = unit
		return 0
	if ((unit >= 56320) && (unit <= 57343)):           /* low surrogate */
		int high = *pending
		*pending = 0
		if (high == 0):
			return 0
		return 65536 + ((high - 55296) << 10) + (unit - 56320)
	*pending = 0
	if ((unit == 8) || (unit == 9) || (unit == 13) || (unit == 27)):
		return unit
	if ((unit < 32) || (unit == 127)):
		return 0
	return unit


# Malloc'd NUL-terminated UTF-16 copy of a UTF-8 string (invalid bytes
# become U+FFFD).
char* gfx_win32_wide(char* text):
	int n = 0
	while (text[n] != 0):
		n = n + 1
	char* out = malloc(n * 4 + 2)
	int i = 0
	int o = 0
	while (text[i] != 0):
		int b = text[i] & 255
		int cp = 65533
		int len = 1
		if (b < 128):
			cp = b
		else if (((b & 224) == 192) && ((text[i + 1] & 192) == 128)):
			cp = ((b & 31) << 6) | (text[i + 1] & 63)
			len = 2
		else if (((b & 240) == 224) && ((text[i + 1] & 192) == 128) && ((text[i + 2] & 192) == 128)):
			cp = ((b & 15) << 12) | ((text[i + 1] & 63) << 6) | (text[i + 2] & 63)
			len = 3
		else if (((b & 248) == 240) && ((text[i + 1] & 192) == 128) && ((text[i + 2] & 192) == 128) && ((text[i + 3] & 192) == 128)):
			cp = ((b & 7) << 18) | ((text[i + 1] & 63) << 12) | ((text[i + 2] & 63) << 6) | (text[i + 3] & 63)
			len = 4
		if (cp >= 65536):
			cp = cp - 65536
			save_int16(out + o, 55296 + (cp >> 10))
			save_int16(out + o + 2, 56320 + (cp & 1023))
			o = o + 4
		else:
			save_int16(out + o, cp)
			o = o + 2
		i = i + len
	save_int16(out + o, 0)
	return out


# The window procedure (WNDPROC), entered through a win_callback thunk.
# Only the low 32 bits of msg are defined (it is a UINT in edx).
int gfx_win32_wndproc(int hwnd, int msg, int wparam, int lparam):
	gfx_window* win = gfx_win32_active
	int m = msg & 65535
	if ((win == 0) || (win.hwnd != hwnd)):
		return DefWindowProcW(hwnd, msg, wparam, lparam)
	if ((m == 16) || (m == 2)):          /* WM_CLOSE, WM_DESTROY */
		win.should_close = 1
		return 0
	if (m == 5):                          /* WM_SIZE */
		win.width = lparam & 65535
		win.height = (lparam >> 16) & 65535
		if (win.context != 0):
			glViewport(0, 0, win.width, win.height)
		return 0
	if ((m == 256) || (m == 260)):        /* WM_KEYDOWN, WM_SYSKEYDOWN */
		int mods = gfx_win32_mods()
		int vk = wparam & 255
		win.last_keycode = vk
		gfx_win32_push(win, GFX_EVENT_KEY_DOWN, vk, mods)
		int nav = gfx_win32_nav(vk)
		if (nav != 0):
			gfx_win32_push(win, GFX_EVENT_NAV, nav, mods)
		if (m == 260):
			return DefWindowProcW(hwnd, msg, wparam, lparam)
		return 0
	if ((m == 257) || (m == 261)):        /* WM_KEYUP, WM_SYSKEYUP */
		gfx_win32_push(win, GFX_EVENT_KEY_UP, wparam & 255, gfx_win32_mods())
		if (m == 261):
			return DefWindowProcW(hwnd, msg, wparam, lparam)
		return 0
	if (m == 258):                        /* WM_CHAR */
		int ch = gfx_win32_char(&win.pending_surrogate, wparam)
		if (ch != 0):
			gfx_win32_push(win, GFX_EVENT_CHAR, ch, gfx_win32_mods())
		return 0
	if (m == 512):                        /* WM_MOUSEMOVE */
		win.mouse_x = gfx_win32_lo16(lparam)
		win.mouse_y = gfx_win32_hi16(lparam)
		return 0
	if (m == 513):                        /* WM_LBUTTONDOWN */
		gfx_win32_button(win, 1, 1, lparam)
		return 0
	if (m == 514):                        /* WM_LBUTTONUP */
		gfx_win32_button(win, 1, 0, lparam)
		return 0
	if (m == 516):                        /* WM_RBUTTONDOWN */
		gfx_win32_button(win, 3, 1, lparam)
		return 0
	if (m == 517):                        /* WM_RBUTTONUP */
		gfx_win32_button(win, 3, 0, lparam)
		return 0
	if (m == 519):                        /* WM_MBUTTONDOWN */
		gfx_win32_button(win, 2, 1, lparam)
		return 0
	if (m == 520):                        /* WM_MBUTTONUP */
		gfx_win32_button(win, 2, 0, lparam)
		return 0
	if (m == 522):                        /* WM_MOUSEWHEEL */
		# The wheel reports screen coordinates; the event contract wants
		# the client-area pointer position.
		int32[2] point
		point[0] = gfx_win32_lo16(lparam)
		point[1] = gfx_win32_hi16(lparam)
		ScreenToClient(hwnd, &point[0])
		win.mouse_x = point[0]
		win.mouse_y = point[1]
		int delta = gfx_win32_hi16(wparam)
		int wheel_mods = gfx_win32_mods()
		while (delta >= 120):
			gfx_win32_push(win, GFX_EVENT_SCROLL, 1, wheel_mods)
			delta = delta - 120
		while (delta <= 0 - 120):
			gfx_win32_push(win, GFX_EVENT_SCROLL, 0 - 1, wheel_mods)
			delta = delta + 120
		return 0
	return DefWindowProcW(hwnd, msg, wparam, lparam)


# UTF-16 "w_gfx_window", the window class name.
char* gfx_win32_class_name():
	return gfx_win32_wide(c"w_gfx_window")


# WNDCLASSEXW (80 bytes on x64) for the class every gfx window uses.
int gfx_win32_register_class(int instance):
	if (gfx_win32_class_registered):
		return 1
	int proc = win_callback(cast(int, gfx_win32_wndproc), 4)
	if (proc == 0):
		return 0
	char* wc = malloc(80)
	int i = 0
	while (i < 80):
		wc[i] = 0
		i = i + 1
	save_int32(wc, 80)                    /* cbSize */
	save_int32(wc + 4, 35)                /* CS_OWNDC | CS_HREDRAW | CS_VREDRAW */
	save_int64(wc + 8, proc)              /* lpfnWndProc */
	save_int64(wc + 24, instance)         /* hInstance */
	save_int64(wc + 40, LoadCursorA(0, 32512))    /* IDC_ARROW */
	char* class_name = gfx_win32_class_name()
	save_int64(wc + 64, cast(int, class_name))   /* lpszClassName */
	int atom = RegisterClassExW(wc)
	free(class_name)
	free(wc)
	if (atom == 0):
		return 0
	gfx_win32_class_registered = 1
	return 1


# PIXELFORMATDESCRIPTOR (40 bytes): double-buffered RGBA8 with a 24-bit
# depth and 8-bit stencil buffer.
char* gfx_win32_pixel_format():
	char* pfd = malloc(40)
	int i = 0
	while (i < 40):
		pfd[i] = 0
		i = i + 1
	save_int16(pfd, 40)          /* nSize */
	save_int16(pfd + 2, 1)       /* nVersion */
	save_int32(pfd + 4, 37)      /* PFD_DRAW_TO_WINDOW | PFD_SUPPORT_OPENGL | PFD_DOUBLEBUFFER */
	pfd[8] = 0                   /* PFD_TYPE_RGBA */
	pfd[9] = 32                  /* cColorBits */
	pfd[16] = 8                  /* cAlphaBits */
	pfd[23] = 24                 /* cDepthBits */
	pfd[24] = 8                  /* cStencilBits */
	return pfd


# Open a titled window whose client area is width x height with a
# double-buffered GL context made current. Returns 0 (with a message on
# stderr) when any Win32/WGL step fails.
gfx_window* gfx_window_open(char* title, int width, int height):
	if (gfx_win32_active != 0):
		print_error(c"graphics.window: the win32 backend supports one window at a time\n")
		return 0
	int instance = GetModuleHandleA(cast(char*, 0))
	if (gfx_win32_register_class(instance) == 0):
		print_error(c"graphics.window: RegisterClassExW failed\n")
		return 0

	# Grow the outer rectangle so the client area is exactly width x height.
	int style = 282001408             /* WS_OVERLAPPEDWINDOW | WS_VISIBLE */
	int32[4] rect
	rect[0] = 0
	rect[1] = 0
	rect[2] = width
	rect[3] = height
	AdjustWindowRect(&rect[0], style, 0)

	gfx_window* win = new gfx_window()
	win.hwnd = 0
	win.dc = 0
	win.context = 0
	win.width = width
	win.height = height
	win.should_close = 0
	win.mouse_x = 0
	win.mouse_y = 0
	win.mouse_buttons = 0
	win.last_keycode = 0
	win.pending_surrogate = 0
	win.event_head = 0
	win.event_tail = 0
	gfx_win32_active = win

	int use_default = 0 - 2147483648  /* CW_USEDEFAULT */
	char* class_name = gfx_win32_class_name()
	char* wide_title = gfx_win32_wide(title)
	int hwnd = CreateWindowExW(0, class_name, wide_title, style, use_default, use_default, rect[2] - rect[0], rect[3] - rect[1], 0, 0, instance, 0)
	free(class_name)
	free(wide_title)
	if (hwnd == 0):
		print_error(c"graphics.window: CreateWindowExW failed\n")
		gfx_win32_active = cast(gfx_window*, 0)
		free(win)
		return 0
	win.hwnd = hwnd

	int dc = GetDC(hwnd)
	char* pfd = gfx_win32_pixel_format()
	int format = ChoosePixelFormat(dc, pfd)
	int ok = 0
	if (format != 0):
		ok = SetPixelFormat(dc, format, pfd)
	free(pfd)
	if (ok == 0):
		print_error(c"graphics.window: no usable OpenGL pixel format\n")
		ReleaseDC(hwnd, dc)
		DestroyWindow(hwnd)
		gfx_win32_active = cast(gfx_window*, 0)
		free(win)
		return 0
	int context = wglCreateContext(dc)
	if ((context == 0) || (wglMakeCurrent(dc, context) == 0)):
		print_error(c"graphics.window: wglCreateContext failed\n")
		if (context != 0):
			wglDeleteContext(context)
		ReleaseDC(hwnd, dc)
		DestroyWindow(hwnd)
		gfx_win32_active = cast(gfx_window*, 0)
		free(win)
		return 0
	win.dc = dc
	win.context = context
	ShowWindow(hwnd, 5)               /* SW_SHOW */
	glViewport(0, 0, win.width, win.height)
	return win


# Drain pending window messages. Returns 1 while the window should stay
# open.
int gfx_window_poll(gfx_window* win):
	char* msg = malloc(48)            /* MSG */
	while (PeekMessageW(msg, 0, 0, 0, 1)):     /* PM_REMOVE */
		if ((load_int32(msg + 8) & 65535) == 18):  /* WM_QUIT */
			win.should_close = 1
		TranslateMessage(msg)
		DispatchMessageW(msg)
	free(msg)
	if (win.should_close):
		return 0
	return 1


# Pop the oldest queued input event (graphics.event); returns 1 while
# events remain from the polls since the last drain.
int gfx_window_next_event(gfx_window* win, gfx_event* out):
	return gfx_event_ring_next(&win.event_ring[0], &win.event_head, &win.event_tail, out)


void gfx_window_swap(gfx_window* win):
	SwapBuffers(win.dc)


void gfx_window_destroy(gfx_window* win):
	wglMakeCurrent(0, 0)
	wglDeleteContext(win.context)
	ReleaseDC(win.hwnd, win.dc)
	gfx_win32_active = cast(gfx_window*, 0)
	DestroyWindow(win.hwnd)
	free(win)
