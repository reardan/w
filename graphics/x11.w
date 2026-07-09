/*
graphics.x11: minimal Xlib bindings for the graphics stack.

Links libX11.so.6 at load time via the extern/c_lib FFI (the same
mechanism as tests/dynamic_test.w). Only the calls the windowing layer
needs are declared; everything else can be added incrementally.

Handles (Display*, Window, Atom, Colormap, Visual*) are word-sized
opaque values held in W ints, matching C's pointer / unsigned long on
both 32- and 64-bit targets. The struct layouts below, however, are the
x86_64 Xlib layouts (8-byte longs and pointers with C padding written
out explicitly), so this module is 64-bit only: compile consumers with
'wv2 x64'. The host also only ships a 64-bit libX11 here.

Design notes: docs/projects/graphics.md
*/

# Event types (X.h)
enum x_event_type:
	KeyPress = 2
	KeyRelease = 3
	ButtonPress = 4
	ButtonRelease = 5
	MotionNotify = 6
	Expose = 12
	DestroyNotify = 17
	UnmapNotify = 18
	MapNotify = 19
	ConfigureNotify = 22
	ClientMessage = 33


# Event masks (X.h)
enum x_event_mask:
	KeyPressMask = 0x1
	KeyReleaseMask = 0x2
	ButtonPressMask = 0x4
	ButtonReleaseMask = 0x8
	PointerMotionMask = 0x40
	ExposureMask = 0x8000
	StructureNotifyMask = 0x20000


# XCreateWindow valuemask bits (X.h CW*)
enum x_cw_mask:
	CWBackPixel = 0x2
	CWBorderPixel = 0x8
	CWEventMask = 0x800
	CWColormap = 0x2000


enum x_window_class:
	InputOutput = 1


# XVisualInfo, x86_64 layout (Xutil.h): 64 bytes.
struct x_visual_info:
	int visual
	int visual_id
	int32 screen
	int32 depth
	int32 visual_class
	int32 pad0
	int red_mask
	int green_mask
	int blue_mask
	int32 colormap_size
	int32 bits_per_rgb


# XSetWindowAttributes, x86_64 layout (Xlib.h): 112 bytes.
struct x_set_window_attributes:
	int background_pixmap
	int background_pixel
	int border_pixmap
	int border_pixel
	int32 bit_gravity
	int32 win_gravity
	int32 backing_store
	int32 pad0
	int backing_planes
	int backing_pixel
	int32 save_under
	int32 pad1
	int event_mask
	int do_not_propagate_mask
	int32 override_redirect
	int32 pad2
	int colormap
	int cursor


# XKeyEvent / XButtonEvent / XMotionEvent share this prefix on x86_64;
# 'detail' is keycode, button number, or is_hint respectively.
struct x_input_event:
	int32 event_type
	int32 pad0
	int serial
	int32 send_event
	int32 pad1
	int display
	int window
	int root
	int subwindow
	int time
	int32 x
	int32 y
	int32 x_root
	int32 y_root
	int32 state
	int32 detail
	int32 same_screen
	int32 pad2


# XConfigureEvent, x86_64 layout.
struct x_configure_event:
	int32 event_type
	int32 pad0
	int serial
	int32 send_event
	int32 pad1
	int display
	int event
	int window
	int32 x
	int32 y
	int32 width
	int32 height
	int32 border_width
	int32 pad2
	int above
	int32 override_redirect
	int32 pad3


# XClientMessageEvent, x86_64 layout; data0..data4 are the l[5] arm of
# the data union (WM_DELETE_WINDOW arrives in data0). W fixed-array
# fields carry a {data,length} descriptor that C structs do not have,
# so FFI-facing structs spell the elements out.
struct x_client_message_event:
	int32 event_type
	int32 pad0
	int serial
	int32 send_event
	int32 pad1
	int display
	int window
	int message_type
	int32 format
	int32 pad2
	int data0
	int data1
	int data2
	int data3
	int data4


# Padding member sized like C's XEvent (24 longs / 192 bytes on x86_64)
# so an x_event local reserves enough stack for any event XNextEvent
# writes.
struct x_event_padding:
	int p0
	int p1
	int p2
	int p3
	int p4
	int p5
	int p6
	int p7
	int p8
	int p9
	int p10
	int p11
	int p12
	int p13
	int p14
	int p15
	int p16
	int p17
	int p18
	int p19
	int p20
	int p21
	int p22
	int p23


# XEvent: a 192-byte union of every event struct.
union x_event:
	int32 event_type
	x_input_event input
	x_configure_event configure
	x_client_message_event client
	x_event_padding pad


c_lib "libX11.so.6"

extern int XOpenDisplay(char* display_name)
extern int XCloseDisplay(int display)
extern int XDefaultScreen(int display)
extern int XRootWindow(int display, int screen)
extern int XCreateColormap(int display, int window, int visual, int alloc)
extern int XCreateWindow(int display, int parent, int x, int y, int width, int height, int border_width, int depth, int window_class, int visual, int valuemask, x_set_window_attributes* attributes)
extern int XDestroyWindow(int display, int window)
extern int XMapWindow(int display, int window)
extern int XStoreName(int display, int window, char* window_name)
extern int XSelectInput(int display, int window, int event_mask)
extern int XPending(int display)
extern int XNextEvent(int display, x_event* event)
extern int XInternAtom(int display, char* atom_name, int only_if_exists)
extern int XSetWMProtocols(int display, int window, int* protocols, int count)
extern int XFree(int data)
extern int XFlush(int display)
extern int XSync(int display, int discard)
