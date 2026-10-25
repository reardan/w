# wbuild: x64
# Graphical layout edits for C4, swimlane, block, outline, kanban and
# agentflow diagrams, inspector typing groups and flowchart line removal.
# C4 and swimlane store `%% @w-position` / `%% @w-size` records applied
# after their own layouts; block cells, outline siblings and kanban cards
# move by reordering their source. Every edit round-trips (save -> reopen
# -> SVG export) and undoes back to the original bytes.
import lib.testing
import libs.extras.mermaid.canvas

int el_find(mm_editor* e, char* id):
	return mm_find_node(e.document, id)

# Save, reopen and export; the reopened scene must match the editor's.
void el_round_trip(mm_editor* e, char* name):
	string_builder* path = string_from(c"bin/mermaid_edit_layout_")
	string_append(path, name)
	string_append(path, c".mmd")
	unlink(path.data)
	assert_equal(1, mm_editor_save_as(e, path.data))
	mm_document* reopened = mm_read_selected(path.data, e.selected)
	asserts(c"reopens", reopened != 0 && reopened.error == 0)
	assert_strings_equal(e.document.source, reopened.source)
	assert_equal(e.document.nodes.length, reopened.nodes.length)
	mm_scene* scene = mm_render(reopened)
	asserts(c"renders", scene != 0)
	assert_equal(e.scene.nodes.length, scene.nodes.length)
	for i in range(scene.nodes.length):
		assert_equal(e.scene.nodes[i].x, scene.nodes[i].x)
		assert_equal(e.scene.nodes[i].y, scene.nodes[i].y)
		assert_equal(e.scene.nodes[i].w, scene.nodes[i].w)
		assert_equal(e.scene.nodes[i].h, scene.nodes[i].h)
	char* svg = mm_svg(scene)
	asserts(c"exports SVG", svg != 0 && index_of(svg, c"<svg") >= 0)
	free(svg)
	mm_scene_free(scene)
	mm_document_free(reopened)
	unlink(path.data)
	string_free(path)

void el_undo_all(mm_editor* e, char* source):
	while (e.position > 0): assert_equal(1, mm_editor_undo(e, 0))
	assert_strings_equal(source, e.document.source)

# 1 when the SVG has a rectangle at exactly (x, y).
int el_svg_rect_at(mm_scene* s, int x, int y):
	char* svg = mm_svg(s)
	string_builder* key = string_from(c"x=\"")
	string_append_int(key, x)
	string_append(key, c"\" y=\"")
	string_append_int(key, y)
	string_append(key, c"\"")
	int found = index_of(svg, key.data) >= 0
	string_free(key)
	free(svg)
	return found

void test_c4_positions_sizes_and_boundaries():
	char* source = c"C4Container\nPerson(user, \"User\")\nSystem_Boundary(editor, \"Desktop editor\") {\n  Container(parser, \"Parser\", \"W\")\n  ContainerDb(model, \"Model\", \"W structs\")\n}\nRel(user, parser, \"Edits source\")\n"
	mm_editor* e = mm_editor_new(c"bin/unused.mmd", source)
	asserts(c"parses", e.document.error == 0)
	int user = el_find(e, c"user")
	assert_equal(1, mm_editor_can_move(e, user))
	assert_equal(1, mm_editor_can_resize(e, user))
	assert_equal(1, mm_editor_move_node(e, user, 700, 420))
	asserts(c"position record", index_of(e.document.source, c"%% @w-position \"user\" 700 420\n") >= 0)
	assert_equal(700, e.scene.nodes[el_find(e, c"user")].x)
	assert_equal(420, e.scene.nodes[el_find(e, c"user")].y)
	asserts(c"card drawn at the saved position", el_svg_rect_at(e.scene, 700, 420))
	el_round_trip(e, c"c4_moved")
	assert_equal(1, mm_editor_resize_node(e, el_find(e, c"user"), 300, 150))
	asserts(c"size record", index_of(e.document.source, c"%% @w-size \"user\" 300 150\n") >= 0)
	assert_equal(300, e.scene.nodes[el_find(e, c"user")].w)
	el_round_trip(e, c"c4_resized")
	# A boundary carries its members; the relation follows the new bounds.
	int editor = el_find(e, c"editor")
	int parser = el_find(e, c"parser")
	int dx = e.scene.nodes[parser].x - e.scene.nodes[editor].x
	assert_equal(1, mm_editor_move_node(e, editor, 100, 600))
	assert_equal(100 + dx, e.scene.nodes[el_find(e, c"parser")].x)
	el_round_trip(e, c"c4_boundary")
	assert_equal(1, mm_editor_has_positions(e))
	assert_equal(1, mm_editor_reset_positions(e))
	assert_strings_equal(source, e.document.source)
	assert_equal(1, mm_editor_undo(e, 0))
	el_undo_all(e, source)
	mm_editor_free(e)

void test_swimlane_positions_and_lane_moves():
	char* source = c"swimlane-beta LR\nsubgraph Customer\n  request([Request])\nend\nsubgraph Engineering\n  work[Implement]\nend\nrequest --> work\n"
	mm_editor* e = mm_editor_new(c"bin/unused.mmd", source)
	asserts(c"parses", e.document.error == 0)
	int work = el_find(e, c"work")
	assert_equal(1, mm_editor_can_move(e, work))
	int lane = el_find(e, c"Engineering")
	int lane_w = e.scene.nodes[lane].w
	assert_equal(1, mm_editor_move_node(e, work, e.scene.nodes[work].x + 200, e.scene.nodes[work].y))
	asserts(c"position record", index_of(e.document.source, c"%% @w-position \"work\" ") >= 0)
	asserts(c"lane grows to keep its step", e.scene.nodes[el_find(e, c"Engineering")].w >= lane_w)
	el_round_trip(e, c"swimlane_step")
	lane = el_find(e, c"Customer")
	int request = el_find(e, c"request")
	int offset = e.scene.nodes[request].y - e.scene.nodes[lane].y
	assert_equal(1, mm_editor_move_node(e, lane, 60, 500))
	assert_equal(500 + offset, e.scene.nodes[el_find(e, c"request")].y)
	assert_equal(1, mm_editor_resize_node(e, el_find(e, c"work"), 260, 90))
	assert_equal(260, e.scene.nodes[el_find(e, c"work")].w)
	el_round_trip(e, c"swimlane_lane")
	el_undo_all(e, source)
	mm_editor_free(e)

void test_block_cells_reorder_and_span():
	char* source = c"block\ncolumns 3\na[\"A\"] b[\"B\"] c\nspace d[(\"D\")]\nblock:g\n  x y\nend\na --> d\n"
	mm_editor* e = mm_editor_new(c"bin/unused.mmd", source)
	asserts(c"parses", e.document.error == 0)
	int a = el_find(e, c"a")
	assert_equal(1, mm_editor_can_move(e, a))
	assert_equal(1, mm_editor_can_resize(e, a))
	assert_equal(0, mm_editor_can_move(e, el_find(e, c"@block:root")))
	assert_equal(1, mm_editor_slot_step(e, a, 1))
	asserts(c"cells swapped in their row", index_of(e.document.source, c"\nb[\"B\"] a[\"A\"] c\n") >= 0)
	asserts(c"cell moved right", e.scene.nodes[el_find(e, c"a")].x > e.scene.nodes[el_find(e, c"b")].x)
	el_round_trip(e, c"block_step")
	# Three cells later: across the row break (one undo step).
	int history = e.history.length
	assert_equal(1, mm_editor_slot_step(e, el_find(e, c"a"), 3))
	assert_equal(history + 1, e.history.length)
	asserts(c"moved into the next row", index_of(e.document.source, c"\nb[\"B\"] c space\nd[(\"D\")] a[\"A\"]\n") >= 0)
	el_round_trip(e, c"block_row")
	assert_equal(1, mm_editor_undo(e, 0))
	# A drop onto another cell takes that cell's place.
	assert_equal(1, mm_editor_slot_move(e, el_find(e, c"c"), el_find(e, c"b")))
	asserts(c"c before b", index_of(e.document.source, c"\nc b[\"B\"] a[\"A\"]\n") >= 0)
	assert_equal(1, mm_editor_undo(e, 0))
	# Composite blocks move as whole lines.
	assert_equal(1, mm_editor_slot_move(e, el_find(e, c"g"), el_find(e, c"d")))
	asserts(c"composite before d", index_of(e.document.source, c"block:g\n  x y\nend\n") < index_of(e.document.source, c"d[(\"D\")]"))
	el_round_trip(e, c"block_group")
	assert_equal(1, mm_editor_undo(e, 0))
	# Members never leave their composite by a move.
	assert_equal(0, mm_editor_slot_move(e, el_find(e, c"x"), el_find(e, c"a")))
	# A link-only mention is not a cell, but its declaration is.
	assert_equal(1, mm_editor_block_span(e, el_find(e, c"a"), 2))
	assert_equal(2, e.document.nodes[el_find(e, c"a")].value_x)
	asserts(c"span written", index_of(e.document.source, c"a[\"A\"]:2") >= 0)
	assert_equal(0, mm_editor_block_span(e, el_find(e, c"a"), 9))
	assert_equal(1, mm_editor_block_span(e, el_find(e, c"a"), 1))
	asserts(c"span 1 drops the suffix", index_of(e.document.source, c"a[\"A\"]:") < 0)
	el_round_trip(e, c"block_span")
	el_undo_all(e, source)
	mm_editor_free(e)

void test_block_canvas_drag_and_keys():
	char* source = c"block\ncolumns 3\na b c\n"
	mm_editor* e = mm_editor_new(c"bin/unused.mmd", source)
	mm_canvas c
	mm_canvas_init(&c)
	mm_bounds* a = e.scene.nodes[el_find(e, c"a")]
	mm_bounds* target = e.scene.nodes[el_find(e, c"c")]
	float32 px = cast(float32, a.x + a.w / 2)
	float32 py = cast(float32, a.y + a.h / 2)
	float32 tx = cast(float32, target.x + target.w / 2)
	int start_x = a.x
	assert_equal(0, mm_canvas_press(&c, e, px, py))
	assert_equal(el_find(e, c"a"), c.node)
	assert_equal(2, c.gesture)
	mm_canvas_motion(&c, e, px + 20.0, py)
	mm_canvas_motion(&c, e, tx, py)
	asserts(c"ghost follows the pointer", e.scene.nodes[el_find(e, c"a")].x > start_x)
	assert_strings_equal(source, e.document.source)
	assert_equal(1, mm_canvas_release(&c, e))
	assert_strings_equal(c"block\ncolumns 3\nb c a\n", e.document.source)
	mm_canvas_reset(&c, e)
	c.node = el_find(e, c"a")
	assert_equal(1, mm_canvas_nudge(&c, e, -1, 0))
	assert_strings_equal(c"block\ncolumns 3\nb a c\n", e.document.source)
	c.node = el_find(e, c"a")
	assert_equal(1, mm_canvas_grow(&c, e, 1, 0))
	assert_strings_equal(c"block\ncolumns 3\nb a:2 c\n", e.document.source)
	el_round_trip(e, c"block_canvas")
	el_undo_all(e, source)
	mm_editor_free(e)

void test_outline_slots_and_reparent():
	char* source = c"mindmap\n  root((Native diagrams))\n    Models\n      Bounded parsing\n    Rendering\n      SVG\n"
	mm_editor* e = mm_editor_new(c"bin/unused.mmd", source)
	assert_equal(0, mm_editor_can_move(e, 0))
	assert_equal(1, mm_editor_can_move(e, 1))
	assert_equal(0, mm_editor_can_resize(e, 1))
	assert_equal(1, mm_editor_slot_step(e, 1, 1))
	assert_strings_equal(c"mindmap\n  root((Native diagrams))\n    Rendering\n      SVG\n    Models\n      Bounded parsing\n", e.document.source)
	el_round_trip(e, c"mindmap_step")
	# SVG under Models: a branch moves under another node.
	assert_equal(1, mm_editor_slot_move(e, 2, 3))
	assert_strings_equal(c"mindmap\n  root((Native diagrams))\n    Rendering\n    Models\n      Bounded parsing\n      SVG\n", e.document.source)
	el_round_trip(e, c"mindmap_reparent")
	assert_equal(0, mm_editor_slot_move(e, 2, 3))
	el_undo_all(e, source)
	mm_editor_free(e)
	source = c"treeView-beta\nw/\n├── libs/\n│   └── parser.w\n└── README.md\n"
	e = mm_editor_new(c"bin/unused.mmd", source)
	assert_equal(1, mm_editor_slot_step(e, 3, -1))
	assert_strings_equal(c"README.md", e.document.nodes[1].label)
	el_round_trip(e, c"treeview_step")
	el_undo_all(e, source)
	mm_editor_free(e)

void test_kanban_cards_move_between_columns():
	char* source = c"kanban\n  todo[Todo]\n    docs[Write documentation]@{ priority: 'High' }\n    tests[Write tests]\n  progress[In progress]\n    renderer[Native rendering]\n  done[Done]\n"
	mm_editor* e = mm_editor_new(c"bin/unused.mmd", source)
	asserts(c"parses", e.document.error == 0)
	int docs = el_find(e, c"docs")
	assert_equal(1, mm_editor_can_move(e, docs))
	assert_equal(1, mm_editor_slot_column(e, docs, 1))
	assert_strings_equal(c"kanban\n  todo[Todo]\n    tests[Write tests]\n  progress[In progress]\n    renderer[Native rendering]\n    docs[Write documentation]@{ priority: 'High' }\n  done[Done]\n", e.document.source)
	assert_equal(el_find(e, c"progress"), e.document.nodes[el_find(e, c"docs")].parent)
	el_round_trip(e, c"kanban_column")
	# A drop on a card in another column lands before that card.
	assert_equal(1, mm_editor_slot_move(e, el_find(e, c"tests"), el_find(e, c"renderer")))
	assert_strings_equal(c"kanban\n  todo[Todo]\n  progress[In progress]\n    tests[Write tests]\n    renderer[Native rendering]\n    docs[Write documentation]@{ priority: 'High' }\n  done[Done]\n", e.document.source)
	# Onto an empty column.
	assert_equal(1, mm_editor_slot_move(e, el_find(e, c"renderer"), el_find(e, c"done")))
	asserts(c"card under Done", index_of(e.document.source, c"  done[Done]\n    renderer[Native rendering]\n") >= 0)
	assert_equal(1, mm_editor_slot_step(e, el_find(e, c"docs"), -1))
	asserts(c"reordered in its column", index_of(e.document.source, c"    docs[Write documentation]@{ priority: 'High' }\n    tests[Write tests]\n") >= 0)
	assert_equal(1, mm_editor_set_label(e, el_find(e, c"docs"), c"Write the docs"))
	assert_strings_equal(c"Write the docs", e.document.nodes[el_find(e, c"docs")].label)
	assert_equal(1, mm_outline_add(e, el_find(e, c"todo"), c"Triage", 0))
	asserts(c"card added to the column", index_of(e.document.source, c"  todo[Todo]\n    Triage\n") >= 0)
	assert_equal(1, mm_editor_delete_node(e, el_find(e, c"tests")))
	el_round_trip(e, c"kanban_edits")
	# Columns do not nest.
	assert_equal(0, mm_outline_reparent(e, el_find(e, c"todo"), el_find(e, c"done")))
	el_undo_all(e, source)
	mm_editor_free(e)

void test_agentflow_edits_like_a_flowchart():
	char* source = c"agentflow-beta TB\n  flow reviewer[\"Review Agent\"]\n    changes[\"Gather changes\"]\n    analyse[\"Analyse diff\"]\n    changes --> analyse\n  end\n  report[\"Report\"]\n  analyse --> report\n"
	mm_editor* e = mm_editor_new(c"bin/unused.mmd", source)
	asserts(c"parses", e.document.error == 0)
	assert_equal(1, mm_canvas_edit_family(e.document.kind))
	assert_equal(1, mm_editor_set_label(e, el_find(e, c"report"), c"Summary"))
	assert_strings_equal(c"Summary", e.document.nodes[el_find(e, c"report")].label)
	assert_equal(1, mm_editor_add_graph_node(e, c"notify", c"Notify"))
	assert_equal(1, mm_editor_connect(e, c"report", c"notify"))
	assert_equal(3, e.document.edges.length)
	assert_equal(1, mm_editor_edge_kind(e, 2, c"-.->"))
	assert_equal(1, e.document.edges[2].dashed)
	int reviewer = el_find(e, c"reviewer")
	assert_equal(1, mm_editor_move_node(e, reviewer, 400, 300))
	assert_equal(400, e.scene.nodes[el_find(e, c"reviewer")].x)
	assert_equal(1, mm_editor_add_node_in(e, c"lint", c"Lint", el_find(e, c"reviewer")))
	assert_equal(el_find(e, c"reviewer"), e.document.nodes[el_find(e, c"lint")].parent)
	el_round_trip(e, c"agentflow")
	assert_equal(1, mm_editor_delete_node(e, el_find(e, c"analyse")))
	assert_equal(-1, el_find(e, c"analyse"))
	el_round_trip(e, c"agentflow_deleted")
	el_undo_all(e, source)
	mm_editor_free(e)

void test_flowchart_subgraph_delete_removes_the_line():
	char* source = c"flowchart LR\nsubgraph G[Group]\n  A[Alpha]\n  B[Beta]\nend\nB --> C\n%% @w-position \"A\" 10 20\n"
	mm_editor* e = mm_editor_new(c"bin/unused.mmd", source)
	assert_equal(1, mm_editor_delete_node(e, el_find(e, c"A")))
	assert_strings_equal(c"flowchart LR\nsubgraph G[Group]\n  B[Beta]\nend\nB --> C\n", e.document.source)
	el_undo_all(e, source)
	mm_editor_free(e)

void test_inspector_typing_coalesces_into_one_step():
	char* source = c"classDiagram\nclass Order {\n  +int id\n  +total() float\n}\n"
	mm_editor* e = mm_editor_new(c"bin/unused.mmd", source)
	int order = el_find(e, c"Order")
	assert_equal(1, mm_editor_member_set(e, order, 0, c"+int ident"))
	assert_equal(0, mm_editor_coalesce(e))
	assert_equal(1, mm_editor_member_set(e, el_find(e, c"Order"), 0, c"+int identifier"))
	assert_equal(1, mm_editor_coalesce(e))
	assert_equal(1, e.position)
	asserts(c"edited in place", index_of(e.document.source, c"  +int identifier\n") >= 0)
	assert_equal(1, mm_editor_undo(e, 0))
	assert_strings_equal(source, e.document.source)
	assert_equal(1, mm_editor_undo(e, 1))
	# A saved state stays an undo stop.
	assert_equal(1, mm_editor_save_as(e, c"bin/mermaid_edit_layout_saved.mmd"))
	assert_equal(1, mm_editor_member_set(e, el_find(e, c"Order"), 1, c"+sum() float"))
	assert_equal(0, mm_editor_coalesce(e))
	unlink(c"bin/mermaid_edit_layout_saved.mmd")
	mm_editor_free(e)
