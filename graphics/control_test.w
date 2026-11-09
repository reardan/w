# Protocol unit test for graphics.control (docs/projects/wdrive.md):
# feeds request lines to a socketless session (responses collect in
# session.out), runs the poll and swap phases against a fake window
# target and checks the events that reach its input queue, the replies,
# frame accounting, a fake-readback screenshot round trip through PNG,
# and the a11y_tree hand-off through graphics.control_hooks. No display,
# GL or socket needed.
# wbuild: name=graphics_control_test x64
import lib.testing
import structures.string
import graphics.control
import graphics.image.png


struct fake_window:
	gfx_input_queue queue
	int32 width
	int32 height
	int32 should_close
	int32 mouse_x
	int32 mouse_y
	int32 mouse_buttons
	int resized_w
	int resized_h
	gfx_control_target target


int fake_resize(void* window, int w, int h):
	fake_window* f = cast(fake_window*, window)
	f.resized_w = w
	f.resized_h = h
	return 1


# A 4x2 framebuffer whose pixel (x, y from the bottom) is (x*10, y*100, 7).
void fake_readback(int x, int y, int w, int h, char* out):
	for j in range(h):
		for i in range(w):
			char* p = &out[(j * w + i) * 4]
			p[0] = (x + i) * 10
			p[1] = (y + j) * 100
			p[2] = 7
			p[3] = 0


fake_window* fake_new():
	fake_window* f = new fake_window()
	gfx_input_queue_init(&f.queue)
	f.width = 4
	f.height = 2
	gfx_control_target* t = &f.target
	t.window = cast(void*, f)
	t.queue = &f.queue
	t.width = &f.width
	t.height = &f.height
	t.should_close = &f.should_close
	t.mouse_x = &f.mouse_x
	t.mouse_y = &f.mouse_y
	t.mouse_buttons = &f.mouse_buttons
	t.resize = fake_resize
	t.readback = fake_readback
	return f


gfx_control_session* session_new():
	gfx_control_session* s = gfx_control_start(0 - 1, c"Fake", c"test")
	return s


void send_line(gfx_control_session* s, fake_window* f, char* line):
	gfx_control_feed(s, line, strlen(line), f.mouse_x, f.mouse_y)


# Responses so far, then cleared.
char* take_out(gfx_control_session* s):
	char* text = strclone(s.out.data)
	string_clear(s.out)
	return text


void frame(fake_window* f):
	gfx_input_queue_begin(&f.queue)
	gfx_control_poll(&f.target)


int next_kind(fake_window* f, gfx_event* e):
	if (gfx_input_queue_next(&f.queue, e) == 0): return 0 - 1
	return e.kind


void test_hello_reports_window():
	fake_window* f = fake_new()
	gfx_control_session* s = session_new()
	send_line(s, f, c"{\"id\":1,\"cmd\":\"hello\"}\n")
	frame(f)
	char* out = take_out(s)
	assert_strings_equal(c"{\"id\":1,\"ok\":true,\"protocol\":1,\"title\":\"Fake\",\"backend\":\"test\",\"width\":4,\"height\":2,\"pixel_width\":4,\"pixel_height\":2,\"frame\":0}\n", out)
	gfx_control_end()


void test_partial_lines_and_errors():
	fake_window* f = fake_new()
	gfx_control_session* s = session_new()
	send_line(s, f, c"{\"id\":2,\"cmd\":\"he")
	frame(f)
	assert_strings_equal(c"", take_out(s))
	send_line(s, f, c"llo\"}\n\n{\"id\":3,\"cmd\":\"bogus\"}\nnot json\n{\"id\":4}\n")
	frame(f)
	char* out = take_out(s)
	assert_contains(out, c"{\"id\":2,\"ok\":true,")
	assert_contains(out, c"{\"id\":3,\"ok\":false,\"error\":\"unknown cmd: bogus\"}\n")
	assert_contains(out, c"{\"id\":0,\"ok\":false,\"error\":\"request is not a JSON object\"}\n")
	assert_contains(out, c"{\"id\":4,\"ok\":false,\"error\":\"request has no cmd\"}\n")
	gfx_control_end()


void test_click_spans_frames():
	fake_window* f = fake_new()
	gfx_control_session* s = session_new()
	send_line(s, f, c"{\"id\":5,\"cmd\":\"click\",\"x\":3,\"y\":1,\"count\":2}\n")
	gfx_event e
	frame(f)
	assert_equal(3, f.mouse_x)
	assert_equal(1, f.mouse_y)
	assert_equal(1, f.mouse_buttons)
	assert_equal(GFX_EVENT_MOUSE_DOWN, next_kind(f, &e))
	assert_equal(1, e.code)
	assert_equal(1, gfx_event_clicks(e.mods))
	assert_equal(0 - 1, next_kind(f, &e))
	# Nothing more until the frame is presented.
	frame(f)
	assert_equal(0 - 1, next_kind(f, &e))
	gfx_control_swap(&f.target)
	frame(f)
	assert_equal(GFX_EVENT_MOUSE_UP, next_kind(f, &e))
	assert_equal(0, f.mouse_buttons)
	gfx_control_swap(&f.target)
	frame(f)
	assert_equal(GFX_EVENT_MOUSE_DOWN, next_kind(f, &e))
	assert_equal(2, gfx_event_clicks(e.mods))
	gfx_control_swap(&f.target)
	frame(f)
	assert_equal(GFX_EVENT_MOUSE_UP, next_kind(f, &e))
	assert_strings_equal(c"", take_out(s))
	gfx_control_swap(&f.target)
	frame(f)
	assert_strings_equal(c"{\"id\":5,\"ok\":true}\n", take_out(s))
	gfx_control_end()


void test_keys_and_text():
	fake_window* f = fake_new()
	gfx_control_session* s = session_new()
	send_line(s, f, c"{\"id\":6,\"cmd\":\"key\",\"name\":\"Ctrl+S\"}\n{\"id\":7,\"cmd\":\"key\",\"name\":\"left\",\"mods\":[\"shift\"]}\n{\"id\":8,\"cmd\":\"text\",\"text\":\"hé\\n\"}\n{\"id\":9,\"cmd\":\"key\",\"name\":\"a\",\"mods\":\"shift\",\"keycode\":38}\n{\"id\":10,\"cmd\":\"key\",\"name\":\"Hyper+x\"}\n")
	gfx_event e
	frame(f)
	assert_equal(GFX_EVENT_CHAR, next_kind(f, &e))
	assert_equal(19, e.code)
	assert_equal(GFX_MOD_CTRL, e.mods)
	gfx_control_swap(&f.target)
	frame(f)
	assert_equal(GFX_EVENT_NAV, next_kind(f, &e))
	assert_equal(GFX_NAV_LEFT, e.code)
	assert_equal(GFX_MOD_SHIFT, e.mods)
	gfx_control_swap(&f.target)
	frame(f)
	assert_equal(GFX_EVENT_CHAR, next_kind(f, &e))
	assert_equal('h', e.code)
	assert_equal(GFX_EVENT_CHAR, next_kind(f, &e))
	assert_equal(233, e.code)
	assert_equal(GFX_EVENT_CHAR, next_kind(f, &e))
	assert_equal(13, e.code)
	gfx_control_swap(&f.target)
	frame(f)
	assert_equal(GFX_EVENT_KEY_DOWN, next_kind(f, &e))
	assert_equal(38, e.code)
	assert_equal(GFX_EVENT_CHAR, next_kind(f, &e))
	assert_equal('A', e.code)
	assert_equal(GFX_EVENT_KEY_UP, next_kind(f, &e))
	gfx_control_swap(&f.target)
	frame(f)
	char* out = take_out(s)
	assert_contains(out, c"{\"id\":6,\"ok\":true}\n{\"id\":7,\"ok\":true}\n{\"id\":8,\"ok\":true}\n{\"id\":9,\"ok\":true}\n")
	assert_contains(out, c"{\"id\":10,\"ok\":false,\"error\":\"unknown modifier in key name\"}\n")
	gfx_control_end()


void test_wheel_and_move():
	fake_window* f = fake_new()
	gfx_control_session* s = session_new()
	send_line(s, f, c"{\"id\":11,\"cmd\":\"wheel\",\"notches\":-2,\"x\":2,\"y\":1}\n{\"id\":12,\"cmd\":\"move\",\"x\":1,\"y\":0}\n")
	gfx_event e
	frame(f)
	assert_equal(GFX_EVENT_SCROLL, next_kind(f, &e))
	assert_equal(0 - 1, e.code)
	assert_equal(2, e.x)
	assert_equal(GFX_EVENT_SCROLL, next_kind(f, &e))
	assert_equal(0 - 1, next_kind(f, &e))
	gfx_control_swap(&f.target)
	frame(f)
	assert_equal(1, f.mouse_x)
	assert_equal(0, f.mouse_y)
	# move queues no event, as X11 motion does not.
	assert_equal(0 - 1, next_kind(f, &e))
	gfx_control_swap(&f.target)
	frame(f)
	assert_strings_equal(c"{\"id\":11,\"ok\":true}\n{\"id\":12,\"ok\":true}\n", take_out(s))
	gfx_control_end()


void test_step_counts_swaps():
	fake_window* f = fake_new()
	gfx_control_session* s = session_new()
	send_line(s, f, c"{\"id\":13,\"cmd\":\"step\",\"frames\":3}\n{\"id\":14,\"cmd\":\"hello\"}\n")
	frame(f)
	gfx_control_swap(&f.target)
	frame(f)
	gfx_control_swap(&f.target)
	frame(f)
	assert_strings_equal(c"", take_out(s))
	gfx_control_swap(&f.target)
	assert_strings_equal(c"{\"id\":13,\"ok\":true,\"frame\":3}\n", take_out(s))
	frame(f)
	assert_contains(take_out(s), c"\"frame\":3}\n")
	gfx_control_end()


void test_pixel_and_screenshot():
	fake_window* f = fake_new()
	gfx_control_session* s = session_new()
	send_line(s, f, c"{\"id\":15,\"cmd\":\"pixel\",\"x\":2,\"y\":0}\n{\"id\":16,\"cmd\":\"screenshot\",\"path\":\"bin/graphics_control_test.png\"}\n{\"id\":17,\"cmd\":\"pixel\",\"x\":9,\"y\":0}\n")
	frame(f)
	assert_strings_equal(c"", take_out(s))
	gfx_control_swap(&f.target)
	char* out = take_out(s)
	# Top row (y 0) is the framebuffer's bottom-up row 1.
	assert_contains(out, c"{\"id\":15,\"ok\":true,\"x\":2,\"y\":0,\"rgba\":[20,100,7,255],\"frame\":1}\n")
	assert_contains(out, c"{\"id\":16,\"ok\":true,\"path\":\"bin/graphics_control_test.png\",\"width\":4,\"height\":2,\"frame\":1}\n")
	assert_contains(out, c"{\"id\":17,\"ok\":false,\"error\":\"pixel is outside the window\"}\n")
	int fd = open(c"bin/graphics_control_test.png", 0, 0)
	assert1(fd >= 0)
	string_builder* bytes = string_new()
	char* buf = cast(char*, malloc(4096))
	int n = read(fd, buf, 4096)
	while (n > 0):
		string_append_bytes(bytes, buf, n)
		n = read(fd, buf, 4096)
	close(fd)
	wresult[rgba_image*]* result = png_decode_n(bytes.data, bytes.length, 0)
	assert_equal(1, result.ok)
	rgba_image* image = result.value
	assert_equal(4, image.width)
	assert_equal(2, image.height)
	# Row 0 of the PNG is the top: framebuffer row 1, green 100, opaque.
	assert_equal(30, image.pixels[12] & 255)
	assert_equal(100, image.pixels[13] & 255)
	assert_equal(255, image.pixels[15] & 255)
	assert_equal(0, image.pixels[4 * 4 + 1] & 255)
	gfx_control_end()


void test_resize_waits_for_configure():
	fake_window* f = fake_new()
	gfx_control_session* s = session_new()
	send_line(s, f, c"{\"id\":18,\"cmd\":\"resize\",\"w\":8,\"h\":6}\n{\"id\":19,\"cmd\":\"resize\",\"w\":0,\"h\":6}\n")
	frame(f)
	assert_equal(8, f.resized_w)
	assert_equal(6, f.resized_h)
	gfx_control_swap(&f.target)
	frame(f)
	assert_strings_equal(c"", take_out(s))
	f.width = 8
	f.height = 6
	gfx_control_swap(&f.target)
	frame(f)
	char* out = take_out(s)
	assert_contains(out, c"{\"id\":18,\"ok\":true,\"width\":8,\"height\":6,\"pixel_width\":8,\"pixel_height\":6}\n")
	assert_contains(out, c"{\"id\":19,\"ok\":false,")
	gfx_control_end()


void test_a11y_tree_handoff():
	fake_window* f = fake_new()
	gfx_control_session* s = session_new()
	send_line(s, f, c"{\"id\":20,\"cmd\":\"a11y_tree\"}\n")
	frame(f)
	assert_equal(1, gfx_control_a11y_request)
	# What graphics.ui's ui_end leaves behind.
	gfx_control_a11y_reply = strclone(c"{\"role\":\"document\"}")
	gfx_control_swap(&f.target)
	assert_strings_equal(c"{\"id\":20,\"ok\":true,\"tree\":{\"role\":\"document\"},\"frame\":1}\n", take_out(s))
	assert_equal(0, gfx_control_a11y_request)
	# Without a ui frame the request gives up after a few frames.
	send_line(s, f, c"{\"id\":21,\"cmd\":\"a11y_tree\"}\n")
	for i in range(3):
		frame(f)
		gfx_control_swap(&f.target)
	assert_contains(take_out(s), c"{\"id\":21,\"ok\":false,\"error\":\"no accessibility tree")
	assert_equal(0, gfx_control_a11y_request)
	gfx_control_end()


void test_close_sets_should_close():
	fake_window* f = fake_new()
	gfx_control_session* s = session_new()
	send_line(s, f, c"{\"id\":22,\"cmd\":\"close\"}\n")
	frame(f)
	assert_equal(1, f.should_close)
	assert_strings_equal(c"{\"id\":22,\"ok\":true}\n", take_out(s))
	gfx_control_end()


void test_inactive_without_env():
	# No W_GFX_CONTROL in the test environment: open reports inactive and
	# the hooks are no-ops.
	assert_equal(0, gfx_control_open(c"x", c"test"))
	assert_equal(0, gfx_control_active())
	fake_window* f = fake_new()
	frame(f)
	gfx_control_swap(&f.target)
	gfx_event e
	assert_equal(0 - 1, next_kind(f, &e))
