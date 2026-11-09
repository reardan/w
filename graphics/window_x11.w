/*
graphics.window_x11: a double-buffered OpenGL window on X11/GLX — the
Linux backend behind graphics.window (see that module for the API
contract shared by every backend).

64-bit only (x86_64 Xlib struct layouts; see graphics.x11): compile
consumers with 'wv2 x64' (or arm64). Design notes:
docs/projects/graphics.md
*/
import lib.lib
import graphics.x11
import graphics.gl
import graphics.event
import graphics.input_queue
import graphics.clipboard_store
import graphics.control
import lib.utf8
import lib.mem


# One INCR transfer a window serves: the requestor deletes the property
# after each chunk and the owner writes the next, ending with a
# zero-length chunk. requestor 0 marks a free slot.
struct gfx_x11_incr_send:
	int requestor
	int property
	int target
	int offset
	char* data
	int length


struct gfx_window:
	int display
	int window
	int context
	int input_method
	int text_focus
	int input_context
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
	# per-frame event ring (graphics.event); drained by
	# gfx_window_next_event
	gfx_input_queue input_queue
	# Clipboard (graphics.clipboard_store): the CLIPBOARD selection this
	# window owns or is reading, the atoms it speaks, the server time of
	# the latest input event (ICCCM asks owners and requestors for a real
	# timestamp, not CurrentTime), and the INCR transfers it is serving.
	gfx_clipboard_store clip
	int clip_time
	int atom_clipboard
	int atom_targets
	int atom_utf8
	int atom_string
	int atom_text
	int atom_plain_utf8
	int atom_incr
	int atom_property
	int atom_html
	int atom_png
	gfx_x11_incr_send[4] incr_sends
	# The PRIMARY selection: the latest selected text, served and read
	# like CLIPBOARD through its own property; primary_claimed while the
	# server still names this window its owner.
	gfx_clipboard_store primary
	int atom_primary_property
	int32 primary_claimed
	# Double- and triple-click counting from ButtonPress server times.
	gfx_click_tracker clicks


gfx_window* gfx_x11_active


# Bytes one ChangeProperty may carry before a transfer switches to INCR;
# 0 derives it from the server's maximum request size. Tests lower it to
# exercise INCR with small payloads.
int gfx_x11_clipboard_chunk


# ---- clipboard: the CLIPBOARD selection (ICCCM §2) ----------------------
#
# Copy claims ownership and keeps a copy of the text; every later
# SelectionRequest from another client is answered from it, for as long
# as this window owns the selection (X11 clipboards empty when their
# owner exits). Paste asks the owner for UTF8_STRING (STRING as a
# fallback) into a property on this window and reads it when
# SelectionNotify arrives; an INCR reply is read chunk by chunk as the
# owner rewrites the property. Text this window owns itself is taken
# straight from the store, without a server round trip.

void gfx_x11_clipboard_init(gfx_window* win):
	gfx_clipboard_store_init(&win.clip)
	win.clip_time = 0
	int d = win.display
	win.atom_clipboard = XInternAtom(d, c"CLIPBOARD", 0)
	win.atom_targets = XInternAtom(d, c"TARGETS", 0)
	win.atom_utf8 = XInternAtom(d, c"UTF8_STRING", 0)
	win.atom_string = 31
	win.atom_text = XInternAtom(d, c"TEXT", 0)
	win.atom_plain_utf8 = XInternAtom(d, c"text/plain;charset=utf-8", 0)
	win.atom_incr = XInternAtom(d, c"INCR", 0)
	win.atom_property = XInternAtom(d, c"W_CLIPBOARD", 0)
	win.atom_html = XInternAtom(d, c"text/html", 0)
	win.atom_png = XInternAtom(d, c"image/png", 0)
	gfx_clipboard_store_init(&win.primary)
	win.atom_primary_property = XInternAtom(d, c"W_PRIMARY", 0)
	win.primary_claimed = 0
	gfx_click_tracker_init(&win.clicks)
	for i in range(4):
		win.incr_sends[i].requestor = 0
		win.incr_sends[i].data = 0


# Largest property payload one request carries.
int gfx_x11_clipboard_chunk_size(gfx_window* win):
	if (gfx_x11_clipboard_chunk > 0): return gfx_x11_clipboard_chunk
	int limit = XMaxRequestSize(win.display) * 4 - 1024
	if (limit > 262144): limit = 262144
	if (limit < 4096): limit = 4096
	return limit


# XA_PRIMARY: a predefined atom, like XA_STRING (31).
const int gfx_x11_atom_primary = 1


# The store and paste property behind a selection atom (CLIPBOARD or
# PRIMARY), or 0 for any other selection.
gfx_clipboard_store* gfx_x11_store(gfx_window* win, int selection):
	if (selection == win.atom_clipboard): return &win.clip
	if (selection == gfx_x11_atom_primary): return &win.primary
	return cast(gfx_clipboard_store*, 0)


int gfx_x11_property(gfx_window* win, int selection):
	if (selection == gfx_x11_atom_primary): return win.atom_primary_property
	return win.atom_property


# Claim selection for what s now owns. Returns 1 when the server made
# this window the owner.
int gfx_x11_claim(gfx_window* win, int selection):
	XSetSelectionOwner(win.display, selection, win.window, win.clip_time)
	int owned = XGetSelectionOwner(win.display, selection) == win.window
	XFlush(win.display)
	return owned


# Claim CLIPBOARD with a copy of text. Returns 1 when the server made
# this window the owner.
int gfx_clipboard_set(gfx_window* win, char* text):
	if (win == 0): return gfx_clipboard_local_set(text)
	gfx_clipboard_store_own(&win.clip, text, strlen(text))
	return gfx_x11_claim(win, win.atom_clipboard)


# Claim CLIPBOARD with text plus text/html and image/png flavors.
int gfx_clipboard_set_rich(gfx_window* win, char* text, char* html, char* png, int png_length):
	if (win == 0): return gfx_clipboard_local_set_rich(text, html, png, png_length)
	gfx_clipboard_store_own_rich(&win.clip, text, html, png, png_length)
	return gfx_x11_claim(win, win.atom_clipboard)


# Publish text as PRIMARY. A selection that keeps changing (a drag)
# claims the server once and then only updates what it serves.
int gfx_primary_set(gfx_window* win, char* text):
	if (win == 0): return gfx_primary_local_set(text)
	gfx_clipboard_store_own(&win.primary, text, strlen(text))
	if (win.primary_claimed == 0): win.primary_claimed = gfx_x11_claim(win, gfx_x11_atom_primary)
	return win.primary_claimed


# Ask the owner of selection for its text as `target`.
void gfx_x11_convert(gfx_window* win, int selection, int target):
	gfx_clipboard_store* s = gfx_x11_store(win, selection)
	int property = gfx_x11_property(win, selection)
	s.target = target
	XDeleteProperty(win.display, win.window, property)
	XConvertSelection(win.display, selection, target, property, win.window, win.clip_time)
	XFlush(win.display)


void gfx_x11_request(gfx_window* win, int selection):
	gfx_clipboard_store* s = gfx_x11_store(win, selection)
	int owner = XGetSelectionOwner(win.display, selection)
	if (owner == win.window):
		gfx_clipboard_store_echo(s)
		return
	if (owner == 0):
		gfx_clipboard_store_deliver(s, c"", 0)
		return
	gfx_clipboard_store_begin(s, GFX_CLIPBOARD_REQUESTED)
	gfx_x11_convert(win, selection, win.atom_utf8)


void gfx_clipboard_request(gfx_window* win):
	if (win == 0):
		gfx_clipboard_local_request()
		return
	gfx_x11_request(win, win.atom_clipboard)


char* gfx_clipboard_take(gfx_window* win):
	if (win == 0): return gfx_clipboard_local_take()
	return gfx_clipboard_store_take(&win.clip)


void gfx_primary_request(gfx_window* win):
	if (win == 0):
		gfx_primary_local_request()
		return
	gfx_x11_request(win, gfx_x11_atom_primary)


char* gfx_primary_take(gfx_window* win):
	if (win == 0): return gfx_primary_local_take()
	return gfx_clipboard_store_take(&win.primary)


# Append Latin-1 bytes (a STRING reply) as UTF-8.
void gfx_x11_clipboard_append_latin1(gfx_clipboard_store* s, char* data, int length):
	char[2] pair
	for i in range(length):
		int c = data[i] & 255
		if (c < 128):
			pair[0] = c
			gfx_clipboard_store_append(s, &pair[0], 1)
		else:
			pair[0] = 192 | (c >> 6)
			pair[1] = 128 | (c & 63)
			gfx_clipboard_store_append(s, &pair[0], 2)


# Read and delete this window's paste property for selection. Returns
# its type (-1 for a format that is not text) and its item count in
# count[0]; the bytes go to the selection's store unless the type is
# INCR.
int gfx_x11_clipboard_read(gfx_window* win, int selection, int* count):
	gfx_clipboard_store* s = gfx_x11_store(win, selection)
	int actual_type = 0
	int32 actual_format = 0
	int nitems = 0
	int after = 0
	char* data = 0
	if (XGetWindowProperty(win.display, win.window, gfx_x11_property(win, selection), 0, 268435455, 1, 0, &actual_type, &actual_format, &nitems, &after, &data) != 0): return 0
	if ((actual_type != win.atom_incr) && (actual_format == 8) && (data != 0)):
		if (actual_type == win.atom_string): gfx_x11_clipboard_append_latin1(s, data, nitems)
		else: gfx_clipboard_store_append(s, data, nitems)
	if (data != 0): XFree(cast(int, data))
	count[0] = nitems
	if ((actual_type != win.atom_incr) && (actual_format != 8)): return 0 - 1
	return actual_type


# The owner answered our XConvertSelection.
void gfx_x11_clipboard_notify(gfx_window* win, x_selection_event* e):
	gfx_clipboard_store* s = gfx_x11_store(win, e.selection)
	if ((s == 0) || (s.state != GFX_CLIPBOARD_REQUESTED)): return
	if (e.property == 0):
		# Refused: an owner without UTF8_STRING may still speak STRING.
		if (s.target == win.atom_utf8):
			gfx_x11_convert(win, e.selection, win.atom_string)
			return
		gfx_clipboard_store_arrive(s)
		return
	int count = 0
	int kind = gfx_x11_clipboard_read(win, e.selection, &count)
	# Reading with delete=True told an INCR owner to send the first chunk.
	if (kind == win.atom_incr): s.state = GFX_CLIPBOARD_INCR
	else: gfx_clipboard_store_arrive(s)


# Write the next chunk of an INCR transfer; the zero-length chunk ends
# it and frees the slot.
void gfx_x11_clipboard_incr_next(gfx_window* win, gfx_x11_incr_send* t):
	int n = t.length - t.offset
	int chunk = gfx_x11_clipboard_chunk_size(win)
	if (n > chunk): n = chunk
	XChangeProperty(win.display, t.requestor, t.property, t.target, 8, 0, &t.data[t.offset], n)
	if (n == 0):
		XSelectInput(win.display, t.requestor, 0)
		free(t.data)
		t.data = 0
		t.requestor = 0
	t.offset = t.offset + n
	XFlush(win.display)


# Answer another client's SelectionRequest from the owned text (and,
# for CLIPBOARD, the rich flavors copied with it).
void gfx_x11_clipboard_serve(gfx_window* win, x_selection_request_event* r):
	int property = r.property
	if (property == 0): property = r.target
	gfx_clipboard_store* s = gfx_x11_store(win, r.selection)
	int text_target = (r.target == win.atom_utf8) || (r.target == win.atom_plain_utf8) || (r.target == win.atom_string) || (r.target == win.atom_text)
	char* data = 0
	int length = 0
	if ((s != 0) && text_target):
		data = s.owned
		length = s.owned_length
	else if ((s != 0) && (r.target == win.atom_html)):
		data = s.html
		length = s.html_length
	else if ((s != 0) && (r.target == win.atom_png)):
		data = s.png
		length = s.png_length
	if ((s == 0) || (r.owner != win.window) || (s.owned == 0)): property = 0
	else if (r.target == win.atom_targets):
		int[7] targets
		targets[0] = win.atom_targets
		targets[1] = win.atom_utf8
		targets[2] = win.atom_plain_utf8
		targets[3] = win.atom_string
		targets[4] = win.atom_text
		int n = 5
		if (s.html != 0):
			targets[n] = win.atom_html
			n = n + 1
		if (s.png != 0):
			targets[n] = win.atom_png
			n = n + 1
		# XA_ATOM = 4, format 32: an array of C longs.
		XChangeProperty(win.display, r.requestor, property, 4, 32, 0, cast(char*, &targets[0]), n)
	else if (data != 0):
		int reply_type = r.target
		if (r.target == win.atom_text): reply_type = win.atom_utf8
		if (length <= gfx_x11_clipboard_chunk_size(win)):
			XChangeProperty(win.display, r.requestor, property, reply_type, 8, 0, data, length)
		else:
			# INCR (ICCCM §2.7.2): announce the size, then feed chunks as
			# the requestor deletes the property.
			int slot = 0 - 1
			for i in range(4):
				if ((slot < 0) && (win.incr_sends[i].requestor == 0)): slot = i
			if (slot < 0): property = 0
			else:
				gfx_x11_incr_send* t = &win.incr_sends[slot]
				t.requestor = r.requestor
				t.property = property
				t.target = reply_type
				t.offset = 0
				t.length = length
				t.data = cast(char*, malloc(length + 1))
				mem_copy[char](t.data, data, length)
				XSelectInput(win.display, r.requestor, PropertyChangeMask)
				int[1] size
				size[0] = length
				XChangeProperty(win.display, r.requestor, property, win.atom_incr, 32, 0, cast(char*, &size[0]), 1)
	else: property = 0
	x_event reply
	reply.selection.event_type = SelectionNotify
	reply.selection.send_event = 1
	reply.selection.display = win.display
	reply.selection.requestor = r.requestor
	reply.selection.selection = r.selection
	reply.selection.target = r.target
	reply.selection.property = property
	reply.selection.time = r.time
	XSendEvent(win.display, r.requestor, 0, 0, &reply)
	XFlush(win.display)


# PropertyNotify, SelectionClear, SelectionRequest and SelectionNotify.
void gfx_x11_clipboard_event(gfx_window* win, x_event* event):
	int event_type = event.event_type
	if (event_type == SelectionRequest): gfx_x11_clipboard_serve(win, &event.selection_request)
	else if (event_type == SelectionNotify): gfx_x11_clipboard_notify(win, &event.selection)
	else if (event_type == SelectionClear):
		# Another client copied or selected: our text is no longer the
		# clipboard (or PRIMARY).
		int cleared = event.selection_clear.selection
		gfx_clipboard_store* s = gfx_x11_store(win, cleared)
		if (s != 0): gfx_clipboard_store_disown(s)
		if (cleared == gfx_x11_atom_primary): win.primary_claimed = 0
	else if (event_type == PropertyNotify):
		x_property_event* p = &event.property
		int selection = 0
		if (p.atom == win.atom_property): selection = win.atom_clipboard
		else if (p.atom == win.atom_primary_property): selection = gfx_x11_atom_primary
		gfx_clipboard_store* s = gfx_x11_store(win, selection)
		if ((p.window == win.window) && (s != 0) && (p.state == 0) && (s.state == GFX_CLIPBOARD_INCR)):
			# A new INCR chunk; the zero-length one ends the transfer.
			int count = 0
			int kind = gfx_x11_clipboard_read(win, selection, &count)
			if ((kind <= 0) || (count == 0)): gfx_clipboard_store_arrive(s)
		else if (p.state == 1):
			for i in range(4):
				gfx_x11_incr_send* t = &win.incr_sends[i]
				if ((t.requestor != 0) && (t.requestor == p.window) && (t.property == p.atom)): gfx_x11_clipboard_incr_next(win, t)


# "#version" line for shader sources that should compile on every
# backend: GLX contexts are compatibility-profile GL, where GLSL 130
# is the sweet spot (the Mac's 3.2-core contexts use 150).
char* gfx_shader_header():
	return c"#version 130\n"


# Open a titled window with a double-buffered RGBA GLX context made
# current. Returns 0 (with a message on stderr) when there is no X
# display or no usable visual.
gfx_window* gfx_window_open(char* title, int width, int height):
	if (__word_size__ != 8):
		print_error(c"graphics.window requires a 64-bit target\n")
		return 0
	# LC_CTYPE only: leave numeric parsing/formatting locale unchanged.
	setlocale(0, c"")
	XSetLocaleModifiers(c"")
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
	attributes.event_mask = ExposureMask | KeyPressMask | KeyReleaseMask | ButtonPressMask | ButtonReleaseMask | PointerMotionMask | StructureNotifyMask | FocusChangeMask | PropertyChangeMask
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
	win.input_method = XOpenIM(display, 0, cast(char*, 0), cast(char*, 0))
	win.input_context = 0
	win.text_focus = 0
	gfx_x11_active = win
	if (win.input_method != 0):
		win.input_context = XCreateIC(win.input_method, c"inputStyle", 1032, c"clientWindow", window, c"focusWindow", window, 0)
	win.wm_delete_atom = wm_delete
	win.width = width
	win.height = height
	win.should_close = 0
	win.mouse_x = 0
	win.mouse_y = 0
	win.mouse_buttons = 0
	win.last_keycode = 0
	gfx_input_queue_init(&win.input_queue)
	gfx_x11_clipboard_init(win)
	glViewport(0, 0, width, height)
	gfx_control_open(title, c"x11")
	return win


# Translate an X modifier state mask (KeyPress/ButtonPress carry it in
# event.input.state) into gfx_mod bits: ShiftMask 1, ControlMask 4,
# Mod1Mask 8 (alt), Mod4Mask 64 (super). LockMask and the pointer-button
# bits are not modifiers as far as widget code is concerned.
int gfx_x11_mods(int state):
	int mods = 0
	if (state & 1): mods = mods | GFX_MOD_SHIFT
	if (state & 4): mods = mods | GFX_MOD_CTRL
	if (state & 8): mods = mods | GFX_MOD_ALT
	if (state & 64): mods = mods | GFX_MOD_SUPER
	return mods


void gfx_window_handle_event(gfx_window* win, x_event* event):
	int event_type = event.event_type
	if (event_type == ClientMessage):
		if (event.client.data0 == win.wm_delete_atom): win.should_close = 1
	else if (event_type == ConfigureNotify):
		win.width = event.configure.width
		win.height = event.configure.height
		glViewport(0, 0, win.width, win.height)
	else if (event_type == DestroyNotify): win.should_close = 1
	else if (event_type == KeyPress):
		int mods = gfx_x11_mods(event.input.state)
		win.clip_time = event.input.time
		win.last_keycode = event.input.detail
		gfx_input_queue_push(&win.input_queue, GFX_EVENT_KEY_DOWN, event.input.detail, event.input.x, event.input.y, mods)
		char[256] text
		int keysym = 0
		if (win.input_context != 0):
			int32 status = 0
			int count = Xutf8LookupString(win.input_context, event, &text[0], 256, &keysym, &status)
			char* bytes = &text[0]
			# XBufferOverflow reports the required size without consuming
			# the commit. Retry with owned storage for long IME commits.
			if ((status == 0 - 1) && (count > 0)):
				bytes = cast(char*, malloc(count))
				count = Xutf8LookupString(win.input_context, event, bytes, count, &keysym, &status)
			if ((status == 2) || (status == 4)):
				int at = 0
				while (at < count):
					int cp = 0
					int n = utf8_scan(bytes + at, count - at, &cp)
					if (n == 0): break
					gfx_input_queue_push(&win.input_queue, GFX_EVENT_CHAR, cp, event.input.x, event.input.y, mods)
					at = at + n
			if (bytes != &text[0]): free(bytes)
		else:
			# Legacy fallback when no input method is available. Modern X
			# Unicode keysyms encode a scalar in their low 24 bits.
			int count = XLookupString(event, &text[0], 256, &keysym, 0)
			int cp = 0
			if (count == 1): cp = text[0] & 255
			else if ((keysym >> 24) == 1): cp = keysym & 0xffffff
			if ((cp > 0) && (cp <= 1114111) && ((cp < 55296) || (cp > 57343))):
				gfx_input_queue_push(&win.input_queue, GFX_EVENT_CHAR, cp, event.input.x, event.input.y, mods)
		# Shift+Tab arrives as ISO_Left_Tab (0xfe20), which Xlib maps to no
		# text; report it as the Tab character with Shift held, as the other
		# backends do, so Shift+Tab focus traversal works on X11.
		if (keysym == 0xfe20):
			gfx_input_queue_push(&win.input_queue, GFX_EVENT_CHAR, 9, event.input.x, event.input.y, mods)
		# Navigation keysyms have no character; translate the portable
		# set (XK_Home 0xff50, XK_Left 0xff51, XK_Up 0xff52,
		# XK_Right 0xff53, XK_Down 0xff54, XK_Page_Up 0xff55,
		# XK_Page_Down 0xff56, XK_End 0xff57, XK_Delete 0xffff) to NAV
		# codes.
		int nav = 0
		if (keysym == 0xff51): nav = GFX_NAV_LEFT
		else if (keysym == 0xff53): nav = GFX_NAV_RIGHT
		else if (keysym == 0xff50): nav = GFX_NAV_HOME
		else if (keysym == 0xff57): nav = GFX_NAV_END
		else if (keysym == 0xff52): nav = GFX_NAV_UP
		else if (keysym == 0xff54): nav = GFX_NAV_DOWN
		else if (keysym == 0xff55): nav = GFX_NAV_PAGE_UP
		else if (keysym == 0xff56): nav = GFX_NAV_PAGE_DOWN
		else if (keysym == 0xffff): nav = GFX_NAV_DELETE
		if (nav != 0):
			gfx_input_queue_push(&win.input_queue, GFX_EVENT_NAV, nav, event.input.x, event.input.y, mods)
	else if (event_type == FocusIn):
		if (win.input_context != 0): XSetICFocus(win.input_context)
	else if (event_type == FocusOut):
		if (win.input_context != 0): XUnsetICFocus(win.input_context)
	else if (event_type == KeyRelease):
		gfx_input_queue_push(&win.input_queue, GFX_EVENT_KEY_UP, event.input.detail, event.input.x, event.input.y, gfx_x11_mods(event.input.state))
	else if (event_type == MotionNotify):
		win.mouse_x = event.input.x
		win.mouse_y = event.input.y
	else if (event_type == ButtonPress):
		int button = event.input.detail
		int button_mods = gfx_x11_mods(event.input.state)
		win.clip_time = event.input.time
		if ((button >= 1) && (button <= 3)):
			win.mouse_buttons = win.mouse_buttons | (1 << (button - 1))
			# Button events carry their own coordinates: update the
			# snapshot too, so a click without prior motion is not
			# attributed to a stale position.
			win.mouse_x = event.input.x
			win.mouse_y = event.input.y
			# X has no double-click setting; count presses by server time.
			int clicks = gfx_click_tracker_press(&win.clicks, button, event.input.time, event.input.x, event.input.y, gfx_click_interval_ms, gfx_click_slop)
			gfx_input_queue_push(&win.input_queue, GFX_EVENT_MOUSE_DOWN, button, event.input.x, event.input.y, gfx_mods_with_clicks(button_mods, clicks))
		else if (button == 4):
			# Wheel notches arrive as button 4 (up) / 5 (down) press+
			# release pairs; one SCROLL per press, releases ignored.
			gfx_input_queue_push(&win.input_queue, GFX_EVENT_SCROLL, 1, event.input.x, event.input.y, button_mods)
		else if (button == 5):
			gfx_input_queue_push(&win.input_queue, GFX_EVENT_SCROLL, 0 - 1, event.input.x, event.input.y, button_mods)
	else if ((event_type >= PropertyNotify) && (event_type <= SelectionNotify)): gfx_x11_clipboard_event(win, event)
	else if (event_type == ButtonRelease):
		int released = event.input.detail
		if ((released >= 1) && (released <= 3)):
			# no bitwise-not operator: -1 - mask == ~mask
			win.mouse_buttons = win.mouse_buttons & (0 - 1 - (1 << (released - 1)))
			win.mouse_x = event.input.x
			win.mouse_y = event.input.y
			gfx_input_queue_push(&win.input_queue, GFX_EVENT_MOUSE_UP, released, event.input.x, event.input.y, gfx_x11_mods(event.input.state))


# graphics.control hooks (docs/projects/wdrive.md): without a window
# manager the server applies the request at once and the usual
# ConfigureNotify updates width/height.
int gfx_x11_control_resize(void* window, int width, int height):
	gfx_window* win = cast(gfx_window*, window)
	XResizeWindow(win.display, win.window, width, height)
	XFlush(win.display)
	return 1


void gfx_x11_control_readback(int x, int y, int w, int h, char* out):
	glReadPixels(x, y, w, h, GL_RGBA, GL_UNSIGNED_BYTE, out)


void gfx_x11_control_target(gfx_window* win, gfx_control_target* t):
	t.window = cast(void*, win)
	t.queue = &win.input_queue
	t.width = &win.width
	t.height = &win.height
	t.should_close = &win.should_close
	t.mouse_x = &win.mouse_x
	t.mouse_y = &win.mouse_y
	t.mouse_buttons = &win.mouse_buttons
	t.pixel_width = 0
	t.pixel_height = 0
	t.resize = gfx_x11_control_resize
	t.readback = gfx_x11_control_readback


# Drain pending X events. Returns 1 while the window should stay open.
int gfx_window_poll(gfx_window* win):
	gfx_x11_active = win
	gfx_input_queue_begin(&win.input_queue)
	while (XPending(win.display) > 0):
		x_event event
		XNextEvent(win.display, &event)
		if (XFilterEvent(&event, 0) == 0): gfx_window_handle_event(win, &event)
	if (gfx_control_active()):
		gfx_control_target t
		gfx_x11_control_target(win, &t)
		gfx_control_poll(&t)
	if (win.should_close): return 0
	return 1


# Pop the oldest queued input event (graphics.event); returns 1 while
# events remain from the polls since the last drain.
int gfx_window_next_event(gfx_window* win, gfx_event* out):
	return gfx_input_queue_next(&win.input_queue, out)


void gfx_window_swap(gfx_window* win):
	if (gfx_control_active()):
		gfx_control_target t
		gfx_x11_control_target(win, &t)
		gfx_control_swap(&t)
	glXSwapBuffers(win.display, win.window)


# Device pixels per logical window pixel, for graphics.ui's crisp text
# (ui_render_set_pixel_scale). This backend draws 1:1.
float32 gfx_window_pixel_ratio(gfx_window* win):
	return 1.0


void gfx_window_destroy(gfx_window* win):
	if (gfx_x11_active == win): gfx_x11_active = cast(gfx_window*, 0)
	gfx_input_queue_free(&win.input_queue)
	if (win.input_context != 0): XDestroyIC(win.input_context)
	if (win.input_method != 0): XCloseIM(win.input_method)
	for i in range(4):
		if (win.incr_sends[i].data != 0): free(win.incr_sends[i].data)
	gfx_clipboard_store_free(&win.clip)
	gfx_clipboard_store_free(&win.primary)
	glXMakeCurrent(win.display, 0, 0)
	glXDestroyContext(win.display, win.context)
	XDestroyWindow(win.display, win.window)
	XCloseDisplay(win.display)
	free(win)
