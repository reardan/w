# wbuild: x64
# Multi-selection moves in the source-order families (block, mindmap,
# treeView, kanban) and block composite column spans. Each set move is one
# validated transaction: one undo step, refused whole, the moved items in
# their relative order. Every edit round-trips (save -> reopen -> SVG
# export) and undoes back to the original bytes.
import lib.testing
import libs.extras.mermaid.canvas

int mt_find(mm_editor* e, char* id):
	return mm_find_node(e.document, id)

void mt_round_trip(mm_editor* e, char* name):
	string_builder* path = string_from(c"bin/mermaid_edit_multi_")
	string_append(path, name)
	string_append(path, c".mmd")
	unlink(path.data)
	assert_equal(1, mm_editor_save_as(e, path.data))
	mm_document* reopened = mm_read_selected(path.data, e.selected)
	asserts(c"reopens", reopened != 0 && reopened.error == 0)
	assert_strings_equal(e.document.source, reopened.source)
	mm_scene* scene = mm_render(reopened)
	asserts(c"renders", scene != 0)
	assert_equal(e.scene.nodes.length, scene.nodes.length)
	for i in range(scene.nodes.length):
		assert_equal(e.scene.nodes[i].x, scene.nodes[i].x)
		assert_equal(e.scene.nodes[i].y, scene.nodes[i].y)
		assert_equal(e.scene.nodes[i].w, scene.nodes[i].w)
	char* svg = mm_svg(scene)
	asserts(c"exports SVG", svg != 0 && index_of(svg, c"<svg") >= 0)
	free(svg)
	mm_scene_free(scene)
	mm_document_free(reopened)
	unlink(path.data)
	string_free(path)

void mt_undo_all(mm_editor* e, char* source):
	while (e.position > 0): assert_equal(1, mm_editor_undo(e, 0))
	assert_strings_equal(source, e.document.source)

list[int] mt_ids(mm_editor* e, char* first, char* second, char* third = 0):
	list[int] result = list[int]{mt_find(e, first), mt_find(e, second)}
	if (third != 0): result.push(mt_find(e, third))
	return result

void test_block_selection_moves_as_a_run():
	char* source = c"block\ncolumns 4\na[\"A\"] b c d\n"
	mm_editor* e = mm_editor_new(c"bin/unused.mmd", source)
	list[int] set = mt_ids(e, c"a", c"c")
	# Forward: the run lands after the target, a before c as in the source.
	assert_equal(1, mm_editor_slot_move_set(e, set, mt_find(e, c"a"), mt_find(e, c"d")))
	assert_strings_equal(c"block\ncolumns 4\nb d a[\"A\"] c\n", e.document.source)
	assert_equal(1, e.position)
	assert_equal(2, mm_slot_moved_set.length)
	assert_equal(mt_find(e, c"a"), mm_slot_moved_set[0])
	assert_equal(mt_find(e, c"c"), mm_slot_moved_set[1])
	assert_equal(mt_find(e, c"a"), mm_slot_moved)
	mt_round_trip(e, c"block_run")
	# Backward: before the target.
	__w_list_free(cast(__w_list*, set))
	set = mt_ids(e, c"a", c"c")
	assert_equal(1, mm_editor_slot_move_set(e, set, mt_find(e, c"c"), mt_find(e, c"b")))
	assert_strings_equal(c"block\ncolumns 4\na[\"A\"] c b d\n", e.document.source)
	assert_equal(2, e.position)
	# A selected target or a target inside the selection is refused.
	__w_list_free(cast(__w_list*, set))
	set = mt_ids(e, c"a", c"c")
	assert_equal(0, mm_editor_slot_move_set(e, set, mt_find(e, c"a"), mt_find(e, c"c")))
	# Arrow steps keep the gap; a step out of the row is refused whole.
	assert_equal(1, mm_editor_slot_step_set(e, set, 1))
	assert_strings_equal(c"block\ncolumns 4\nb a[\"A\"] c d\n", e.document.source)
	__w_list_free(cast(__w_list*, set))
	set = mt_ids(e, c"a", c"c")
	assert_equal(1, mm_editor_slot_step_set(e, set, 1))
	assert_strings_equal(c"block\ncolumns 4\nb d a[\"A\"] c\n", e.document.source)
	__w_list_free(cast(__w_list*, set))
	set = mt_ids(e, c"a", c"c")
	int position = e.position
	assert_equal(0, mm_editor_slot_step_set(e, set, 1))
	assert_equal(position, e.position)
	assert_strings_equal(c"block\ncolumns 4\nb d a[\"A\"] c\n", e.document.source)
	assert_equal(1, mm_editor_slot_step_set(e, set, -2))
	assert_strings_equal(c"block\ncolumns 4\na[\"A\"] c b d\n", e.document.source)
	mt_round_trip(e, c"block_steps")
	__w_list_free(cast(__w_list*, set))
	mt_undo_all(e, source)
	mm_editor_free(e)

void test_block_selection_with_composites_and_rows():
	char* source = c"block\ncolumns 3\na\nblock:g\n  x y\nend\nb c\nd\n"
	mm_editor* e = mm_editor_new(c"bin/unused.mmd", source)
	asserts(c"parses", e.document.error == 0)
	# A composite and a cell (its member rides along) move after d.
	list[int] set = mt_ids(e, c"a", c"g", c"x")
	assert_equal(1, mm_editor_slot_move_set(e, set, mt_find(e, c"g"), mt_find(e, c"d")))
	assert_equal(1, e.position)
	mm_document* d = e.document
	int order_b = mt_find(e, c"b")
	asserts(c"b first", order_b < mt_find(e, c"a") && mt_find(e, c"c") < mt_find(e, c"d") && mt_find(e, c"d") < mt_find(e, c"a") && mt_find(e, c"a") < mt_find(e, c"g"))
	assert_equal(mt_find(e, c"g"), d.nodes[mt_find(e, c"x")].parent)
	mt_round_trip(e, c"block_composite_run")
	# Cells of different composites never move together.
	__w_list_free(cast(__w_list*, set))
	set = mt_ids(e, c"x", c"b")
	assert_equal(0, mm_editor_slot_move_set(e, set, mt_find(e, c"b"), mt_find(e, c"c")))
	__w_list_free(cast(__w_list*, set))
	mt_undo_all(e, source)
	mm_editor_free(e)

void test_long_selection_move_is_one_undo_step():
	# Far more validated steps than the 32-entry history holds.
	string_builder* text = string_from(c"block\ncolumns 8\n")
	for i in range(24):
		string_append(text, c"n")
		string_append_int(text, i)
		string_append_char(text, 32)
	string_append_char(text, 10)
	char* source = text.data
	mm_editor* e = mm_editor_new(c"bin/unused.mmd", source)
	assert_equal(1, mm_editor_change(e, c"block\ncolumns 8\nn0 n1\n"))
	assert_equal(1, mm_editor_undo(e, 0))
	list[int] set = mt_ids(e, c"n0", c"n1", c"n2")
	assert_equal(1, mm_editor_slot_move_set(e, set, mt_find(e, c"n0"), mt_find(e, c"n23")))
	asserts(c"run at the end", index_of(e.document.source, c"n23 n0 n1 n2") >= 0)
	assert_equal(1, e.position)
	assert_equal(2, e.history.length)
	assert_equal(1, mm_editor_undo(e, 0))
	assert_strings_equal(source, e.document.source)
	# A single cell stepped across many rows is one step too.
	assert_equal(1, mm_editor_slot_step(e, mt_find(e, c"n0"), 23))
	assert_equal(1, e.position)
	assert_equal(1, mm_editor_undo(e, 0))
	assert_strings_equal(source, e.document.source)
	__w_list_free(cast(__w_list*, set))
	mm_editor_free(e)
	string_free(text)

void test_block_composite_span():
	char* source = c"block\ncolumns 3\nblock:g\n  x\nend\na\nblock:h:2 %% wide\n  z\nend\n"
	mm_editor* e = mm_editor_new(c"bin/unused.mmd", source)
	asserts(c"parses", e.document.error == 0)
	int g = mt_find(e, c"g")
	assert_equal(1, mm_editor_can_resize(e, g))
	assert_equal(1, mm_block_span_of(e.document, g))
	int width = e.scene.nodes[g].w
	assert_equal(1, mm_editor_block_span(e, g, 2))
	assert_equal(2, e.document.nodes[mt_find(e, c"g")].value_y)
	asserts(c"composite span written", index_of(e.document.source, c"\nblock:g:2\n  x\nend\n") >= 0)
	asserts(c"composite widened", e.scene.nodes[mt_find(e, c"g")].w > width)
	mt_round_trip(e, c"composite_span")
	# Wider than the parent's columns: refused, nothing changes.
	assert_equal(0, mm_editor_block_span(e, mt_find(e, c"g"), 4))
	assert_equal(1, e.position)
	# An existing span (before a trailing comment) is rewritten in place.
	assert_equal(1, mm_editor_block_span(e, mt_find(e, c"h"), 3))
	asserts(c"span rewritten", index_of(e.document.source, c"\nblock:h:3 %% wide\n") >= 0)
	assert_equal(1, mm_editor_block_span(e, mt_find(e, c"h"), 1))
	asserts(c"span 1 drops the suffix", index_of(e.document.source, c"\nblock:h %% wide\n") >= 0)
	mt_round_trip(e, c"composite_span_drop")
	# The canvas: Alt+Right and the resize gesture.
	mm_canvas c
	mm_canvas_init(&c)
	c.node = mt_find(e, c"g")
	assert_equal(1, mm_canvas_grow(&c, e, 1, 0))
	asserts(c"Alt+Right widened", index_of(e.document.source, c"\nblock:g:3\n") >= 0)
	assert_equal(1, mm_canvas_grow(&c, e, -1, 0))
	assert_equal(1, mm_canvas_grow(&c, e, -1, 0))
	asserts(c"back to one column", index_of(e.document.source, c"\nblock:g\n") >= 0)
	c.node = mt_find(e, c"g")
	mm_bounds* b = e.scene.nodes[c.node]
	float32 hx = cast(float32, b.x + b.w)
	float32 hy = cast(float32, b.y + b.h)
	assert_equal(0, mm_canvas_press(&c, e, hx, hy))
	assert_equal(4, c.gesture)
	mm_canvas_motion(&c, e, hx + 30.0, hy)
	mm_canvas_motion(&c, e, hx + cast(float32, b.w + 40), hy)
	assert_equal(1, mm_canvas_release(&c, e))
	asserts(c"dragged to two columns", index_of(e.document.source, c"\nblock:g:2\n") >= 0)
	mt_round_trip(e, c"composite_span_canvas")
	mt_undo_all(e, source)
	mm_editor_free(e)

void test_block_canvas_multi_drag():
	char* source = c"block\ncolumns 4\na b c d\n"
	mm_editor* e = mm_editor_new(c"bin/unused.mmd", source)
	mm_canvas c
	mm_canvas_init(&c)
	mm_bounds* a = e.scene.nodes[mt_find(e, c"a")]
	mm_bounds* bb = e.scene.nodes[mt_find(e, c"b")]
	mm_bounds* target = e.scene.nodes[mt_find(e, c"d")]
	float32 ax = cast(float32, a.x + a.w / 2)
	float32 ay = cast(float32, a.y + a.h / 2)
	assert_equal(0, mm_canvas_press(&c, e, ax, ay))
	assert_equal(1, mm_canvas_release(&c, e) == 0)
	assert_equal(0, mm_canvas_press_mods(&c, e, cast(float32, bb.x + bb.w / 2), ay, MM_CANVAS_EXTEND))
	mm_canvas_release(&c, e)
	assert_equal(2, mm_canvas_selection_count(&c, e))
	float32 tx = cast(float32, target.x + target.w / 2)
	assert_equal(0, mm_canvas_press(&c, e, ax, ay))
	assert_equal(2, c.gesture)
	mm_canvas_motion(&c, e, ax + 20.0, ay)
	mm_canvas_motion(&c, e, tx, ay)
	assert_strings_equal(source, e.document.source)
	assert_equal(1, mm_canvas_release(&c, e))
	assert_strings_equal(c"block\ncolumns 4\nc d a b\n", e.document.source)
	assert_equal(1, e.position)
	# The selection follows both cells; arrows move them together.
	assert_equal(2, mm_canvas_selection_count(&c, e))
	asserts(c"a still selected", mm_canvas_selected(&c, mt_find(e, c"a")) && mm_canvas_selected(&c, mt_find(e, c"b")))
	assert_equal(1, mm_canvas_nudge(&c, e, -1, 0))
	assert_strings_equal(c"block\ncolumns 4\nc a b d\n", e.document.source)
	assert_equal(0, mm_canvas_nudge(&c, e, 0, 1))
	mt_round_trip(e, c"block_canvas_multi")
	mt_undo_all(e, source)
	mm_editor_free(e)

void test_mindmap_selection_moves():
	char* source = c"mindmap\n  root((Plan))\n    A\n      A1\n    B\n    C\n      C1\n"
	mm_editor* e = mm_editor_new(c"bin/unused.mmd", source)
	asserts(c"parses", e.document.error == 0)
	# Siblings A and C dropped on B (which follows A): a run after B.
	list[int] set = list[int]{1, 4}
	assert_equal(1, mm_editor_slot_move_set(e, set, 1, 3))
	assert_strings_equal(c"mindmap\n  root((Plan))\n    B\n    A\n      A1\n    C\n      C1\n", e.document.source)
	assert_equal(1, e.position)
	mt_round_trip(e, c"mindmap_run")
	assert_equal(1, mm_editor_undo(e, 0))
	# Branches of different parents dropped on B become its last children.
	while (set.length > 0): set.pop()
	set.push(2)
	set.push(4)
	assert_equal(1, mm_editor_slot_move_set(e, set, 2, 3))
	assert_strings_equal(c"mindmap\n  root((Plan))\n    A\n    B\n        A1\n        C\n          C1\n", e.document.source)
	assert_equal(2, mm_slot_moved_set.length)
	assert_strings_equal(c"A1", e.document.nodes[mm_slot_moved_set[0]].label)
	assert_strings_equal(c"C", e.document.nodes[mm_slot_moved_set[1]].label)
	mt_round_trip(e, c"mindmap_gather")
	assert_equal(1, mm_editor_undo(e, 0))
	# A child of a selected branch rides along; a drop inside the selection is refused.
	while (set.length > 0): set.pop()
	set.push(1)
	set.push(2)
	assert_equal(1, mm_editor_slot_move_set(e, set, 2, 5))
	assert_strings_equal(c"mindmap\n  root((Plan))\n    B\n    C\n      C1\n          A\n            A1\n", e.document.source)
	assert_equal(1, mm_editor_undo(e, 0))
	assert_equal(0, mm_editor_slot_move_set(e, set, 1, 2))
	# The root never moves.
	set.push(0)
	assert_equal(0, mm_editor_slot_move_set(e, set, 1, 3))
	__w_list_free(cast(__w_list*, set))
	mt_undo_all(e, source)
	mm_editor_free(e)

void test_treeview_selection_moves():
	char* source = c"treeView-beta\nw/\n  libs/\n    parser.w\n  docs/\n  a.md\n  b.md\n"
	mm_editor* e = mm_editor_new(c"bin/unused.mmd", source)
	asserts(c"parses", e.document.error == 0)
	assert_strings_equal(c"a.md", e.document.nodes[4].label)
	# parser.w and b.md (different parents) dropped on docs/.
	list[int] set = list[int]{2, 5}
	assert_equal(1, mm_editor_slot_move_set(e, set, 2, 3))
	assert_strings_equal(c"treeView-beta\nw/\n  libs/\n  docs/\n      parser.w\n      b.md\n  a.md\n", e.document.source)
	assert_strings_equal(c"docs/", e.document.nodes[e.document.nodes[4].parent].label)
	assert_equal(1, e.position)
	mt_round_trip(e, c"treeview_gather")
	mt_undo_all(e, source)
	# Up with two siblings keeps their gap.
	while (set.length > 0): set.pop()
	set.push(3)
	set.push(5)
	assert_equal(1, mm_editor_slot_step_set(e, set, -1))
	assert_strings_equal(c"docs/", e.document.nodes[1].label)
	assert_strings_equal(c"b.md", e.document.nodes[4].label)
	mt_round_trip(e, c"treeview_steps")
	__w_list_free(cast(__w_list*, set))
	mt_undo_all(e, source)
	mm_editor_free(e)

void test_kanban_selection_moves():
	char* source = c"kanban\n  todo[Todo]\n    t1[One]@{ priority: 'High' }\n    t2[Two]\n    t3[Three]\n  doing[Doing]\n    p1[Busy]\n  done[Done]\n"
	mm_editor* e = mm_editor_new(c"bin/unused.mmd", source)
	asserts(c"parses", e.document.error == 0)
	# Cards dropped on a card of another column land before it, in order.
	list[int] set = mt_ids(e, c"t1", c"t3")
	assert_equal(1, mm_editor_slot_move_set(e, set, mt_find(e, c"t3"), mt_find(e, c"p1")))
	assert_strings_equal(c"kanban\n  todo[Todo]\n    t2[Two]\n  doing[Doing]\n    t1[One]@{ priority: 'High' }\n    t3[Three]\n    p1[Busy]\n  done[Done]\n", e.document.source)
	assert_equal(1, e.position)
	mt_round_trip(e, c"kanban_cards")
	# Onto a column: its last cards.
	__w_list_free(cast(__w_list*, set))
	set = mt_ids(e, c"p1", c"t1")
	assert_equal(1, mm_editor_slot_move_set(e, set, mt_find(e, c"p1"), mt_find(e, c"done")))
	asserts(c"cards in Done", index_of(e.document.source, c"  done[Done]\n    t1[One]@{ priority: 'High' }\n    p1[Busy]\n") >= 0)
	# Left/Right: cards of one column go to the neighbouring column.
	__w_list_free(cast(__w_list*, set))
	set = mt_ids(e, c"t1", c"p1")
	assert_equal(1, mm_editor_slot_column_set(e, set, -1))
	asserts(c"cards back in Doing", index_of(e.document.source, c"  doing[Doing]\n    t3[Three]\n    t1[One]@{ priority: 'High' }\n    p1[Busy]\n  done[Done]\n") >= 0)
	__w_list_free(cast(__w_list*, set))
	set = mt_ids(e, c"t1", c"p1")
	assert_equal(0, mm_editor_slot_column_set(e, set, 5))
	# Columns move as a run among the columns.
	__w_list_free(cast(__w_list*, set))
	set = mt_ids(e, c"todo", c"doing")
	assert_equal(1, mm_editor_slot_move_set(e, set, mt_find(e, c"todo"), mt_find(e, c"done")))
	assert_equal(0, mt_find(e, c"done"))
	asserts(c"todo before doing", mt_find(e, c"todo") < mt_find(e, c"doing"))
	mt_round_trip(e, c"kanban_columns")
	# A column and a card of another column cannot move together.
	__w_list_free(cast(__w_list*, set))
	set = mt_ids(e, c"todo", c"p1")
	assert_equal(0, mm_editor_slot_move_set(e, set, mt_find(e, c"p1"), mt_find(e, c"t3")))
	__w_list_free(cast(__w_list*, set))
	mt_undo_all(e, source)
	mm_editor_free(e)
