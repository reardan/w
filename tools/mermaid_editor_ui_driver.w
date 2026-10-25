# wbuild: binary=mermaid_editor_ui_driver arch=x64 tag=tests
# Real X11/XTest editor workflows; run through the opt-in Xvfb target:
# the pointer/keyboard flowchart workflow, keyboard-only edit/undo/redo
# chains in each graphically editable family, group editing and
# multi-selection (Space, Ctrl+A, rubber band), C4 geometry, block cell
# (single and multi-selection) and kanban card moves, inspector line
# typing, and external-change detection with refused saves, Keep mine,
# reload and deletion.
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

void mu_redo(char* expected, char* message):
	mu_key(c"y", c"Control_L")
	mu_save()
	mu_wait(expected, 0, message)

# The bytes on disk right after a save, once they differ from before.
char* mu_saved_change(char* before, char* message):
	mu_save()
	mu_wait(before, 1, message)
	return ht_read(mu_path).data

# A save that must not write: the file keeps its bytes for a while.
void mu_refused_save(char* kept, char* message):
	mu_save()
	process_sleep_ms(500)
	ht_require(strcmp(ht_read(mu_path).data, kept) == 0, message)

# Start the editor on path and wait until its window is viewable.
process* mu_start(char* path):
	mu_path = path
	mu_window = 0
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
	return editor

void mu_quit(process* editor):
	mu_key(c"q", c"Control_L")
	ht_require(process_wait_or_kill(editor, 5000) == 0, c"editor did not close normally")
	mu_window = 0

# Canvas focus with nothing selected: Ctrl+D, then a click on empty canvas.
void mu_canvas():
	mu_key(c"d", c"Control_L")
	mu_click(1250.0, 700.0)

void mu_write_external(char* text):
	ht_write(mu_path, text, strlen(text))
	# The editor polls a few times a second.
	process_sleep_ms(700)

# Keyboard only, per graphically editable family: select with Tab, move with
# arrows, Tab then Shift+Tab back to the first node, delete it (deleted
# names it; it must vanish from the source), and walk an undo/redo chain whose every state is saved and
# compared byte for byte.
void mu_family(char* work, char* name, char* source, char* deleted):
	char* path = path_join(work, name)
	ht_write(path, source, strlen(source))
	process* editor = mu_start(path)
	mu_canvas()
	mu_key(c"Tab")
	mu_key(c"Right", c"Shift_L")
	char* moved = mu_saved_change(source, strjoin(name, c": keyboard move was not saved"))
	ht_require(contains(moved, c"@w-position"), strjoin(name, c": move did not store a position"))
	mu_key(c"Down")
	char* lowered = mu_saved_change(moved, strjoin(name, c": second move was not saved"))
	mu_key(c"Tab")
	mu_key(c"Tab", c"Shift_L")
	mu_key(c"Delete")
	char* removed = mu_saved_change(lowered, strjoin(name, c": Delete changed nothing"))
	ht_require(!contains(removed, deleted), strjoin(name, c": Delete kept the selected item"))
	mu_undo(lowered, strjoin(name, c": undo of the deletion"))
	mu_undo(moved, strjoin(name, c": undo of the second move"))
	mu_undo(source, strjoin(name, c": undo of the first move"))
	mu_redo(moved, strjoin(name, c": redo of the first move"))
	mu_redo(lowered, strjoin(name, c": redo of the second move"))
	mu_redo(removed, strjoin(name, c": redo of the deletion"))
	mu_undo(lowered, strjoin(name, c": undo after redo"))
	ht_checked(ht_argv(c"bin/wmermaid", c"check", mu_path))
	mu_quit(editor)

void mu_families(char* work):
	mu_family(work, c"er.mmd", c"erDiagram\nCUSTOMER ||--o{ ORDER : places\nORDER ||--|{ LINE : contains\n", c"CUSTOMER")
	mu_family(work, c"class.mmd", c"classDiagram\nclass Animal\nclass Dog\nclass Cat\nAnimal <|-- Dog\nAnimal <|-- Cat\n", c"Animal")
	mu_family(work, c"state.mmd", c"stateDiagram-v2\nIdle --> Running : start\nRunning --> Done : finish\n", c"Idle")

# Group editing from the keyboard: Tab selects the subgraph itself, arrows
# move it with its member, Ctrl+R renames it, Ctrl+G ungroups it (members
# stay), Delete removes it with its member, and every state undoes exactly.
void mu_groups(char* work):
	char* path = path_join(work, c"groups.mmd")
	char* source = c"flowchart LR\nsubgraph G[Group]\n  A[Alpha]\nend\nA --> B[Beta]\n"
	ht_write(path, source, strlen(source))
	process* editor = mu_start(path)
	mu_canvas()
	mu_key(c"Tab")
	mu_key(c"Right", c"Shift_L")
	char* moved = mu_saved_change(source, c"group: keyboard move was not saved")
	ht_require(contains(moved, c"@w-position \"G\""), c"group: move did not store the group's position")
	mu_key(c"r", c"Control_L")
	mu_key(c"a", c"Control_L")
	mu_type(c"Team")
	mu_key(c"Return", c"Control_L")
	char* renamed = mu_saved_change(moved, c"group: rename was not saved")
	ht_require(contains(renamed, c"subgraph G[Team]") && contains(renamed, c"A[Alpha]"), c"group: rename changed the wrong text")
	mu_key(c"d", c"Control_L")
	mu_key(c"g", c"Control_L")
	char* ungrouped = mu_saved_change(renamed, c"group: Ctrl+G changed nothing")
	ht_require(!contains(ungrouped, c"subgraph") && !contains(ungrouped, c"\nend\n") && contains(ungrouped, c"A[Alpha]"), c"group: ungroup lost or kept the wrong lines")
	mu_undo(renamed, c"group: undo of ungroup")
	mu_canvas()
	mu_key(c"Tab")
	mu_key(c"Delete")
	char* removed = mu_saved_change(renamed, c"group: Delete changed nothing")
	ht_require(!contains(removed, c"subgraph") && !contains(removed, c"Alpha") && contains(removed, c"B[Beta]"), c"group: Delete did not remove exactly the group and its member")
	mu_undo(renamed, c"group: undo of the deletion")
	mu_undo(moved, c"group: undo of the rename")
	mu_undo(source, c"group: undo of the move")
	ht_checked(ht_argv(c"bin/wmermaid", c"check", mu_path))
	mu_quit(editor)

# Multi-selection: Space extends a Tab selection, arrows move every selected
# node in one undo step, Delete removes them together, Ctrl+A selects all,
# and a Shift+drag rubber band selects what it covers.
void mu_multiselect(char* work):
	char* path = path_join(work, c"multi.mmd")
	char* source = c"flowchart LR\nA[Alpha] --> B[Beta]\nB --> C[Gamma]\n"
	ht_write(path, source, strlen(source))
	process* editor = mu_start(path)
	mu_canvas()
	mu_key(c"Tab")
	mu_key(c"space")
	mu_key(c"Tab")
	mu_key(c"space")
	mu_key(c"Right", c"Shift_L")
	char* moved = mu_saved_change(source, c"multi: set move was not saved")
	ht_require(contains(moved, c"@w-position \"A\"") && contains(moved, c"@w-position \"B\"") && !contains(moved, c"@w-position \"C\""), c"multi: arrows did not move exactly the selected nodes")
	mu_key(c"Delete")
	char* removed = mu_saved_change(moved, c"multi: Delete changed nothing")
	ht_require(!contains(removed, c"Alpha") && !contains(removed, c"Beta") && contains(removed, c"C[Gamma]"), c"multi: Delete did not remove exactly the selection")
	mu_undo(moved, c"multi: deleting the selection was not one undo step")
	mu_undo(source, c"multi: the set move was not one undo step")
	mu_canvas()
	mu_key(c"a", c"Control_L")
	mu_key(c"Down", c"Shift_L")
	char* all = mu_saved_change(source, c"multi: Ctrl+A move was not saved")
	ht_require(contains(all, c"@w-position \"A\"") && contains(all, c"@w-position \"B\"") && contains(all, c"@w-position \"C\""), c"multi: Ctrl+A did not select every node")
	mu_undo(source, c"multi: undo of the select-all move")
	mu_key(c"d", c"Control_L")
	mu_raw(c"Shift_L", 1)
	mu_flush()
	mu_move(1250.0, 700.0)
	mu_button(1)
	for step in range(1, 9): mu_move(1250.0 - 98.0 * cast(float, step), 700.0 - 70.0 * cast(float, step))
	mu_button(0)
	mu_raw(c"Shift_L", 0)
	mu_flush()
	mu_key(c"Left")
	char* banded = mu_saved_change(source, c"multi: rubber band move was not saved")
	ht_require(contains(banded, c"@w-position \"A\"") && contains(banded, c"@w-position \"B\"") && contains(banded, c"@w-position \"C\""), c"multi: rubber band did not select every node")
	mu_undo(source, c"multi: undo of the rubber band move")
	ht_checked(ht_argv(c"bin/wmermaid", c"check", mu_path))
	mu_quit(editor)

# Layout edits beyond the graph families: a C4 card moves and resizes as
# saved geometry, a block cell moves to the next cell and widens its column
# span, a kanban card moves to the next column; every step undoes exactly.
void mu_layouts(char* work):
	char* path = path_join(work, c"c4.mmd")
	char* source = c"C4Context\nPerson(user, \"User\")\nSystem(app, \"Editor\")\nRel(user, app, \"Uses\")\n"
	ht_write(path, source, strlen(source))
	process* editor = mu_start(path)
	mu_canvas()
	mu_key(c"Tab")
	mu_key(c"Right", c"Shift_L")
	char* moved = mu_saved_change(source, c"c4: keyboard move was not saved")
	ht_require(contains(moved, c"%% @w-position \"user\""), c"c4: move did not store a position")
	mu_key(c"Right", c"Alt_L")
	char* resized = mu_saved_change(moved, c"c4: Alt+Right resize was not saved")
	ht_require(contains(resized, c"%% @w-size \"user\""), c"c4: resize did not store a size")
	mu_undo(moved, c"c4: undo of the resize")
	mu_undo(source, c"c4: undo of the move")
	mu_redo(moved, c"c4: redo of the move")
	ht_checked(ht_argv(c"bin/wmermaid", c"check", mu_path))
	mu_quit(editor)
	path = path_join(work, c"block.mmd")
	source = c"block\ncolumns 3\na b c\n"
	ht_write(path, source, strlen(source))
	editor = mu_start(path)
	mu_canvas()
	mu_key(c"Tab")
	mu_key(c"Right")
	char* swapped = mu_saved_change(source, c"block: keyboard move was not saved")
	ht_require(contains(swapped, c"\nb a c\n") && !contains(swapped, c"@w-position"), c"block: move did not reorder the cells")
	mu_key(c"Right", c"Alt_L")
	char* wider = mu_saved_change(swapped, c"block: Alt+Right did not change the span")
	ht_require(contains(wider, c"\nb a:2 c\n"), c"block: span not written")
	mu_undo(swapped, c"block: undo of the span")
	mu_undo(source, c"block: undo of the move")
	ht_checked(ht_argv(c"bin/wmermaid", c"check", mu_path))
	mu_quit(editor)
	# Multi-selection reorder: Space extends a Tab selection of two cells,
	# Right moves both one cell as one undo step, Left brings them back.
	path = path_join(work, c"block_multi.mmd")
	source = c"block\ncolumns 4\na b c d\n"
	ht_write(path, source, strlen(source))
	editor = mu_start(path)
	mu_canvas()
	mu_key(c"Tab")
	mu_key(c"space")
	mu_key(c"Tab")
	mu_key(c"space")
	mu_key(c"Right")
	char* runs = mu_saved_change(source, c"block: multi-selection move was not saved")
	ht_require(contains(runs, c"\nc a b d\n"), c"block: the selected cells did not move together")
	mu_key(c"Right")
	char* further = mu_saved_change(runs, c"block: second multi-selection move was not saved")
	ht_require(contains(further, c"\nc d a b\n"), c"block: the selection did not follow the moved cells")
	mu_undo(runs, c"block: undo of the second multi-selection move")
	mu_undo(source, c"block: the multi-selection move was not one undo step")
	ht_checked(ht_argv(c"bin/wmermaid", c"check", mu_path))
	mu_quit(editor)
	path = path_join(work, c"kanban.mmd")
	source = c"kanban\n  todo[Todo]\n    docs[Write docs]\n  done[Done]\n"
	ht_write(path, source, strlen(source))
	editor = mu_start(path)
	mu_canvas()
	mu_key(c"Tab")
	mu_key(c"Tab")
	mu_key(c"Right")
	char* carded = mu_saved_change(source, c"kanban: Right did not move the card")
	ht_require(contains(carded, c"  done[Done]\n    docs[Write docs]\n"), c"kanban: card not in the next column")
	mu_undo(source, c"kanban: undo of the card move")
	mu_quit(editor)

# Inspector line field: Ctrl+P focuses a class member line, typing edits it
# in place, and the whole typing run is one undo step.
void mu_inspector(char* work):
	char* path = path_join(work, c"members.mmd")
	char* source = c"classDiagram\nclass Order {\n  +int id\n  +total() float\n}\n"
	ht_write(path, source, strlen(source))
	process* editor = mu_start(path)
	mu_canvas()
	mu_key(c"Tab")
	mu_key(c"p", c"Control_L")
	mu_key(c"End")
	mu_type(c"entifier")
	mu_save()
	mu_wait(c"  +int identifier\n", 2, c"inspector: member line was not edited in place")
	char* typed = ht_read(mu_path).data
	ht_require(contains(typed, c"  +total() float\n") && !contains(typed, c"+int id\n"), c"inspector: edit touched the wrong line")
	mu_undo(source, c"inspector: the typing run was not one undo step")
	mu_redo(typed, c"inspector: redo of the typing run")
	mu_key(c"d", c"Control_L")
	mu_key(c"p", c"Control_L")
	mu_key(c"p", c"Control_L")
	mu_key(c"BackSpace")
	mu_key(c"BackSpace")
	mu_key(c"BackSpace")
	mu_key(c"BackSpace")
	mu_key(c"BackSpace")
	mu_type(c"double")
	mu_save()
	mu_wait(c"  +total() double\n", 2, c"inspector: Ctrl+P did not step to the next line")
	mu_undo(typed, c"inspector: undo of the second line edit")
	ht_checked(ht_argv(c"bin/wmermaid", c"check", mu_path))
	mu_quit(editor)

# External changes: a save over a changed file is refused, Keep mine makes
# the next save replace exactly that version, Reload from disk adopts it,
# and a deleted file is only recreated after Keep mine.
void mu_conflicts(char* work):
	char* path = path_join(work, c"conflict.mmd")
	char* original = c"flowchart LR\nA[Alpha] --> B[Beta]\n"
	ht_write(path, original, strlen(original))
	process* editor = mu_start(path)
	mu_canvas()
	mu_key(c"Tab")
	mu_key(c"Right")
	char* external = c"%% external edit\nflowchart LR\nA[Alpha] --> B[Beta]\nB --> C\n"
	mu_write_external(external)
	mu_refused_save(external, c"save overwrote an external change")
	mu_refused_save(external, c"second save overwrote an external change")
	mu_key(c"k", c"Control_L")
	char* mine = mu_saved_change(external, c"Keep mine did not allow the save")
	ht_require(contains(mine, c"@w-position") && !contains(mine, c"external edit"), c"Keep mine did not save the editor's version")
	char* again = c"%% second external edit\nflowchart LR\nA[Alpha] --> B[Beta]\n"
	mu_write_external(again)
	mu_key(c"r", c"Control_L", c"Shift_L")
	mu_canvas()
	mu_key(c"Tab")
	mu_key(c"Right")
	char* merged = mu_saved_change(again, c"edit after reload was not saved")
	ht_require(contains(merged, c"second external edit") && contains(merged, c"@w-position"), c"reload did not adopt the disk version")
	unlink(mu_path)
	process_sleep_ms(700)
	mu_save()
	process_sleep_ms(500)
	ht_require(!path_exists(mu_path), c"save recreated a deleted file without asking")
	mu_key(c"k", c"Control_L")
	mu_save()
	mu_wait(merged, 0, c"Keep mine did not recreate the deleted file")
	mu_quit(editor)

void mu_flowchart(char* work):
	char* original = c"%% keep this comment\nflowchart LR\nA[Alpha] --> B[Beta]\n"
	char* path = path_join(work, c"diagram.mmd")
	ht_write(path, original, strlen(original))
	process* editor = mu_start(path)
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
	mu_wait(c"A[Renamed]", 2, c"inspector did not replace entire label")
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
	mu_quit(editor)
	char* screenshot = c"bin/mermaid-editor-workflow.ppm"
	ht_checked(ht_argv(c"bin/wmermaid_editor", mu_path, c"--frames", c"3", c"--screenshot", screenshot))
	ht_require(starts_with(ht_read(screenshot).data, c"P6\n"), c"missing editor screenshot")
	ht_equal_file(mu_path, renamed)

int main():
	mu_display = XOpenDisplay(0)
	ht_require(mu_display != 0, c"X11 unavailable; run with xvfb-run -a")
	mu_root = XDefaultRootWindow(mu_display)
	char* work = ht_temp()
	mu_flowchart(work)
	mu_families(work)
	mu_groups(work)
	mu_multiselect(work)
	mu_layouts(work)
	mu_inspector(work)
	mu_conflicts(work)
	XCloseDisplay(mu_display)
	ht_cleanup()
	println(c"Mermaid native editor workflow passed")
	return 0
