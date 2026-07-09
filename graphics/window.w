/*
graphics.window: a double-buffered OpenGL window on X11/GLX.

The happy path is four calls:

	gfx_window* win = gfx_window_open(c"demo", 640, 480)
	while (gfx_window_poll(win)):
		# ... glClear / draw ...
		gfx_window_swap(win)
	gfx_window_destroy(win)

gfx_window_poll drains the X event queue, tracks resize / close /
basic input state, and returns 0 once the user closed the window.
WM_DELETE_WINDOW is registered so window-manager close buttons work.

64-bit only (x86_64 Xlib struct layouts; see graphics.x11): compile
consumers with 'wv2 x64'. Design notes: docs/projects/graphics.md
*/
import lib.lib
import graphics.x11
import graphics.gl


struct gfx_window:
	int display
	int window
	int context
	int wm_delete_atom
	int32 width
	int32 height
	int32 should_close
	# last known pointer position and button mask (bit 0 = left,
	# bit 1 = middle, bit 2 = right), and the most recent keycode
	int32 mouse_x
	int32 mouse_y
	int32 mouse_buttons
	int32 last_keycode


# Open a titled window with a double-buffered RGBA GLX context made
# current. Returns 0 (with a message on stderr) when there is no X
# display or no usable visual.
gfx_window* gfx_window_open(char* title, int width, int height):
	if (__word_size__ != 8):
		print_error(c"graphics.window requires the x64 target\n")
		return 0
	int display = XOpenDisplay(0)
	if (display == 0):
		print_error(c"graphics.window: cannot open X display\n")
		return 0

	int screen = XDefaultScreen(display)
	int32[16] visual_attribs
	visual_attribs[0] = GLX_RGBA
	visual_attribs[1] = GLX_DOUBLEBUFFER
	visual_attribs[2] = GLX_DEPTH_SIZE
	visual_attribs[3] = 16
	visual_attribs[4] = 0
	x_visual_info* visual = glXChooseVisual(display, screen, &visual_attribs[0])
	if (visual == 0):
		print_error(c"graphics.window: no matching GLX visual\n")
		XCloseDisplay(display)
		return 0

	int root = XRootWindow(display, screen)
	x_set_window_attributes attributes
	attributes.colormap = XCreateColormap(display, root, visual.visual, 0)
	attributes.event_mask = ExposureMask | KeyPressMask | KeyReleaseMask | ButtonPressMask | ButtonReleaseMask | PointerMotionMask | StructureNotifyMask
	attributes.border_pixel = 0
	int window = XCreateWindow(display, root, 0, 0, width, height, 0, visual.depth, InputOutput, visual.visual, CWBorderPixel | CWEventMask | CWColormap, &attributes)
	XStoreName(display, window, title)

	# Ask the window manager to send ClientMessage instead of killing us
	int wm_delete = XInternAtom(display, c"WM_DELETE_WINDOW", 0)
	XSetWMProtocols(display, window, &wm_delete, 1)

	XMapWindow(display, window)

	int context = glXCreateContext(display, visual, 0, 1)
	XFree(cast(int, visual))
	if (context == 0):
		print_error(c"graphics.window: glXCreateContext failed\n")
		XDestroyWindow(display, window)
		XCloseDisplay(display)
		return 0
	glXMakeCurrent(display, window, context)

	gfx_window* win = new gfx_window()
	win.display = display
	win.window = window
	win.context = context
	win.wm_delete_atom = wm_delete
	win.width = width
	win.height = height
	win.should_close = 0
	win.mouse_x = 0
	win.mouse_y = 0
	win.mouse_buttons = 0
	win.last_keycode = 0
	glViewport(0, 0, width, height)
	return win


void gfx_window_handle_event(gfx_window* win, x_event* event):
	int event_type = event.event_type
	if (event_type == ClientMessage):
		if (event.client.data0 == win.wm_delete_atom):
			win.should_close = 1
	else if (event_type == ConfigureNotify):
		win.width = event.configure.width
		win.height = event.configure.height
		glViewport(0, 0, win.width, win.height)
	else if (event_type == DestroyNotify):
		win.should_close = 1
	else if (event_type == KeyPress):
		win.last_keycode = event.input.detail
	else if (event_type == MotionNotify):
		win.mouse_x = event.input.x
		win.mouse_y = event.input.y
	else if (event_type == ButtonPress):
		int button = event.input.detail
		if ((button >= 1) & (button <= 3)):
			win.mouse_buttons = win.mouse_buttons | (1 << (button - 1))
	else if (event_type == ButtonRelease):
		int released = event.input.detail
		if ((released >= 1) & (released <= 3)):
			# no bitwise-not operator: -1 - mask == ~mask
			win.mouse_buttons = win.mouse_buttons & (0 - 1 - (1 << (released - 1)))


# Drain pending X events. Returns 1 while the window should stay open.
int gfx_window_poll(gfx_window* win):
	while (XPending(win.display) > 0):
		x_event event
		XNextEvent(win.display, &event)
		gfx_window_handle_event(win, &event)
	if (win.should_close):
		return 0
	return 1


void gfx_window_swap(gfx_window* win):
	glXSwapBuffers(win.display, win.window)


void gfx_window_destroy(gfx_window* win):
	glXMakeCurrent(win.display, 0, 0)
	glXDestroyContext(win.display, win.context)
	XDestroyWindow(win.display, win.window)
	XCloseDisplay(win.display)
	free(win)
