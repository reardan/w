/*
graphics.control: an in-process control channel that lets a driver
(tools/wdrive.w, an agent, a test) steer an unmodified graphics
program: inject input, step frames, read pixels, take PNG screenshots
and read the graphics.ui accessibility tree. Protocol, CLI and
limitations: docs/projects/wdrive.md.

Activation is by environment only. When W_GFX_CONTROL names a
unix-domain socket path, the first gfx_window_open connects to it as a
client (the driver listens); otherwise nothing here runs past one
pointer test per poll and swap, so ordinary programs pay nothing.

The wire format is NDJSON: one request object per line,
{"id":N,"cmd":"...",...}, answered by one line {"id":N,"ok":true,...}
or {"id":N,"ok":false,"error":"..."}. Requests run strictly in order,
each expanded into a short list of operations that execute at one of
two points of the frame loop:

	poll phase   inside gfx_window_poll, after the platform events:
	             input events go into the window's gfx_input_queue
	             exactly as the backend's own would (updating mouse_x /
	             mouse_y / mouse_buttons too), replies are written
	swap phase   inside gfx_window_swap, before the buffers flip: frame
	             barriers and step counts advance, screenshots and pixel
	             reads see the frame just drawn

so "click" (down, a frame, up, a frame) is answered only once the frame
that consumed the release has been drawn, and a screenshot issued after
it shows the result. Reads are non-blocking polls: with nothing pending
the program runs its loop normally.

Backends describe their window with a gfx_control_target (pointers to
the public gfx_window fields shared by every backend, plus their input
queue and two optional hooks) and call:

	gfx_control_open(title, backend)   in gfx_window_open
	gfx_control_poll(&target)          at the end of gfx_window_poll
	gfx_control_swap(&target)          before presenting the frame

guarded by gfx_control_active(). graphics/ui reaches the channel only
through graphics/control_hooks.w.
*/
import lib.lib
import lib.env
import structures.string
import structures.json
import lib.stream
import graphics.event
import graphics.input_queue
import graphics.image.png
import graphics.control_hooks
import graphics.__arch__.control_transport


# Backend hooks. resize asks the window system for a new client size
# (returns 1 when requested; the size lands later through the backend's
# own configure events). readback fills out with w x h RGBA bytes of
# the frame being presented, bottom row first (glReadPixels order).
type gfx_control_resize_fn = fn(void*, int, int) -> int
type gfx_control_readback_fn = fn(int, int, int, int, char*) -> void


struct gfx_control_target:
	void* window
	gfx_input_queue* queue
	int32* width
	int32* height
	int32* should_close
	int32* mouse_x
	int32* mouse_y
	int32* mouse_buttons
	# framebuffer size for readback; 0 means the logical width/height
	int pixel_width
	int pixel_height
	gfx_control_resize_fn* resize
	gfx_control_readback_fn* readback


const int GFX_CONTROL_OP_HELLO = 1
const int GFX_CONTROL_OP_EVENT = 2
const int GFX_CONTROL_OP_OK = 3
const int GFX_CONTROL_OP_ERROR = 4
const int GFX_CONTROL_OP_RESIZE = 5
const int GFX_CONTROL_OP_SIZE = 6
const int GFX_CONTROL_OP_CLOSE = 7
# swap phase from here on
const int GFX_CONTROL_OP_BARRIER = 8
const int GFX_CONTROL_OP_STEP = 9
const int GFX_CONTROL_OP_SHOT = 10
const int GFX_CONTROL_OP_PIXEL = 11
const int GFX_CONTROL_OP_WAIT_SIZE = 12
const int GFX_CONTROL_OP_A11Y = 13

# An EVENT op whose kind is this only moves the pointer snapshot (X11
# motion queues no event either).
const int GFX_CONTROL_MOVE = 0

# Frames an a11y_tree request waits for a graphics.ui frame, and a
# resize for the window system's configure event.
const int gfx_control_a11y_frames = 3
const int gfx_control_resize_frames = 30


struct gfx_control_op:
	int kind
	int id
	int a
	int b
	int c
	int d
	int e
	char* text
	gfx_control_op* next


struct gfx_control_session:
	int fd
	int eof
	string_builder* input
	# responses, when fd < 0 (the protocol unit test)
	string_builder* out
	gfx_control_op* head
	gfx_control_op* tail
	int frames
	char* title
	char* backend


gfx_control_session* gfx_control_current
int gfx_control_checked


int gfx_control_active():
	return gfx_control_current != 0


# A session over fd (negative: collect responses in session.out).
gfx_control_session* gfx_control_start(int fd, char* title, char* backend):
	gfx_control_session* s = new gfx_control_session()
	s.fd = fd
	s.eof = 0
	s.input = string_new()
	s.out = string_new()
	s.head = cast(gfx_control_op*, 0)
	s.tail = cast(gfx_control_op*, 0)
	s.frames = 0
	s.title = strclone(title)
	s.backend = strclone(backend)
	gfx_control_current = s
	return s


# Connect once per process when W_GFX_CONTROL is set. Returns 1 while
# a session is active.
int gfx_control_open(char* title, char* backend):
	if (gfx_control_current != 0): return 1
	if (gfx_control_checked): return 0
	gfx_control_checked = 1
	char* path = env_get(c"W_GFX_CONTROL")
	if ((path == 0) || (path[0] == 0)): return 0
	int fd = gfx_control_transport_connect(path)
	if (fd < 0):
		print_error(c"graphics.control: cannot connect to W_GFX_CONTROL socket ")
		print_error(path)
		print_error(c"\n")
		return 0
	gfx_control_start(fd, title, backend)
	return 1


void gfx_control_end():
	gfx_control_session* s = gfx_control_current
	if (s == 0): return
	if (s.fd >= 0): gfx_control_transport_close(s.fd)
	while (s.head != 0):
		gfx_control_op* op = s.head
		s.head = op.next
		if (op.text != 0): free(op.text)
		free(op)
	string_free(s.input)
	string_free(s.out)
	free(s.title)
	free(s.backend)
	free(s)
	gfx_control_current = cast(gfx_control_session*, 0)


# ---- responses -----------------------------------------------------------

void gfx_control_append_string(string_builder* sb, char* text):
	string_append_char(sb, '"')
	int i = 0
	while (text[i] != 0):
		int c = text[i] & 255
		if ((c == '"') || (c == 92)):
			string_append_char(sb, 92)
			string_append_char(sb, c)
		else if (c == '\n'): string_append(sb, c"\\n")
		else if (c == '\t'): string_append(sb, c"\\t")
		else if (c == '\r'): string_append(sb, c"\\r")
		else if (c < 32):
			string_append(sb, c"\\u00")
			string_append_char(sb, c"0123456789abcdef"[c >> 4])
			string_append_char(sb, c"0123456789abcdef"[c & 15])
		else: string_append_char(sb, c)
		i = i + 1
	string_append_char(sb, '"')


void gfx_control_field_int(string_builder* sb, char* key, int value):
	string_append(sb, c",\"")
	string_append(sb, key)
	string_append(sb, c"\":")
	string_append_int(sb, value)


void gfx_control_field_string(string_builder* sb, char* key, char* value):
	string_append(sb, c",\"")
	string_append(sb, key)
	string_append(sb, c"\":")
	gfx_control_append_string(sb, value)


string_builder* gfx_control_reply_begin(int id, int ok):
	string_builder* sb = string_new()
	string_append(sb, c"{\"id\":")
	string_append_int(sb, id)
	if (ok): string_append(sb, c",\"ok\":true")
	else: string_append(sb, c",\"ok\":false")
	return sb


void gfx_control_send(gfx_control_session* s, string_builder* sb):
	string_append(sb, c"}\n")
	if (s.fd >= 0):
		if (gfx_control_transport_send(s.fd, sb.data, sb.length) < 0): s.eof = 1
	else: string_append_bytes(s.out, sb.data, sb.length)
	string_free(sb)


void gfx_control_reply_ok(gfx_control_session* s, int id):
	gfx_control_send(s, gfx_control_reply_begin(id, 1))


void gfx_control_reply_error(gfx_control_session* s, int id, char* message):
	string_builder* sb = gfx_control_reply_begin(id, 0)
	gfx_control_field_string(sb, c"error", message)
	gfx_control_send(s, sb)


# ---- the operation queue -------------------------------------------------

gfx_control_op* gfx_control_push(gfx_control_session* s, int kind, int id):
	gfx_control_op* op = new gfx_control_op()
	op.kind = kind
	op.id = id
	op.text = cast(char*, 0)
	op.next = cast(gfx_control_op*, 0)
	if (s.tail == 0): s.head = op
	else: s.tail.next = op
	s.tail = op
	return op


void gfx_control_push_event(gfx_control_session* s, int id, int kind, int code, int x, int y, int mods):
	gfx_control_op* op = gfx_control_push(s, GFX_CONTROL_OP_EVENT, id)
	op.a = kind
	op.b = code
	op.c = x
	op.d = y
	op.e = mods


void gfx_control_push_barrier(gfx_control_session* s, int id):
	gfx_control_push(s, GFX_CONTROL_OP_BARRIER, id)


void gfx_control_push_error(gfx_control_session* s, int id, char* message):
	gfx_control_op* op = gfx_control_push(s, GFX_CONTROL_OP_ERROR, id)
	op.text = strclone(message)


void gfx_control_pop(gfx_control_session* s):
	gfx_control_op* op = s.head
	if (op == 0): return
	s.head = op.next
	if (s.head == 0): s.tail = cast(gfx_control_op*, 0)
	if (op.text != 0): free(op.text)
	free(op)


# ---- request parsing -----------------------------------------------------

# Integer member key of a request, def when absent or not a number.
int gfx_control_num(json_value* request, char* key, int def):
	json_value* v = json_object_get(request, key)
	if (v == 0): return def
	if (v.type == json_type_int()): return v.int_value
	if (v.type == json_type_float()): return cast(int, v.float_value)
	if (v.type == json_type_bool()): return v.int_value
	return def


int gfx_control_has(json_value* request, char* key):
	return json_object_get(request, key) != 0


char* gfx_control_str(json_value* request, char* key):
	json_value* v = json_object_get(request, key)
	if ((v == 0) || (v.type != json_type_string())): return cast(char*, 0)
	return v.string_value


int gfx_control_lower(int c):
	if ((c >= 'A') && (c <= 'Z')): return c + 32
	return c


# Case-insensitive compare of data[0..n) with the lowercase word.
int gfx_control_word(char* data, int n, char* word):
	if (strlen(word) != n): return 0
	for i in range(n):
		if (gfx_control_lower(data[i] & 255) != word[i]): return 0
	return 1


# One modifier name, as a gfx_mod bit, or -1.
int gfx_control_mod_bit(char* data, int n):
	if (gfx_control_word(data, n, c"shift")): return GFX_MOD_SHIFT
	if (gfx_control_word(data, n, c"ctrl") || gfx_control_word(data, n, c"control")): return GFX_MOD_CTRL
	if (gfx_control_word(data, n, c"alt") || gfx_control_word(data, n, c"option")): return GFX_MOD_ALT
	if (gfx_control_word(data, n, c"super") || gfx_control_word(data, n, c"cmd") || gfx_control_word(data, n, c"meta")): return GFX_MOD_SUPER
	return 0 - 1


# "ctrl+shift" style list of modifier names; -1 on an unknown name.
int gfx_control_mods_text(char* text):
	int mods = 0
	int start = 0
	int i = 0
	while (1):
		int c = text[i]
		if ((c == 0) || (c == '+') || (c == ',') || (c == ' ')):
			if (i > start):
				int bit = gfx_control_mod_bit(text + start, i - start)
				if (bit < 0): return 0 - 1
				mods = mods | bit
			start = i + 1
		if (c == 0): break
		i = i + 1
	return mods


# The "mods" member: an int bitmask, "ctrl+shift", or ["ctrl","shift"].
int gfx_control_mods(json_value* request):
	json_value* v = json_object_get(request, c"mods")
	if (v == 0): return 0
	if (v.type == json_type_int()): return v.int_value & gfx_mod_keys
	if (v.type == json_type_string()): return gfx_control_mods_text(v.string_value)
	if (v.type == json_type_array()):
		int mods = 0
		for i in range(json_array_length(v)):
			json_value* item = json_array_get(v, i)
			if (item.type != json_type_string()): return 0 - 1
			int bit = gfx_control_mods_text(item.string_value)
			if (bit < 0): return 0 - 1
			mods = mods | bit
		return mods
	return 0 - 1


# A key name to an event: kind[0] = GFX_EVENT_CHAR or GFX_EVENT_NAV and
# the return value its code; 0 for an unknown name.
int gfx_control_key_code(char* data, int n, int* kind):
	kind[0] = GFX_EVENT_NAV
	if (gfx_control_word(data, n, c"left")): return GFX_NAV_LEFT
	if (gfx_control_word(data, n, c"right")): return GFX_NAV_RIGHT
	if (gfx_control_word(data, n, c"up")): return GFX_NAV_UP
	if (gfx_control_word(data, n, c"down")): return GFX_NAV_DOWN
	if (gfx_control_word(data, n, c"home")): return GFX_NAV_HOME
	if (gfx_control_word(data, n, c"end")): return GFX_NAV_END
	if (gfx_control_word(data, n, c"pageup") || gfx_control_word(data, n, c"page_up")): return GFX_NAV_PAGE_UP
	if (gfx_control_word(data, n, c"pagedown") || gfx_control_word(data, n, c"page_down")): return GFX_NAV_PAGE_DOWN
	if (gfx_control_word(data, n, c"delete") || gfx_control_word(data, n, c"del")): return GFX_NAV_DELETE
	kind[0] = GFX_EVENT_CHAR
	if (gfx_control_word(data, n, c"enter") || gfx_control_word(data, n, c"return")): return 13
	if (gfx_control_word(data, n, c"tab")): return 9
	if (gfx_control_word(data, n, c"backspace")): return 8
	if (gfx_control_word(data, n, c"escape") || gfx_control_word(data, n, c"esc")): return 27
	if (gfx_control_word(data, n, c"space")): return 32
	int cp = 0
	if ((n > 0) && (utf8_scan(data, n, &cp) == n) && (cp >= 32)): return cp
	return 0


# CHAR as a native backend reports it: Shift capitalises a letter and
# Ctrl turns one into its control code (Ctrl+S is 19).
int gfx_control_char_with_mods(int cp, int mods):
	if (((mods & GFX_MOD_SHIFT) != 0) && (cp >= 'a') && (cp <= 'z')): cp = cp - 32
	if (((mods & GFX_MOD_CTRL) != 0) && (((cp >= 'a') && (cp <= 'z')) || ((cp >= 'A') && (cp <= 'Z')))): cp = cp & 31
	return cp


void gfx_control_request_key(gfx_control_session* s, int id, json_value* request, int x, int y):
	int mods = gfx_control_mods(request)
	if (mods < 0):
		gfx_control_push_error(s, id, c"unknown modifier in mods")
		return
	int kind = GFX_EVENT_CHAR
	int code = 0
	char* name = gfx_control_str(request, c"name")
	if (name == 0): name = gfx_control_str(request, c"key")
	if (name != 0):
		# "Ctrl+Shift+Tab": modifiers before the last '+', a lone "+" is
		# the plus key.
		int n = strlen(name)
		int split = n - 1
		while ((split > 0) && (name[split] != '+')): split = split - 1
		if ((split > 0) && (split < n - 1)):
			char* prefix = strclone(name)
			prefix[split] = 0
			int more = gfx_control_mods_text(prefix)
			free(prefix)
			if (more < 0):
				gfx_control_push_error(s, id, c"unknown modifier in key name")
				return
			mods = mods | more
			code = gfx_control_key_code(name + split + 1, n - split - 1, &kind)
		else: code = gfx_control_key_code(name, n, &kind)
		if (code == 0):
			gfx_control_push_error(s, id, c"unknown key name")
			return
	else if (gfx_control_has(request, c"code")): code = gfx_control_num(request, c"code", 0)
	else if (gfx_control_has(request, c"keycode") == 0):
		gfx_control_push_error(s, id, c"key needs name, code or keycode")
		return
	int keycode = gfx_control_num(request, c"keycode", 0 - 1)
	int repeat = gfx_control_num(request, c"repeat", 1)
	if (repeat < 1): repeat = 1
	for r in range(repeat):
		if (keycode >= 0): gfx_control_push_event(s, id, GFX_EVENT_KEY_DOWN, keycode, x, y, mods)
		if (code > 0):
			if (kind == GFX_EVENT_CHAR): gfx_control_push_event(s, id, kind, gfx_control_char_with_mods(code, mods), x, y, mods)
			else: gfx_control_push_event(s, id, kind, code, x, y, mods)
		if (keycode >= 0): gfx_control_push_event(s, id, GFX_EVENT_KEY_UP, keycode, x, y, mods)
		gfx_control_push_barrier(s, id)
	gfx_control_push(s, GFX_CONTROL_OP_OK, id)


void gfx_control_request_text(gfx_control_session* s, int id, json_value* request, int x, int y):
	char* text = gfx_control_str(request, c"text")
	if (text == 0):
		gfx_control_push_error(s, id, c"text needs a string text member")
		return
	int n = strlen(text)
	int at = 0
	int count = 0
	while (at < n):
		int cp = 0
		int k = utf8_scan(text + at, n - at, &cp)
		if (k == 0):
			cp = 65533
			k = 1
		# A newline types Return, as a keyboard would.
		if (cp == '\n'): cp = 13
		gfx_control_push_event(s, id, GFX_EVENT_CHAR, cp, x, y, 0)
		count = count + 1
		# The input queue lets 32 CHARs through per frame.
		if ((count & 31) == 0): gfx_control_push_barrier(s, id)
		at = at + k
	gfx_control_push_barrier(s, id)
	gfx_control_push(s, GFX_CONTROL_OP_OK, id)


# Expand one request line into operations. The pointer position used
# for events without x/y is the window's (passed in by the caller).
void gfx_control_request(gfx_control_session* s, char* line, int mouse_x, int mouse_y):
	json_value* request = json_parse(line)
	if ((request == 0) || (request.type != json_type_object())):
		if (request != 0): json_free(request)
		gfx_control_push_error(s, 0, c"request is not a JSON object")
		return
	int id = gfx_control_num(request, c"id", 0)
	char* cmd = gfx_control_str(request, c"cmd")
	int x = gfx_control_num(request, c"x", mouse_x)
	int y = gfx_control_num(request, c"y", mouse_y)
	int button = gfx_control_num(request, c"button", 1)
	if (cmd == 0): gfx_control_push_error(s, id, c"request has no cmd")
	else if (strcmp(cmd, c"hello") == 0): gfx_control_push(s, GFX_CONTROL_OP_HELLO, id)
	else if (strcmp(cmd, c"move") == 0):
		gfx_control_push_event(s, id, GFX_CONTROL_MOVE, 0, x, y, 0)
		gfx_control_push_barrier(s, id)
		gfx_control_push(s, GFX_CONTROL_OP_OK, id)
	else if (strcmp(cmd, c"click") == 0):
		int count = gfx_control_num(request, c"count", 1)
		if (count < 1): count = 1
		if (count > 15): count = 15
		int mods = gfx_control_mods(request)
		if (mods < 0): mods = 0
		gfx_control_push_event(s, id, GFX_CONTROL_MOVE, 0, x, y, 0)
		for i in range(count):
			gfx_control_push_event(s, id, GFX_EVENT_MOUSE_DOWN, button, x, y, gfx_mods_with_clicks(mods, i + 1))
			gfx_control_push_barrier(s, id)
			gfx_control_push_event(s, id, GFX_EVENT_MOUSE_UP, button, x, y, mods)
			gfx_control_push_barrier(s, id)
		gfx_control_push(s, GFX_CONTROL_OP_OK, id)
	else if ((strcmp(cmd, c"mouse_down") == 0) || (strcmp(cmd, c"mouse_up") == 0)):
		int kind = GFX_EVENT_MOUSE_UP
		int mods = gfx_control_mods(request)
		if (mods < 0): mods = 0
		if (strcmp(cmd, c"mouse_down") == 0):
			kind = GFX_EVENT_MOUSE_DOWN
			mods = gfx_mods_with_clicks(mods, 1)
		gfx_control_push_event(s, id, GFX_CONTROL_MOVE, 0, x, y, 0)
		gfx_control_push_event(s, id, kind, button, x, y, mods)
		gfx_control_push_barrier(s, id)
		gfx_control_push(s, GFX_CONTROL_OP_OK, id)
	else if (strcmp(cmd, c"wheel") == 0):
		int notches = gfx_control_num(request, c"notches", 0)
		int pixels = gfx_control_num(request, c"pixels", 0)
		gfx_control_push_event(s, id, GFX_CONTROL_MOVE, 0, x, y, 0)
		int step = 1
		if (notches < 0): step = 0 - 1
		int left = notches * step
		for i in range(left): gfx_control_push_event(s, id, GFX_EVENT_SCROLL, step, x, y, 0)
		if (pixels != 0): gfx_control_push_event(s, id, GFX_EVENT_SCROLL_PIXELS, pixels, x, y, 0)
		gfx_control_push_barrier(s, id)
		gfx_control_push(s, GFX_CONTROL_OP_OK, id)
	else if (strcmp(cmd, c"key") == 0): gfx_control_request_key(s, id, request, x, y)
	else if (strcmp(cmd, c"text") == 0): gfx_control_request_text(s, id, request, x, y)
	else if (strcmp(cmd, c"resize") == 0):
		int w = gfx_control_num(request, c"w", gfx_control_num(request, c"width", 0))
		int h = gfx_control_num(request, c"h", gfx_control_num(request, c"height", 0))
		if ((w < 1) || (h < 1) || (w > 16384) || (h > 16384)): gfx_control_push_error(s, id, c"resize needs w and h in 1..16384")
		else:
			gfx_control_op* op = gfx_control_push(s, GFX_CONTROL_OP_RESIZE, id)
			op.a = w
			op.b = h
	else if (strcmp(cmd, c"step") == 0):
		gfx_control_op* op = gfx_control_push(s, GFX_CONTROL_OP_STEP, id)
		op.a = gfx_control_num(request, c"frames", 1)
		if (op.a < 1): op.a = 1
	else if (strcmp(cmd, c"screenshot") == 0):
		char* path = gfx_control_str(request, c"path")
		if ((path == 0) || (path[0] == 0)): gfx_control_push_error(s, id, c"screenshot needs a path")
		else:
			gfx_control_op* op = gfx_control_push(s, GFX_CONTROL_OP_SHOT, id)
			op.text = strclone(path)
	else if (strcmp(cmd, c"pixel") == 0):
		gfx_control_op* op = gfx_control_push(s, GFX_CONTROL_OP_PIXEL, id)
		op.a = x
		op.b = y
	else if (strcmp(cmd, c"a11y_tree") == 0): gfx_control_push(s, GFX_CONTROL_OP_A11Y, id)
	else if (strcmp(cmd, c"close") == 0): gfx_control_push(s, GFX_CONTROL_OP_CLOSE, id)
	else:
		string_builder* message = string_from(c"unknown cmd: ")
		string_append(message, cmd)
		gfx_control_push_error(s, id, message.data)
		string_free(message)
	json_free(request)


# Append received bytes and turn every complete line into operations.
void gfx_control_feed(gfx_control_session* s, char* data, int n, int mouse_x, int mouse_y):
	string_append_bytes(s.input, data, n)
	int start = 0
	for i in range(s.input.length):
		if (s.input.data[i] == '\n'):
			s.input.data[i] = 0
			int k = start
			while ((k < i) && (s.input.data[k] == ' ')): k = k + 1
			if ((k < i) && (s.input.data[k] != '\r')): gfx_control_request(s, s.input.data + start, mouse_x, mouse_y)
			start = i + 1
	if (start > 0):
		int rest = s.input.length - start
		for i in range(rest): s.input.data[i] = s.input.data[start + i]
		s.input.length = rest
		s.input.data[rest] = 0


# ---- execution -----------------------------------------------------------

int gfx_control_pixel_w(gfx_control_target* t):
	if (t.pixel_width > 0): return t.pixel_width
	return t.width[0]


int gfx_control_pixel_h(gfx_control_target* t):
	if (t.pixel_height > 0): return t.pixel_height
	return t.height[0]


void gfx_control_run_event(gfx_control_target* t, gfx_control_op* op):
	int kind = op.a
	int pointer = (kind == GFX_CONTROL_MOVE) || (kind == GFX_EVENT_MOUSE_DOWN) || (kind == GFX_EVENT_MOUSE_UP) || (kind == GFX_EVENT_SCROLL) || (kind == GFX_EVENT_SCROLL_PIXELS)
	if (pointer):
		t.mouse_x[0] = op.c
		t.mouse_y[0] = op.d
	if ((kind == GFX_EVENT_MOUSE_DOWN) && (op.b >= 1) && (op.b <= 3)): t.mouse_buttons[0] = t.mouse_buttons[0] | (1 << (op.b - 1))
	if ((kind == GFX_EVENT_MOUSE_UP) && (op.b >= 1) && (op.b <= 3)): t.mouse_buttons[0] = t.mouse_buttons[0] & ~(1 << (op.b - 1))
	if (kind != GFX_CONTROL_MOVE): gfx_input_queue_push(t.queue, kind, op.b, op.c, op.d, op.e)


void gfx_control_reply_size(gfx_control_session* s, gfx_control_target* t, int id, int ok):
	string_builder* sb = gfx_control_reply_begin(id, ok)
	gfx_control_field_int(sb, c"width", t.width[0])
	gfx_control_field_int(sb, c"height", t.height[0])
	gfx_control_field_int(sb, c"pixel_width", gfx_control_pixel_w(t))
	gfx_control_field_int(sb, c"pixel_height", gfx_control_pixel_h(t))
	if (ok == 0): gfx_control_field_string(sb, c"error", c"the window did not reach the requested size")
	gfx_control_send(s, sb)


# Run poll-phase operations until a swap-phase one heads the queue.
void gfx_control_run_poll(gfx_control_session* s, gfx_control_target* t):
	while (s.head != 0):
		gfx_control_op* op = s.head
		if (op.kind == GFX_CONTROL_OP_A11Y):
			if (gfx_control_a11y_request == 0): gfx_control_a11y_request = 1
			return
		if (op.kind >= GFX_CONTROL_OP_BARRIER): return
		if (op.kind == GFX_CONTROL_OP_HELLO):
			string_builder* sb = gfx_control_reply_begin(op.id, 1)
			gfx_control_field_int(sb, c"protocol", 1)
			gfx_control_field_string(sb, c"title", s.title)
			gfx_control_field_string(sb, c"backend", s.backend)
			gfx_control_field_int(sb, c"width", t.width[0])
			gfx_control_field_int(sb, c"height", t.height[0])
			gfx_control_field_int(sb, c"pixel_width", gfx_control_pixel_w(t))
			gfx_control_field_int(sb, c"pixel_height", gfx_control_pixel_h(t))
			gfx_control_field_int(sb, c"frame", s.frames)
			gfx_control_send(s, sb)
		else if (op.kind == GFX_CONTROL_OP_EVENT): gfx_control_run_event(t, op)
		else if (op.kind == GFX_CONTROL_OP_OK): gfx_control_reply_ok(s, op.id)
		else if (op.kind == GFX_CONTROL_OP_ERROR): gfx_control_reply_error(s, op.id, op.text)
		else if (op.kind == GFX_CONTROL_OP_SIZE): gfx_control_reply_size(s, t, op.id, op.e)
		else if (op.kind == GFX_CONTROL_OP_CLOSE):
			gfx_control_reply_ok(s, op.id)
			t.should_close[0] = 1
		else if (op.kind == GFX_CONTROL_OP_RESIZE):
			int w = op.a
			int h = op.b
			int id = op.id
			gfx_control_pop(s)
			if ((t.resize == 0) || (t.resize(t.window, w, h) == 0)):
				gfx_control_reply_error(s, id, c"resize is not supported by this backend")
				continue
			# Wait for the configure event, then report the size. Both go
			# to the front of the queue, ahead of later requests.
			gfx_control_op* wait = new gfx_control_op()
			wait.kind = GFX_CONTROL_OP_WAIT_SIZE
			wait.id = id
			wait.a = w
			wait.b = h
			wait.c = 0
			wait.text = cast(char*, 0)
			gfx_control_op* size = new gfx_control_op()
			size.kind = GFX_CONTROL_OP_SIZE
			size.id = id
			size.e = 1
			size.text = cast(char*, 0)
			wait.next = size
			size.next = s.head
			if (s.head == 0): s.tail = size
			s.head = wait
			continue
		gfx_control_pop(s)


void gfx_control_poll(gfx_control_target* t):
	gfx_control_session* s = gfx_control_current
	if (s == 0): return
	if ((s.fd >= 0) && (s.eof == 0)):
		char* buf = cast(char*, malloc(4096))
		int rounds = 0
		while ((rounds < 64) && gfx_control_transport_readable(s.fd)):
			int n = gfx_control_transport_recv(s.fd, buf, 4096)
			if (n <= 0):
				s.eof = 1
				break
			gfx_control_feed(s, buf, n, t.mouse_x[0], t.mouse_y[0])
			rounds = rounds + 1
		free(buf)
	gfx_control_run_poll(s, t)
	# The driver went away: close the window like its close button.
	if (s.eof): t.should_close[0] = 1


# The frame being presented, top row first, as w x h opaque RGBA.
char* gfx_control_read_frame(gfx_control_target* t, int w, int h):
	char* bottom_up = cast(char*, malloc(w * h * 4))
	t.readback(0, 0, w, h, bottom_up)
	char* rgba = cast(char*, malloc(w * h * 4))
	for y in range(h):
		char* src = &bottom_up[(h - 1 - y) * w * 4]
		char* dst = &rgba[y * w * 4]
		for i in range(w * 4): dst[i] = src[i]
		# The window's alpha channel is not part of what is on screen.
		for x in range(w): dst[x * 4 + 3] = 255
	free(bottom_up)
	return rgba


int gfx_control_write_file(char* path, char* data, int length):
	wstream* out = stream_open_write(path)
	if (out == 0): return 0
	stream_write(out, data, length)
	io_result r
	return stream_close_checked(out, &r) == IO_OK


void gfx_control_screenshot(gfx_control_session* s, gfx_control_target* t, gfx_control_op* op):
	if (t.readback == 0):
		gfx_control_reply_error(s, op.id, c"this backend cannot read frames back")
		return
	int w = gfx_control_pixel_w(t)
	int h = gfx_control_pixel_h(t)
	char* rgba = gfx_control_read_frame(t, w, h)
	string_builder* png = png_encode_rgba(w, h, rgba)
	free(rgba)
	int written = gfx_control_write_file(op.text, png.data, png.length)
	string_free(png)
	if (written == 0):
		gfx_control_reply_error(s, op.id, c"cannot write the screenshot file")
		return
	string_builder* sb = gfx_control_reply_begin(op.id, 1)
	gfx_control_field_string(sb, c"path", op.text)
	gfx_control_field_int(sb, c"width", w)
	gfx_control_field_int(sb, c"height", h)
	gfx_control_field_int(sb, c"frame", s.frames)
	gfx_control_send(s, sb)


void gfx_control_pixel(gfx_control_session* s, gfx_control_target* t, gfx_control_op* op):
	if (t.readback == 0):
		gfx_control_reply_error(s, op.id, c"this backend cannot read frames back")
		return
	int w = gfx_control_pixel_w(t)
	int h = gfx_control_pixel_h(t)
	int lw = t.width[0]
	int lh = t.height[0]
	if ((op.a < 0) || (op.b < 0) || (op.a >= lw) || (op.b >= lh)):
		gfx_control_reply_error(s, op.id, c"pixel is outside the window")
		return
	# Logical top-left coordinates to the bottom-up framebuffer.
	int px = op.a
	int py = op.b
	if (lw > 0): px = op.a * w / lw
	if (lh > 0): py = op.b * h / lh
	char* rgba = cast(char*, malloc(4))
	t.readback(px, h - 1 - py, 1, 1, rgba)
	string_builder* sb = gfx_control_reply_begin(op.id, 1)
	gfx_control_field_int(sb, c"x", op.a)
	gfx_control_field_int(sb, c"y", op.b)
	string_append(sb, c",\"rgba\":[")
	for i in range(3):
		string_append_int(sb, rgba[i] & 255)
		string_append_char(sb, ',')
	string_append(sb, c"255]")
	gfx_control_field_int(sb, c"frame", s.frames)
	free(rgba)
	gfx_control_send(s, sb)


void gfx_control_swap(gfx_control_target* t):
	gfx_control_session* s = gfx_control_current
	if (s == 0): return
	s.frames = s.frames + 1
	while (s.head != 0):
		gfx_control_op* op = s.head
		if (op.kind < GFX_CONTROL_OP_BARRIER): return
		if (op.kind == GFX_CONTROL_OP_SHOT): gfx_control_screenshot(s, t, op)
		else if (op.kind == GFX_CONTROL_OP_PIXEL): gfx_control_pixel(s, t, op)
		else if (op.kind == GFX_CONTROL_OP_BARRIER):
			gfx_control_pop(s)
			return
		else if (op.kind == GFX_CONTROL_OP_STEP):
			op.a = op.a - 1
			if (op.a > 0): return
			string_builder* sb = gfx_control_reply_begin(op.id, 1)
			gfx_control_field_int(sb, c"frame", s.frames)
			gfx_control_send(s, sb)
			gfx_control_pop(s)
			return
		else if (op.kind == GFX_CONTROL_OP_WAIT_SIZE):
			op.c = op.c + 1
			int reached = (t.width[0] == op.a) && (t.height[0] == op.b)
			if ((reached == 0) && (op.c < gfx_control_resize_frames)): return
			if ((reached == 0) && (op.next != 0)): op.next.e = 0
			gfx_control_pop(s)
			return
		else if (op.kind == GFX_CONTROL_OP_A11Y):
			if (gfx_control_a11y_reply != 0):
				string_builder* sb = gfx_control_reply_begin(op.id, 1)
				string_append(sb, c",\"tree\":")
				string_append(sb, gfx_control_a11y_reply)
				gfx_control_field_int(sb, c"frame", s.frames)
				gfx_control_send(s, sb)
				free(gfx_control_a11y_reply)
				gfx_control_a11y_reply = cast(char*, 0)
				gfx_control_a11y_request = 0
				gfx_control_pop(s)
				return
			op.c = op.c + 1
			if (op.c < gfx_control_a11y_frames): return
			gfx_control_a11y_request = 0
			gfx_control_reply_error(s, op.id, c"no accessibility tree: the program does not draw with graphics.ui")
			gfx_control_pop(s)
			return
		gfx_control_pop(s)
