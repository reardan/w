# wbuild: binary=mermaid_editor_ui_driver arch=x64 tag=tests
# Real X11/XTest editor workflow; run through the opt-in Xvfb target.
import tools.host_tools
import lib.str
import lib.format
import graphics.x11
import libs.standard.formats.xml.etree

c_lib "libX11.so.6"
extern int XDefaultRootWindow(int display)
extern int XQueryTree(int display, int window, int* root, int* parent, int** children, int32* count)
extern int XFetchName(int display, int window, char** name)
extern int XGetWindowAttributes(int display, int window, char* attributes)
extern int XStringToKeysym(char* name)
extern int XKeysymToKeycode(int display, int symbol)
extern int XSetInputFocus(int display, int window, int revert, int timestamp)
extern int XTranslateCoordinates(int display, int source, int destination, int x, int y, int32* ox, int32* oy, int* child)
c_lib "libXtst.so.6"
extern int XTestFakeKeyEvent(int display, int code, int down, int delay)
extern int XTestFakeButtonEvent(int display, int button, int down, int delay)
extern int XTestFakeMotionEvent(int display, int screen, int x, int y, int delay)

int mu_display
int mu_root
int mu_window
char* mu_path

float mu_float(char* value):
	int consumed = 0
	float result = parse_float(value, &consumed)
	ht_require(consumed == strlen(value), c"invalid SVG number")
	return result

int mu_find(int parent):
	char* name = 0
	if (XFetchName(mu_display, parent, &name) && name != 0):
		int matches = strcmp(name, c"W Mermaid") == 0
		XFree(cast(int, name))
		if (matches): return parent
	int root = 0
	int ancestor = 0
	int* children = 0
	int32 count = 0
	if (!XQueryTree(mu_display, parent, &root, &ancestor, &children, &count)): return 0
	int result = 0
	for i in range(cast(int, count)):
		result = mu_find(children[i])
		if (result != 0): break
	if (children != 0): XFree(cast(int, children))
	return result

void mu_flush():
	XFlush(mu_display)
	process_sleep_ms(60)
void mu_raw(char* name, int down):
	int code = XKeysymToKeycode(mu_display, XStringToKeysym(name))
	ht_require(code != 0, strjoin(c"unavailable X11 key: ", name))
	XTestFakeKeyEvent(mu_display, code, down, 0)
void mu_key(char* name, char* first = 0, char* second = 0):
	if (first != 0): mu_raw(first, 1)
	if (second != 0): mu_raw(second, 1)
	mu_raw(name, 1)
	mu_raw(name, 0)
	if (second != 0): mu_raw(second, 0)
	if (first != 0): mu_raw(first, 0)
	mu_flush()
void mu_type(char* text):
	for i in range(strlen(text)):
		char[2] key
		key[0] = text[i]
		key[1] = 0
		char* name = &key[0]
		char* modifier = 0
		if (text[i] == ' '): name = c"space"
		if (text[i] == 10): name = c"Return"
		if (text[i] >= 'A' && text[i] <= 'Z'):
			key[0] = text[i] + 32
			modifier = c"Shift_L"
		mu_key(name, modifier)
void mu_move(float x, float y):
	int32 ox = 0
	int32 oy = 0
	int child = 0
	XTranslateCoordinates(mu_display, mu_window, mu_root, 0, 0, &ox, &oy, &child)
	XTestFakeMotionEvent(mu_display, -1, cast(int, ox) + cast(int, x), cast(int, oy) + cast(int, y), 0)
	mu_flush()
void mu_button(int down):
	XTestFakeButtonEvent(mu_display, 1, down, 0)
	mu_flush()
void mu_click(float x, float y):
	mu_move(x, y)
	mu_button(1)
	mu_button(0)
void mu_save(): mu_key(c"s", c"Control_L")
void mu_wait(char* expected, int mode, char* message):
	int deadline = process_monotonic_ms() + 5000
	while (process_monotonic_ms() < deadline):
		char* actual = ht_read(mu_path).data
		if (mode == 0 && strcmp(actual, expected) == 0): return
		if (mode == 1 && strcmp(actual, expected) != 0): return
		if (mode == 2 && contains(actual, expected)): return
		if (mode == 3 && !contains(actual, expected)): return
		if (mode == 4 && ht_split(replace(actual, c"-->", c"|"), '|').length == 3): return
		process_sleep_ms(40)
	ht_require(0, message)
void mu_undo(char* expected, char* message):
	mu_key(c"z", c"Control_L")
	mu_save()
	mu_wait(expected, 0, message)

int main():
	mu_display = XOpenDisplay(0)
	ht_require(mu_display != 0, c"X11 unavailable; run with xvfb-run -a")
	mu_root = XDefaultRootWindow(mu_display)
	char* work = ht_temp()
	mu_path = path_join(work, c"diagram.mmd")
	char* original = c"%% keep this comment\nflowchart LR\nA[Alpha] --> B[Beta]\n"
	ht_write(mu_path, original, strlen(original))
	spawn_options* options = spawn_options_new()
	options.new_group = 1
	process* editor = ht_spawn(ht_argv(c"bin/wmermaid_editor", mu_path), options)
	int deadline = process_monotonic_ms() + 5000
	while (mu_window == 0 && process_monotonic_ms() < deadline):
		mu_window = mu_find(mu_root)
		process_sleep_ms(40)
	ht_require(mu_window != 0, c"editor window did not appear")
	# XWindowAttributes is 136 bytes in the x86-64 Xlib ABI; map_state at 92.
	char[136] attributes
	deadline = process_monotonic_ms() + 5000
	while (1):
		if (XGetWindowAttributes(mu_display, mu_window, &attributes[0]) && load_int32(&attributes[92]) == 2): break
		ht_require(process_monotonic_ms() < deadline, c"window did not become viewable")
		process_sleep_ms(40)
	XSetInputFocus(mu_display, mu_window, 1, 0)
	mu_flush()
	process_sleep_ms(250)
	char* svg = path_join(work, c"initial.svg")
	ht_checked(ht_argv(c"bin/wmermaid", c"svg", mu_path, svg))
	xml_element* root = xml_fromstring(ht_read(svg).data)
	list[xml_element*] rects = xml_findall(root, c".//{http://www.w3.org/2000/svg}rect")
	ht_require(rects.length >= 2, c"missing SVG node geometry")
	list[char*] view = split(xml_get(root, c"viewBox"))
	float width = mu_float(view[2])
	float height = mu_float(view[3])
	float zoom = 1.0
	if (791.0 / width < zoom): zoom = 791.0 / width
	if (572.0 / height < zoom): zoom = 572.0 / height
	xml_element* rect = rects[0]
	float nx = 453.0 + (815.0 - width * zoom) / 2.0 + (mu_float(xml_get(rect, c"x")) + mu_float(xml_get(rect, c"width")) / 2.0) * zoom
	float ny = 134.0 + (596.0 - height * zoom) / 2.0 + (mu_float(xml_get(rect, c"y")) + mu_float(xml_get(rect, c"height")) / 2.0) * zoom
	mu_move(nx, ny)
	mu_button(1)
	mu_move(nx + 1.0, ny + 1.0)
	mu_button(0)
	mu_save()
	ht_equal_file(mu_path, original)
	mu_move(nx, ny)
	mu_button(1)
	for step in range(1, 6): mu_move(nx + 14.0 * cast(float, step), ny + 9.0 * cast(float, step))
	mu_button(0)
	mu_save()
	mu_wait(original, 1, c"mouse drag panned instead of moving node")
	ht_require(contains(ht_read(mu_path).data, c"@w-position"), c"drag did not store position")
	mu_undo(original, c"drag was not one undo step")
	mu_move(nx, ny)
	mu_button(1)
	mu_move(nx + 60.0, ny + 40.0)
	mu_key(c"Escape")
	mu_button(0)
	mu_save()
	ht_equal_file(mu_path, original)
	mu_click(65.0, 312.0)
	mu_click(1000.0, 550.0)
	mu_save()
	mu_wait(original, 1, c"Move here did not place node")
	ht_require(contains(ht_read(mu_path).data, c"@w-position"), c"placement did not store position")
	mu_undo(original, c"placement undo changed source")
	rect = rects[1]
	float bx = 453.0 + (815.0 - width * zoom) / 2.0 + (mu_float(xml_get(rect, c"x")) + mu_float(xml_get(rect, c"width")) / 2.0) * zoom
	float by = 134.0 + (596.0 - height * zoom) / 2.0 + (mu_float(xml_get(rect, c"y")) + mu_float(xml_get(rect, c"height")) / 2.0) * zoom
	mu_click(155.0, 312.0)
	mu_click(bx, by)
	mu_save()
	mu_wait(c"", 4, c"Link to did not create an edge")
	mu_undo(original, c"connection undo changed source")
	mu_key(c"d", c"Control_L")
	mu_click(1250.0, 700.0)
	mu_key(c"Tab")
	mu_key(c"Right")
	mu_save()
	mu_wait(original, 1, c"keyboard movement was not saved")
	char* moved = ht_read(mu_path).data
	ht_require(contains(moved, c"@w-position") && contains(moved, c"%% keep this comment"), c"movement lost source bytes")
	mu_undo(original, c"undo did not restore exact source")
	mu_key(c"z", c"Control_L", c"Shift_L")
	mu_save()
	mu_wait(moved, 0, c"redo did not restore moved node")
	mu_key(c"r", c"Control_L")
	mu_key(c"a", c"Control_L")
	mu_type(c"Renamed")
	mu_key(c"Return", c"Control_L")
	mu_save()
	mu_wait(c"[\"Renamed\"]", 2, c"inspector did not replace entire label")
	char* renamed = ht_read(mu_path).data
	ht_require(contains(renamed, c"%% keep this comment") && contains(renamed, c"Beta"), c"rename changed unrelated source")
	mu_key(c"r", c"Control_L")
	mu_key(c"a", c"Control_L")
	mu_key(c"Delete")
	mu_save()
	ht_equal_file(mu_path, renamed)
	mu_key(c"d", c"Control_L")
	mu_key(c"Delete")
	mu_save()
	mu_wait(c"Renamed", 3, c"Delete did not remove selected node")
	ht_require(contains(ht_read(mu_path).data, c"Beta"), c"Delete removed unrelated node")
	mu_undo(renamed, c"undo deletion lost document bytes")
	mu_key(c"e", c"Control_L")
	mu_key(c"Home", c"Control_L")
	mu_type(c"%% typed\n")
	mu_undo(renamed, c"contiguous source typing was not one undo step")
	ht_checked(ht_argv(c"bin/wmermaid", c"check", mu_path))
	mu_key(c"q", c"Control_L")
	ht_require(process_wait_or_kill(editor, 5000) == 0, c"editor did not close normally")
	char* screenshot = c"bin/mermaid-editor-workflow.ppm"
	ht_checked(ht_argv(c"bin/wmermaid_editor", mu_path, c"--frames", c"3", c"--screenshot", screenshot))
	ht_require(starts_with(ht_read(screenshot).data, c"P6\n"), c"missing editor screenshot")
	ht_equal_file(mu_path, renamed)
	XCloseDisplay(mu_display)
	ht_cleanup()
	println(c"Mermaid native editor workflow passed")
	return 0
