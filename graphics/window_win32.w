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
	WM_DPICHANGED               dpi, and the window takes the suggested
	                            rectangle
	WM_KEYDOWN / WM_KEYUP       KEY_DOWN / KEY_UP (code = the Win32
	                            virtual-key code), NAV for the arrows,
	                            Home/End, PgUp/PgDn and Delete
	WM_CHAR                     CHAR (UTF-16 decoded to Unicode scalars)
	mouse buttons / motion      mouse_x/mouse_y/mouse_buttons +
	                            MOUSE_DOWN/MOUSE_UP (1 left, 2 middle,
	                            3 right)
	WM_MOUSEWHEEL               SCROLL, one event per 120-unit notch

One window at a time: the window procedure finds its gfx_window through
a module global (Win32 hands it only the HWND).

DPI: the process declares itself per-monitor DPI aware (v2 where the
system has it, else system aware), so Windows never bitmap-stretches the
window. The backend works in logical pixels, like the web backend: at
150% (144 DPI) a 1280x800 window gets a 1920x1200 client area,
width/height and the pointer stay in 1280x800 logical units, the GL
viewport covers the physical pixels, and gfx_window_pixel_ratio reports
1.5 so graphics.ui rasterizes text at device resolution. WM_DPICHANGED
(moving to a monitor with another scale) updates the ratio and resizes
the window to the rectangle Windows suggests.

Design notes: docs/projects/graphics.md
*/
import lib.lib
import graphics.gl
import graphics.event
import graphics.input_queue
import lib.mem
import graphics.text_unicode
import graphics.clipboard_store


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
extern int LoadCursorW(int instance, int name)
extern int AdjustWindowRect(int32* rect, int style, int menu)
extern int GetKeyState(int virtual_key)
extern int ScreenToClient(int hwnd, int32* point)
extern int SetCapture(int hwnd)
extern int ReleaseCapture()
extern int SetWindowPos(int hwnd, int after, int x, int y, int width, int height, int flags)
extern int GetClientRect(int hwnd, int32* rect)
extern int OpenClipboard(int hwnd)
extern int CloseClipboard()
extern int EmptyClipboard()
extern int SetClipboardData(int format, int memory)
extern int GetClipboardData(int format)
extern int RegisterClipboardFormatA(char* name)
extern int GetMessageTime()
extern int GetDoubleClickTime()
extern int GetSystemMetrics(int index)

c_lib "kernel32.dll"
extern int GlobalAlloc(int flags, int bytes)
extern char* GlobalLock(int memory)
extern int GlobalUnlock(int memory)
extern int GlobalFree(int memory)

c_lib "imm32.dll"
extern int ImmGetContext(int hwnd)
extern int ImmReleaseContext(int hwnd, int context)
extern int ImmGetCompositionStringW(int context, int index, char* buffer, int length)
extern int ImmSetCompositionWindow(int context, int32* form)
extern int ImmNotifyIME(int context, int action, int index, int value)

c_lib "gdi32.dll"
extern int GetDeviceCaps(int dc, int index)
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
	int32 text_focus
	int32 pending_surrogate
	int32 last_keycode
	# dots per inch of the window's monitor (96 = 100%) and the client
	# area in physical pixels; width/height above are logical pixels
	int32 dpi
	int32 pixel_width
	int32 pixel_height
	# per-frame event ring (graphics.event); drained by
	# gfx_window_next_event
	gfx_input_queue input_queue
	# Clipboard (graphics.clipboard_store); the Win32 clipboard is
	# synchronous, so a request arrives before gfx_clipboard_take runs.
	gfx_clipboard_store clip
	# Double- and triple-click counting (GetMessageTime against the
	# user's GetDoubleClickTime).
	gfx_click_tracker clicks


gfx_window* gfx_win32_active    /* the window the procedure reports into */

# Optional WM_GETOBJECT (0x3D) handler, e.g. the UI Automation bridge's
# ui_access_uia_wm_getobject. A nonzero result is the message's answer;
# zero (or no hook) falls through to DefWindowProcW as before.
type gfx_win32_getobject_fn = fn(int, int, int) -> int
gfx_win32_getobject_fn* gfx_win32_getobject
int gfx_win32_class_registered
char* gfx_win32_class_name


# Same GLSL dialect as the GLX backend: legacy WGL contexts are
# compatibility profile.
char* gfx_shader_header():
	return c"#version 130\n"


# Optional user32 entry points, resolved at run time so the program
# still loads on Windows versions without them.
type gfx_win32_fn1 = fn(int) -> int
type gfx_win32_fn0 = fn() -> int

int gfx_win32_user32_function(char* name, int nargs):
	int user32 = GetModuleHandleA(c"user32.dll")
	if (user32 == 0): return 0
	int sym = GetProcAddress(user32, name)
	if (sym == 0): return 0
	return win_c_function(sym, nargs, 1)


# Declare per-monitor DPI awareness before the first window exists:
# SetProcessDpiAwarenessContext(PER_MONITOR_AWARE_V2 = -4, else
# PER_MONITOR_AWARE = -3) on Windows 10 1703+, SetProcessDPIAware on
# older systems.
int gfx_win32_dpi_declared
void gfx_win32_declare_dpi_awareness():
	if (gfx_win32_dpi_declared): return
	gfx_win32_dpi_declared = 1
	gfx_win32_fn1* set_context = cast(gfx_win32_fn1*, gfx_win32_user32_function(c"SetProcessDpiAwarenessContext", 1))
	if (set_context != 0):
		if (set_context(0 - 4) != 0): return
		if (set_context(0 - 3) != 0): return
	gfx_win32_fn0* set_aware = cast(gfx_win32_fn0*, gfx_win32_user32_function(c"SetProcessDPIAware", 0))
	if (set_aware != 0): set_aware()


# The window's DPI: GetDpiForWindow (Windows 10 1607+), else the screen
# DC's LOGPIXELSX (88). Never below 48, so a bad answer cannot divide by
# zero or shrink the UI to nothing.
int gfx_win32_window_dpi(int hwnd):
	int dpi = 0
	gfx_win32_fn1* for_window = cast(gfx_win32_fn1*, gfx_win32_user32_function(c"GetDpiForWindow", 1))
	if (for_window != 0): dpi = for_window(hwnd)
	if (dpi <= 0):
		int dc = GetDC(0)
		dpi = cast(int32, GetDeviceCaps(dc, 88))
		ReleaseDC(0, dc)
	if (dpi < 48): dpi = 96
	return dpi


# Physical (device) pixels to logical pixels and back at the window's DPI.
int gfx_win32_logical(gfx_window* win, int v):
	if (win.dpi == 96): return v
	if (v < 0): return 0 - ((0 - v) * 96 + win.dpi - 1) / win.dpi
	return v * 96 / win.dpi


int gfx_win32_physical(gfx_window* win, int v):
	if (win.dpi == 96): return v
	return (v * win.dpi + 48) / 96


# Apply a client size in physical pixels: logical size, GL viewport.
void gfx_win32_client_size(gfx_window* win, int pixel_width, int pixel_height):
	win.pixel_width = pixel_width
	win.pixel_height = pixel_height
	win.width = (pixel_width * 96 + win.dpi / 2) / win.dpi
	win.height = (pixel_height * 96 + win.dpi / 2) / win.dpi
	if (win.context != 0): glViewport(0, 0, pixel_width, pixel_height)


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
	if (x >= 32768): x = x - 65536
	return x


int gfx_win32_hi16(int v):
	return gfx_win32_lo16(v >> 16)


void gfx_win32_push(gfx_window* win, int kind, int code, int mods):
	gfx_input_queue_push(&win.input_queue, kind, code, win.mouse_x, win.mouse_y, mods)


# Portable NAV code for a Win32 virtual-key code, or 0.
int gfx_win32_nav(int vk):
	switch (vk):
		case 37: return GFX_NAV_LEFT
		case 39: return GFX_NAV_RIGHT
		case 36: return GFX_NAV_HOME
		case 35: return GFX_NAV_END
		case 38: return GFX_NAV_UP
		case 40: return GFX_NAV_DOWN
		case 33: return GFX_NAV_PAGE_UP
		case 34: return GFX_NAV_PAGE_DOWN
		case 46: return GFX_NAV_DELETE
		default: return 0


void gfx_win32_button(gfx_window* win, int button, int down, int lparam):
	win.mouse_x = gfx_win32_logical(win, gfx_win32_lo16(lparam))
	win.mouse_y = gfx_win32_logical(win, gfx_win32_hi16(lparam))
	int bit = 1 << (button - 1)
	if (down):
		# Keep receiving the release when it happens outside the window.
		if (win.mouse_buttons == 0): SetCapture(win.hwnd)
		win.mouse_buttons = win.mouse_buttons | bit
		# SM_CXDOUBLECLK (36) is the whole rectangle a second click may
		# land in, centred on the first.
		int slop = GetSystemMetrics(36) / 2
		int clicks = gfx_click_tracker_press(&win.clicks, button, GetMessageTime(), win.mouse_x, win.mouse_y, GetDoubleClickTime(), slop)
		gfx_win32_push(win, GFX_EVENT_MOUSE_DOWN, button, gfx_mods_with_clicks(gfx_win32_mods(), clicks))
	else:
		# no bitwise-not operator: -1 - mask == ~mask
		win.mouse_buttons = win.mouse_buttons & (0 - 1 - bit)
		if (win.mouse_buttons == 0): ReleaseCapture()
		gfx_win32_push(win, GFX_EVENT_MOUSE_UP, button, gfx_win32_mods())


# Read a native preedit snapshot without inserting it into the document.
# Committed results remain owned by DefWindowProcW -> WM_CHAR, so every
# commit takes exactly one path through the UTF-16 decoder.
void gfx_win32_preedit(gfx_window* win):
	int im = ImmGetContext(win.hwnd)
	if (im == 0): return
	int length = cast(int32, ImmGetCompositionStringW(im, 8, cast(char*, 0), 0))
	gfx_input_queue_push(&win.input_queue, GFX_EVENT_PREEDIT_BEGIN, 0, win.text_focus, 0, 0)
	if (length > 0):
		char* bytes = cast(char*, malloc(length))
		int count = cast(int32, ImmGetCompositionStringW(im, 8, bytes, length))
		if (count > length): count = length
		int32 high = 0
		int at = 0
		while (at + 1 < count):
			int cp = gfx_utf16_input(&high, (bytes[at] & 255) | ((bytes[at + 1] & 255) << 8))
			if (cp >= 0): gfx_input_queue_push(&win.input_queue, GFX_EVENT_PREEDIT_TEXT, cp, win.text_focus, 0, 0)
			at = at + 2
		free(bytes)
	ImmReleaseContext(win.hwnd, im)


# The window procedure (WNDPROC), entered through a win_callback thunk.
# Only the low 32 bits of msg are defined (it is a UINT in edx).
int gfx_win32_wndproc(int hwnd, int msg, int wparam, int lparam):
	gfx_window* win = gfx_win32_active
	int m = msg & 65535
	if ((win == 0) || (win.hwnd != hwnd)): return DefWindowProcW(hwnd, msg, wparam, lparam)
	if ((m == 16) || (m == 2)):          /* WM_CLOSE, WM_DESTROY */
		win.should_close = 1
		return 0
	if ((m == 61) && (gfx_win32_getobject != 0)):  /* WM_GETOBJECT */
		int answer = gfx_win32_getobject(hwnd, wparam, lparam)
		if (answer != 0): return answer
	if (m == 5):                          /* WM_SIZE */
		gfx_win32_client_size(win, lparam & 65535, (lparam >> 16) & 65535)
		return 0
	if (m == 736):                        /* WM_DPICHANGED */
		win.dpi = wparam & 65535
		if (win.dpi < 48): win.dpi = 96
		# lparam points at the RECT Windows suggests for the new scale.
		char* suggested = cast(char*, lparam)
		int left = load_int32(suggested)
		int top = load_int32(suggested + 4)
		SetWindowPos(hwnd, 0, left, top, load_int32(suggested + 8) - left, load_int32(suggested + 12) - top, 20)  /* SWP_NOZORDER | SWP_NOACTIVATE */
		gfx_win32_client_size(win, win.pixel_width, win.pixel_height)
		return 0
	if ((m == 256) || (m == 260)):        /* WM_KEYDOWN, WM_SYSKEYDOWN */
		int mods = gfx_win32_mods()
		int vk = wparam & 255
		win.last_keycode = vk
		gfx_win32_push(win, GFX_EVENT_KEY_DOWN, vk, mods)
		int nav = gfx_win32_nav(vk)
		if (nav != 0): gfx_win32_push(win, GFX_EVENT_NAV, nav, mods)
		if (m == 260): return DefWindowProcW(hwnd, msg, wparam, lparam)
		return 0
	if ((m == 257) || (m == 261)):        /* WM_KEYUP, WM_SYSKEYUP */
		gfx_win32_push(win, GFX_EVENT_KEY_UP, wparam & 255, gfx_win32_mods())
		if (m == 261): return DefWindowProcW(hwnd, msg, wparam, lparam)
		return 0
	if (m == 269):                        /* WM_IME_STARTCOMPOSITION */
		gfx_input_queue_push(&win.input_queue, GFX_EVENT_PREEDIT_BEGIN, 0, win.text_focus, 0, 0)
	if (m == 271):                        /* WM_IME_COMPOSITION */
		if (lparam & 8): gfx_win32_preedit(win)
		if ((lparam & 2048) || (lparam == 0)):
			gfx_input_queue_push(&win.input_queue, GFX_EVENT_PREEDIT_END, 0, win.text_focus, 0, 0)
	if (m == 270):                        /* WM_IME_ENDCOMPOSITION */
		gfx_input_queue_push(&win.input_queue, GFX_EVENT_PREEDIT_END, 0, win.text_focus, 0, 0)
	if (m == 258):                        /* WM_CHAR */
		int ch = gfx_utf16_input(&win.pending_surrogate, wparam)
		if (ch < 0): return 0
		int mods = gfx_win32_mods()
		# Ctrl+letter arrives as its control code (Ctrl+S is 19),
		# forwarded for shortcuts (graphics.event).
		int ctrl_code = (ch >= 1) && (ch <= 26) && ((mods & GFX_MOD_CTRL) != 0)
		if (((ch >= 32) && (ch != 127)) || (ch == 8) || (ch == 9) || (ch == 13) || (ch == 27) || ctrl_code):
			gfx_win32_push(win, GFX_EVENT_CHAR, ch, mods)
		return 0
	if (m == 265):                        /* WM_UNICHAR */
		if (wparam == 65535): return 1     /* UNICODE_NOCHAR capability query */
		if ((wparam >= 32) && (wparam <= 1114111) && ((wparam < 55296) || (wparam > 57343))):
			gfx_win32_push(win, GFX_EVENT_CHAR, wparam, gfx_win32_mods())
		return 0
	if (m == 8):                          /* WM_KILLFOCUS */
		win.pending_surrogate = 0
		gfx_input_queue_push(&win.input_queue, GFX_EVENT_PREEDIT_END, 0, win.text_focus, 0, 0)
	if (m == 512):                        /* WM_MOUSEMOVE */
		win.mouse_x = gfx_win32_logical(win, gfx_win32_lo16(lparam))
		win.mouse_y = gfx_win32_logical(win, gfx_win32_hi16(lparam))
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
		win.mouse_x = gfx_win32_logical(win, point[0])
		win.mouse_y = gfx_win32_logical(win, point[1])
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


# WNDCLASSEXA (80 bytes on x64) for the class every gfx window uses.
int gfx_win32_register_class(int instance):
	if (gfx_win32_class_registered): return 1
	int proc = win_callback(cast(int, gfx_win32_wndproc), 4)
	if (proc == 0): return 0
	char* wc = cast(char*, malloc(80))
	mem_fill(wc, 0, 80)
	save_int32(wc, 80)                    /* cbSize */
	save_int32(wc + 4, 35)                /* CS_OWNDC | CS_HREDRAW | CS_VREDRAW */
	save_int64(wc + 8, proc)              /* lpfnWndProc */
	save_int64(wc + 24, instance)         /* hInstance */
	save_int64(wc + 40, LoadCursorW(0, 32512))    /* IDC_ARROW */
	gfx_win32_class_name = gfx_utf16_from_utf8(c"w_gfx_window")
	save_int64(wc + 64, cast(int, gfx_win32_class_name))   /* lpszClassName */
	int atom = RegisterClassExW(wc)
	free(wc)
	if (atom == 0):
		free(gfx_win32_class_name)
		gfx_win32_class_name = cast(char*, 0)
		return 0
	gfx_win32_class_registered = 1
	return 1


# PIXELFORMATDESCRIPTOR (40 bytes): double-buffered RGBA8 with a 24-bit
# depth and 8-bit stencil buffer.
char* gfx_win32_pixel_format():
	char* pfd = cast(char*, malloc(40))
	mem_fill(pfd, 0, 40)
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
	gfx_win32_declare_dpi_awareness()
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
	win.dpi = 96
	win.pixel_width = width
	win.pixel_height = height
	win.should_close = 0
	win.mouse_x = 0
	win.mouse_y = 0
	win.mouse_buttons = 0
	win.last_keycode = 0
	win.pending_surrogate = 0
	win.text_focus = 0
	gfx_input_queue_init(&win.input_queue)
	gfx_clipboard_store_init(&win.clip)
	gfx_click_tracker_init(&win.clicks)
	gfx_win32_active = win

	int use_default = 0 - 2147483648  /* CW_USEDEFAULT */
	char* wide_title = gfx_utf16_from_utf8(title)
	int hwnd = CreateWindowExW(0, gfx_win32_class_name, wide_title, style, use_default, use_default, rect[2] - rect[0], rect[3] - rect[1], 0, 0, instance, 0)
	free(wide_title)
	if (hwnd == 0):
		print_error(c"graphics.window: CreateWindowExW failed\n")
		gfx_win32_active = cast(gfx_window*, 0)
		gfx_input_queue_free(&win.input_queue)
		free(win)
		return 0
	win.hwnd = hwnd
	# width x height are logical pixels: grow the window to the same
	# logical size at its monitor's scale.
	win.dpi = gfx_win32_window_dpi(hwnd)
	if (win.dpi != 96):
		rect[0] = 0
		rect[1] = 0
		rect[2] = gfx_win32_physical(win, width)
		rect[3] = gfx_win32_physical(win, height)
		AdjustWindowRect(&rect[0], style, 0)
		SetWindowPos(hwnd, 0, 0, 0, rect[2] - rect[0], rect[3] - rect[1], 22)  /* SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE */
	int32[4] client
	if (cast(int32, GetClientRect(hwnd, &client[0])) != 0): gfx_win32_client_size(win, client[2] - client[0], client[3] - client[1])

	int dc = GetDC(hwnd)
	char* pfd = gfx_win32_pixel_format()
	int format = ChoosePixelFormat(dc, pfd)
	int ok = 0
	if (format != 0): ok = SetPixelFormat(dc, format, pfd)
	free(pfd)
	if (ok == 0):
		print_error(c"graphics.window: no usable OpenGL pixel format\n")
		ReleaseDC(hwnd, dc)
		DestroyWindow(hwnd)
		gfx_win32_active = cast(gfx_window*, 0)
		gfx_input_queue_free(&win.input_queue)
		free(win)
		return 0
	int context = wglCreateContext(dc)
	if ((context == 0) || (wglMakeCurrent(dc, context) == 0)):
		print_error(c"graphics.window: wglCreateContext failed\n")
		if (context != 0): wglDeleteContext(context)
		ReleaseDC(hwnd, dc)
		DestroyWindow(hwnd)
		gfx_win32_active = cast(gfx_window*, 0)
		gfx_input_queue_free(&win.input_queue)
		free(win)
		return 0
	win.dc = dc
	win.context = context
	ShowWindow(hwnd, 5)               /* SW_SHOW */
	glViewport(0, 0, win.pixel_width, win.pixel_height)
	return win


# ---- clipboard: CF_UNICODETEXT ------------------------------------------
#
# Copy writes UTF-16 with CR LF line ends into a GMEM_MOVEABLE block the
# clipboard then owns; paste reads CF_UNICODETEXT back and decodes it to
# UTF-8 (the store turns CR LF into LF). OpenClipboard fails while
# another process holds the clipboard open, so both sides retry briefly.

const int gfx_win32_cf_unicodetext = 13


int gfx_win32_open_clipboard(gfx_window* win):
	for attempt in range(10):
		if (OpenClipboard(win.hwnd) != 0): return 1
		Sleep(5)
	return 0


# Hand bytes[0..length) to the open clipboard as format, NUL-padded
# with pad zero bytes. Returns 1 when the clipboard took the block.
int gfx_win32_clipboard_put(int format, char* bytes, int length, int pad):
	int memory = GlobalAlloc(2, length + pad)            /* GMEM_MOVEABLE */
	if (memory == 0): return 0
	int ok = 0
	char* dst = GlobalLock(memory)
	if (dst != 0):
		mem_copy[char](dst, bytes, length)
		for i in range(pad): dst[length + i] = 0
		GlobalUnlock(memory)
		# On success the clipboard owns the block; free it only on
		# failure.
		if (SetClipboardData(format, memory) != 0): ok = 1
	if (ok == 0): GlobalFree(memory)
	return ok


# Write what win.clip owns: CF_UNICODETEXT, plus the registered
# "HTML Format" (CF_HTML, graphics.clipboard_store's gfx_clipboard_cf_html)
# and "PNG" formats when the copy carried them.
int gfx_win32_clipboard_publish(gfx_window* win):
	char* text = win.clip.owned
	int length = win.clip.owned_length
	# LF -> CR LF, then UTF-16.
	char* crlf = cast(char*, malloc(length * 2 + 1))
	int n = 0
	for i in range(length):
		if ((text[i] == 10) && ((i == 0) || (text[i - 1] != 13))):
			crlf[n] = 13
			n = n + 1
		crlf[n] = text[i]
		n = n + 1
	crlf[n] = 0
	char* wide = gfx_utf16_from_utf8(crlf)
	free(crlf)
	int units = 0
	while ((wide[units * 2] != 0) || (wide[units * 2 + 1] != 0)): units = units + 1
	int ok = 0
	if (gfx_win32_open_clipboard(win)):
		EmptyClipboard()
		ok = gfx_win32_clipboard_put(gfx_win32_cf_unicodetext, wide, units * 2, 2)
		if (ok && (win.clip.html != 0)):
			char* html = gfx_clipboard_cf_html(win.clip.html)
			gfx_win32_clipboard_put(RegisterClipboardFormatA(c"HTML Format"), html, strlen(html), 1)
			free(html)
		if (ok && (win.clip.png != 0)):
			gfx_win32_clipboard_put(RegisterClipboardFormatA(c"PNG"), win.clip.png, win.clip.png_length, 0)
		CloseClipboard()
	free(wide)
	return ok


int gfx_clipboard_set(gfx_window* win, char* text):
	if (win == 0): return gfx_clipboard_local_set(text)
	gfx_clipboard_store_own(&win.clip, text, strlen(text))
	return gfx_win32_clipboard_publish(win)


int gfx_clipboard_set_rich(gfx_window* win, char* text, char* html, char* png, int png_length):
	if (win == 0): return gfx_clipboard_local_set_rich(text, html, png, png_length)
	gfx_clipboard_store_own_rich(&win.clip, text, html, png, png_length)
	return gfx_win32_clipboard_publish(win)


# Windows has no PRIMARY selection; middle-click pastes the program's own
# latest selection (graphics.clipboard_store's in-process PRIMARY).
int gfx_primary_set(gfx_window* win, char* text):
	return gfx_primary_local_set(text)


void gfx_primary_request(gfx_window* win):
	gfx_primary_local_request()


char* gfx_primary_take(gfx_window* win):
	return gfx_primary_local_take()


# Decode NUL-terminated UTF-16 into the store as UTF-8.
void gfx_win32_clipboard_decode(gfx_window* win, char* wide):
	int32 pending = 0
	char[4] bytes
	int at = 0
	while (1):
		int unit = (wide[at] & 255) | ((wide[at + 1] & 255) << 8)
		if (unit == 0): break
		at = at + 2
		int cp = gfx_utf16_input(&pending, unit)
		if (cp < 0): continue
		int n = 1
		if (cp < 128): bytes[0] = cp
		else if (cp < 2048):
			bytes[0] = 192 | (cp >> 6)
			bytes[1] = 128 | (cp & 63)
			n = 2
		else if (cp < 65536):
			bytes[0] = 224 | (cp >> 12)
			bytes[1] = 128 | ((cp >> 6) & 63)
			bytes[2] = 128 | (cp & 63)
			n = 3
		else:
			bytes[0] = 240 | (cp >> 18)
			bytes[1] = 128 | ((cp >> 12) & 63)
			bytes[2] = 128 | ((cp >> 6) & 63)
			bytes[3] = 128 | (cp & 63)
			n = 4
		gfx_clipboard_store_append(&win.clip, &bytes[0], n)


void gfx_clipboard_request(gfx_window* win):
	if (win == 0):
		gfx_clipboard_local_request()
		return
	gfx_clipboard_store_begin(&win.clip, GFX_CLIPBOARD_REQUESTED)
	if (gfx_win32_open_clipboard(win)):
		int memory = GetClipboardData(gfx_win32_cf_unicodetext)
		if (memory != 0):
			char* wide = GlobalLock(memory)
			if (wide != 0):
				gfx_win32_clipboard_decode(win, wide)
				GlobalUnlock(memory)
		CloseClipboard()
	gfx_clipboard_store_arrive(&win.clip)


char* gfx_clipboard_take(gfx_window* win):
	if (win == 0): return gfx_clipboard_local_take()
	return gfx_clipboard_store_take(&win.clip)


# Drain pending window messages. Returns 1 while the window should stay
# open.
int gfx_window_poll(gfx_window* win):
	gfx_input_queue_begin(&win.input_queue)
	char* msg = cast(char*, malloc(48))            /* MSG */
	while (PeekMessageW(msg, 0, 0, 0, 1)):     /* PM_REMOVE */
		if ((load_int32(msg + 8) & 65535) == 18):  /* WM_QUIT */
			win.should_close = 1
		TranslateMessage(msg)
		DispatchMessageW(msg)
	free(msg)
	if (win.should_close): return 0
	return 1


# Pop the oldest queued input event (graphics.event); returns 1 while
# events remain from the polls since the last drain.
int gfx_window_next_event(gfx_window* win, gfx_event* out):
	return gfx_input_queue_next(&win.input_queue, out)


void gfx_window_swap(gfx_window* win):
	SwapBuffers(win.dc)


# Device pixels per logical window pixel, for graphics.ui's crisp text
# (ui_render_set_pixel_scale): the window's DPI over 96.
float32 gfx_window_pixel_ratio(gfx_window* win):
	return cast(float32, win.dpi) / 96.0


void gfx_window_destroy(gfx_window* win):
	gfx_input_queue_free(&win.input_queue)
	gfx_clipboard_store_free(&win.clip)
	wglMakeCurrent(0, 0)
	wglDeleteContext(win.context)
	ReleaseDC(win.hwnd, win.dc)
	gfx_win32_active = cast(gfx_window*, 0)
	DestroyWindow(win.hwnd)
	free(win)
