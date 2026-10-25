# wbuild: name=mermaid_canvas_access_test arch_only=x64
# The Mermaid canvas' semantic snapshot: roles, names, descriptions, bounds,
# selection and focus, plus assistive focus/select requests reaching the
# canvas selection. Display independent (headless renderer, no window).
import lib.testing
import graphics.mermaid_access
import graphics.ui.testing

const int MT_CANVAS = 900001

char* mt_source = c"---\ntitle: Orders\n---\nflowchart LR\nsubgraph S[Shop]\nA[Alpha]\nend\nA -->|pays| B[Beta]\nB -.-> C\n"

ui_access_node* mt_child(ui_access_node* parent, int index):
	ui_access_node* n = parent.first_child
	for i in range(index):
		if (n != 0): n = n.next_sibling
	return n

ui_access_tree* mt_snapshot(mm_canvas* c, mm_editor* e, int focused):
	ui_access_tree* tree = ui_access_tree_new(256, 65536)
	ui_access_add(tree, 1, 0, UI_ACCESS_DOCUMENT, ui_rect_new(0.0, 0.0, 800.0, 600.0))
	mm_access_canvas(tree, 1, MT_CANVAS, c, e, ui_rect_new(100.0, 50.0, 600.0, 400.0), focused)
	return tree

int mt_find_node(mm_editor* e, char* id):
	return mm_find_node(e.document, id)

void test_canvas_items_have_roles_names_and_descriptions():
	mm_editor* e = mm_editor_new(c"unused_access.mmd", mt_source)
	asserts(c"parsed", e.document.error == 0)
	mm_canvas c
	mm_canvas_init(&c)
	ui_access_tree* tree = mt_snapshot(&c, e, 0)
	ui_access_node* canvas = ui_access_find(tree, MT_CANVAS)
	asserts(c"canvas node", canvas != 0)
	assert_equal(UI_ACCESS_LIST, canvas.role)
	assert_strings_equal(c"Diagram canvas: Orders", canvas.name.data)
	asserts(c"summary counts", contains(canvas.description.data, c"flowchart, 3 nodes, 1 groups, 2 edges"))
	asserts(c"keyboard model", contains(canvas.description.data, c"Tab and Shift+Tab select"))
	asserts(c"canvas focusable", (canvas.states & UI_ACCESS_FOCUSABLE) != 0)
	int count = 0
	ui_access_node* n = canvas.first_child
	while (n != 0):
		count = count + 1
		n = n.next_sibling
	assert_equal(e.document.nodes.length + e.document.edges.length, count)
	int s = mt_find_node(e, c"S")
	int a = mt_find_node(e, c"A")
	ui_access_node* group = ui_access_find(tree, mm_access_node_id(MT_CANVAS, s))
	assert_equal(UI_ACCESS_GROUP, group.role)
	assert_strings_equal(c"Shop", group.name.data)
	assert_strings_equal(c"group S containing 1 items", group.description.data)
	assert_equal(0, group.actions & UI_ACCESS_ACTIVATE)
	ui_access_node* alpha = ui_access_find(tree, mm_access_node_id(MT_CANVAS, a))
	assert_equal(UI_ACCESS_LIST_ITEM, alpha.role)
	assert_strings_equal(c"Alpha", alpha.name.data)
	assert_strings_equal(c"node A in Shop, 1 outgoing, 0 incoming", alpha.description.data)
	ui_access_node* beta = ui_access_find(tree, mm_access_node_id(MT_CANVAS, mt_find_node(e, c"B")))
	assert_strings_equal(c"node B, 1 outgoing, 1 incoming, movable", beta.description.data)
	asserts(c"node selectable", (alpha.actions & UI_ACCESS_ACTIVATE) != 0)
	ui_access_node* pays = ui_access_find(tree, mm_access_edge_id(MT_CANVAS, 0))
	assert_equal(UI_ACCESS_LIST_ITEM, pays.role)
	assert_strings_equal(c"Alpha to Beta: pays", pays.name.data)
	assert_strings_equal(c"edge from Alpha to Beta, label pays", pays.description.data)
	ui_access_node* dashed = ui_access_find(tree, mm_access_edge_id(MT_CANVAS, 1))
	assert_strings_equal(c"Beta to C", dashed.name.data)
	assert_strings_equal(c"edge from Beta to C, dashed", dashed.description.data)
	assert_equal(0, tree.focused_id)
	ui_access_tree_free(tree)
	mm_editor_free(e)

void test_bounds_follow_zoom_pan_and_viewport():
	mm_editor* e = mm_editor_new(c"unused_access.mmd", mt_source)
	mm_canvas c
	mm_canvas_init(&c)
	c.zoom = 2.0
	c.pan_x = 10.0
	c.pan_y = -20.0
	ui_access_tree* tree = mt_snapshot(&c, e, 0)
	int a = mt_find_node(e, c"A")
	mm_bounds* b = e.scene.nodes[a]
	ui_access_node* alpha = ui_access_find(tree, mm_access_node_id(MT_CANVAS, a))
	asserts(c"x", alpha.bounds.x == 100.0 + 10.0 + cast(float32, b.x) * 2.0)
	asserts(c"y", alpha.bounds.y == 50.0 - 20.0 + cast(float32, b.y) * 2.0)
	asserts(c"w", alpha.bounds.w == cast(float32, b.w) * 2.0)
	asserts(c"h", alpha.bounds.h == cast(float32, b.h) * 2.0)
	ui_access_node* edge = ui_access_find(tree, mm_access_edge_id(MT_CANVAS, 0))
	asserts(c"edge spans endpoints", edge.bounds.w > 0.0)
	ui_access_tree_free(tree)
	mm_editor_free(e)

void test_selection_and_focus_states():
	mm_editor* e = mm_editor_new(c"unused_access.mmd", mt_source)
	mm_canvas c
	mm_canvas_init(&c)
	ui_access_tree* tree = mt_snapshot(&c, e, 1)
	assert_equal(MT_CANVAS, tree.focused_id)
	ui_access_tree_free(tree)
	mm_canvas_cycle(&c, e, 0)
	int first = c.node
	asserts(c"tab selected a node", first >= 0)
	tree = mt_snapshot(&c, e, 1)
	int id = mm_access_node_id(MT_CANVAS, first)
	assert_equal(id, tree.focused_id)
	asserts(c"selected state", (ui_access_find(tree, id).states & UI_ACCESS_SELECTED) != 0)
	ui_access_tree* again = mt_snapshot(&c, e, 1)
	assert_equal(1, ui_access_tree_same(tree, again))
	ui_access_tree_free(again)
	# Keyboard navigation changes the published focus, so bridges announce it.
	mm_canvas_cycle(&c, e, 0)
	again = mt_snapshot(&c, e, 1)
	assert_equal(0, ui_access_tree_same(tree, again))
	assert_equal(mm_access_node_id(MT_CANVAS, c.node), again.focused_id)
	asserts(c"old item deselected", (ui_access_find(again, id).states & UI_ACCESS_SELECTED) == 0)
	ui_access_tree_free(again)
	ui_access_tree_free(tree)
	c.node = -1
	c.edge = 1
	tree = mt_snapshot(&c, e, 0)
	assert_equal(0, tree.focused_id)
	asserts(c"edge selected", (ui_access_find(tree, mm_access_edge_id(MT_CANVAS, 1)).states & UI_ACCESS_SELECTED) != 0)
	ui_access_tree_free(tree)
	mm_editor_free(e)

void test_item_ids_round_trip():
	int index = -1
	assert_equal(MM_ACCESS_NODE, mm_access_item(MT_CANVAS, mm_access_node_id(MT_CANVAS, 7), &index))
	assert_equal(7, index)
	assert_equal(MM_ACCESS_EDGE, mm_access_item(MT_CANVAS, mm_access_edge_id(MT_CANVAS, 3), &index))
	assert_equal(3, index)
	assert_equal(MM_ACCESS_NONE, mm_access_item(MT_CANVAS, MT_CANVAS, &index))
	assert_equal(MM_ACCESS_NONE, mm_access_item(MT_CANVAS, 5, &index))

# A frame of the editor shape: widgets, then the canvas semantics.
void mt_frame(ui_context* ctx, ui_access_tree* tree, mm_canvas* c, mm_editor* e):
	ui_access_capture(ctx, tree)
	ui_begin(ctx, 800, 600)
	mm_access_apply(ctx, MT_CANVAS, c, e)
	ui_button(ctx, c"Save")
	ui_end(ctx)
	mm_access_canvas(tree, ui_access_root_id, MT_CANVAS, c, e, ui_rect_new(100.0, 50.0, 600.0, 400.0), ctx.focus == MT_CANVAS)
	ui_access_capture(ctx, 0)

void test_assistive_focus_and_select_requests_reach_the_canvas():
	ui_fixture fx
	ui_context* ctx = ui_fixture_init(&fx)
	mm_editor* e = mm_editor_new(c"unused_access.mmd", mt_source)
	mm_canvas c
	mm_canvas_init(&c)
	ui_access_tree* tree = ui_access_tree_new(256, 65536)
	mt_frame(ctx, tree, &c, e)
	int b = mt_find_node(e, c"B")
	int b_id = mm_access_node_id(MT_CANVAS, b)
	asserts(c"published item", ui_access_find(tree, b_id) != 0)
	# A screen reader moves focus to node B (AT-SPI GrabFocus, UIA SetFocus).
	assert_equal(1, ui_access_dispatch(tree, b_id, UI_ACCESS_FOCUS, 0, 0))
	ui_access_tree* next = ui_access_tree_new(256, 65536)
	mt_frame(ctx, next, &c, e)
	assert_equal(b, c.node)
	assert_equal(MT_CANVAS, ctx.focus)
	assert_equal(b_id, next.focused_id)
	ui_access_tree_free(tree)
	tree = next
	# Selecting an edge (AT-SPI SelectChild, UIA Select) queues an activation.
	int edge_id = mm_access_edge_id(MT_CANVAS, 1)
	assert_equal(1, ui_access_dispatch(tree, edge_id, UI_ACCESS_ACTIVATE, 0, 0))
	next = ui_access_tree_new(256, 65536)
	mt_frame(ctx, next, &c, e)
	assert_equal(-1, c.node)
	assert_equal(1, c.edge)
	assert_equal(edge_id, next.focused_id)
	ui_access_tree_free(tree)
	tree = next
	# Groups are readable but not selectable, as with Tab.
	int group_id = mm_access_node_id(MT_CANVAS, mt_find_node(e, c"S"))
	assert_equal(0, ui_access_dispatch(tree, group_id, UI_ACCESS_ACTIVATE, 0, 0))
	ui_access_tree_free(tree)
	mm_editor_free(e)
	ui_render_destroy(&fx.r)

void test_non_graph_family_exposes_the_canvas_only():
	mm_editor* e = mm_editor_new(c"unused_access.mmd", c"pie title Pets\n\"Dogs\" : 3\n\"Cats\" : 2\n")
	mm_canvas c
	mm_canvas_init(&c)
	ui_access_tree* tree = mt_snapshot(&c, e, 1)
	ui_access_node* canvas = ui_access_find(tree, MT_CANVAS)
	asserts(c"pie canvas", canvas != 0)
	asserts(c"pie family", contains(canvas.description.data, c"pie chart"))
	assert_equal(MT_CANVAS, tree.focused_id)
	ui_access_tree_free(tree)
	mm_editor_change(e, c"flowchart LR\nA[")
	tree = mt_snapshot(&c, e, 0)
	canvas = ui_access_find(tree, MT_CANVAS)
	asserts(c"error summary", contains(canvas.description.data, c"Syntax error"))
	assert_equal(0, cast(int, canvas.first_child))
	ui_access_tree_free(tree)
	mm_editor_free(e)
