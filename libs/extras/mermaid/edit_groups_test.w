# wbuild: x64
# Graphical editing inside groups: flowchart subgraphs, class namespaces,
# composite states, use-case boundaries, swimlane lanes, C4 boundaries and
# architecture groups. Every edit is one undo step that restores the bytes.
import lib.testing
import libs.extras.mermaid.edit_commands

int eg_find(mm_editor* e, char* id):
	return mm_find_node(e.document, id)

int eg_parent(mm_editor* e, char* id):
	return e.document.nodes[eg_find(e, id)].parent

void eg_restores(mm_editor* e, char* source):
	assert_equal(1, mm_editor_undo(e, 0))
	assert_strings_equal(source, e.document.source)

char* eg_flow():
	return c"flowchart LR\n%% keep\nsubgraph G[Group one]\nA[Alpha] --> B[Beta]\nend\nC[Gamma]\nB --> C\n"

void test_flow_subgraph_select_rename_and_move_carries_members():
	char* source = eg_flow()
	mm_editor* e = mm_editor_new(c"unused.mmd", source)
	int g = eg_find(e, c"G")
	mm_bounds* box = e.scene.nodes[g]
	assert_equal(g, mm_editor_hit(e, box.x + 4, box.y + 4))
	int a = eg_find(e, c"A")
	mm_bounds* alpha = e.scene.nodes[a]
	assert_equal(a, mm_editor_hit(e, alpha.x + alpha.w / 2, alpha.y + alpha.h / 2))
	assert_equal(1, mm_editor_set_label(e, g, c"Renamed group"))
	asserts(c"group title edited in place", index_of(e.document.source, c"subgraph G[Renamed group]\n") >= 0)
	assert_strings_equal(c"Renamed group", e.document.nodes[eg_find(e, c"G")].label)
	eg_restores(e, source)
	g = eg_find(e, c"G")
	a = eg_find(e, c"A")
	int dx = e.scene.nodes[a].x - e.scene.nodes[g].x
	int dy = e.scene.nodes[a].y - e.scene.nodes[g].y
	assert_equal(1, mm_editor_move_node(e, g, 400, 300))
	g = eg_find(e, c"G")
	a = eg_find(e, c"A")
	assert_equal(400, e.scene.nodes[g].x)
	assert_equal(400 + dx, e.scene.nodes[a].x)
	assert_equal(300 + dy, e.scene.nodes[a].y)
	assert_equal(1, e.position)
	# A positioned member follows a later group move by the same offset.
	assert_equal(1, mm_editor_move_node(e, a, 420 + dx, 300 + dy))
	assert_equal(1, mm_editor_move_node(e, eg_find(e, c"G"), 500, 300))
	a = eg_find(e, c"A")
	assert_equal(520 + dx, e.scene.nodes[a].x)
	asserts(c"member record shifted", index_of(e.document.source, c"%% @w-position \"A\" ") >= 0)
	assert_equal(3, e.position)
	for i in range(3): assert_equal(1, mm_editor_undo(e, 0))
	assert_strings_equal(source, e.document.source)
	mm_editor_free(e)

void test_flow_nested_connect_delete_and_add_inside_group():
	char* source = eg_flow()
	mm_editor* e = mm_editor_new(c"unused.mmd", source)
	assert_equal(1, mm_editor_connect(e, c"A", c"C"))
	assert_equal(3, e.document.edges.length)
	eg_restores(e, source)
	assert_equal(1, mm_editor_delete_node(e, eg_find(e, c"A")))
	assert_equal(-1, eg_find(e, c"A"))
	assert_equal(eg_find(e, c"G"), eg_parent(e, c"B"))
	eg_restores(e, source)
	assert_equal(1, mm_editor_add_node_in(e, c"D", c"Delta", eg_find(e, c"G")))
	assert_equal(eg_find(e, c"G"), eg_parent(e, c"D"))
	assert_strings_equal(c"Delta", e.document.nodes[eg_find(e, c"D")].label)
	asserts(c"inserted before end", index_of(e.document.source, c"D[\"Delta\"]\nend\n") >= 0)
	eg_restores(e, source)
	mm_editor_free(e)

void test_flow_reparent_ungroup_and_delete_group():
	char* source = eg_flow()
	mm_editor* e = mm_editor_new(c"unused.mmd", source)
	# Into a group: a declaration in the group's body.
	assert_equal(1, mm_editor_reparent(e, eg_find(e, c"C"), eg_find(e, c"G")))
	assert_equal(eg_find(e, c"G"), eg_parent(e, c"C"))
	assert_strings_equal(c"Gamma", e.document.nodes[eg_find(e, c"C")].label)
	eg_restores(e, source)
	# A is declared by an edge inside the group: moving it out is refused.
	assert_equal(0, mm_editor_reparent(e, eg_find(e, c"A"), -1))
	assert_strings_equal(source, e.document.source)
	assert_equal(0, e.position)
	assert_equal(1, mm_editor_ungroup(e, eg_find(e, c"G")))
	assert_equal(-1, eg_find(e, c"G"))
	assert_equal(-1, eg_parent(e, c"A"))
	assert_strings_equal(c"flowchart LR\n%% keep\nA[Alpha] --> B[Beta]\nC[Gamma]\nB --> C\n", e.document.source)
	eg_restores(e, source)
	assert_equal(1, mm_editor_delete_node(e, eg_find(e, c"G")))
	assert_strings_equal(c"flowchart LR\n%% keep\nC[Gamma]\n", e.document.source)
	eg_restores(e, source)
	mm_editor_free(e)
	# A declaration alone inside the group moves out with its label.
	source = c"flowchart LR\nsubgraph G\nA[Alpha]\nB\nend\nA --> B\n"
	e = mm_editor_new(c"unused.mmd", source)
	assert_equal(1, mm_editor_reparent(e, eg_find(e, c"A"), -1))
	assert_equal(-1, eg_parent(e, c"A"))
	assert_strings_equal(c"Alpha", e.document.nodes[eg_find(e, c"A")].label)
	assert_strings_equal(c"flowchart LR\nsubgraph G\nB\nend\nA --> B\nA[Alpha]\n", e.document.source)
	eg_restores(e, source)
	mm_editor_free(e)

void test_multi_selection_move_delete_and_resize_are_single_steps():
	char* source = eg_flow()
	mm_editor* e = mm_editor_new(c"unused.mmd", source)
	int a = eg_find(e, c"A")
	int c = eg_find(e, c"C")
	int ax = e.scene.nodes[a].x
	int cx = e.scene.nodes[c].x
	list[int] both = list[int]{a, c}
	assert_equal(1, mm_editor_move_nodes(e, both, 30, 10))
	assert_equal(1, e.position)
	assert_equal(ax + 30, e.scene.nodes[eg_find(e, c"A")].x)
	assert_equal(cx + 30, e.scene.nodes[eg_find(e, c"C")].x)
	eg_restores(e, source)
	assert_equal(1, mm_editor_delete_nodes(e, both))
	assert_equal(1, e.position)
	assert_equal(-1, eg_find(e, c"A"))
	assert_equal(-1, eg_find(e, c"C"))
	assert_equal(0, e.document.edges.length)
	eg_restores(e, source)
	# A failing member rolls the whole selection back.
	list[int] bad = list[int]{eg_find(e, c"B"), 99}
	assert_equal(0, mm_editor_delete_nodes(e, bad))
	assert_strings_equal(source, e.document.source)
	assert_equal(0, e.position)
	a = eg_find(e, c"A")
	assert_equal(1, mm_editor_resize_node(e, a, 210, 90))
	a = eg_find(e, c"A")
	assert_equal(210, e.scene.nodes[a].w)
	assert_equal(90, e.scene.nodes[a].h)
	asserts(c"size record", index_of(e.document.source, c"%% @w-size \"A\" 210 90\n") >= 0)
	mm_bounds* group = e.scene.nodes[eg_find(e, c"G")]
	asserts(c"group grows around the resized member", group.x + group.w >= e.scene.nodes[a].x + 210)
	assert_equal(0, mm_editor_resize_node(e, a, 2, 90))
	assert_equal(1, mm_editor_has_positions(e))
	assert_equal(1, mm_editor_reset_positions(e))
	assert_strings_equal(source, e.document.source)
	__w_list_free(cast(__w_list*, both))
	__w_list_free(cast(__w_list*, bad))
	mm_editor_free(e)

char* eg_class():
	return c"classDiagram\nnamespace Domain {\n  class Record\n  class Invoice\n  Record <|-- Invoice\n}\nclass Customer\nCustomer --> Invoice\n"

void test_class_namespace_members_rename_delete_connect_reparent():
	char* source = eg_class()
	mm_editor* e = mm_editor_new(c"unused.mmd", source)
	asserts(c"parses", e.document.error == 0)
	int domain = eg_find(e, c"Domain")
	assert_equal(1, mm_editor_set_label(e, eg_find(e, c"Record"), c"Base record"))
	assert_strings_equal(c"Base record", e.document.nodes[eg_find(e, c"Record")].label)
	assert_equal(domain, eg_parent(e, c"Record"))
	eg_restores(e, source)
	assert_equal(1, mm_editor_delete_node(e, eg_find(e, c"Invoice")))
	assert_strings_equal(c"classDiagram\nnamespace Domain {\n  class Record\n}\nclass Customer\n", e.document.source)
	eg_restores(e, source)
	assert_equal(1, mm_editor_delete_edge(e, 0))
	assert_equal(1, e.document.edges.length)
	assert_equal(domain, eg_parent(e, c"Invoice"))
	eg_restores(e, source)
	assert_equal(1, mm_editor_connect(e, c"Customer", c"Record"))
	eg_restores(e, source)
	assert_equal(1, mm_editor_reparent(e, eg_find(e, c"Customer"), domain))
	assert_equal(domain, eg_parent(e, c"Customer"))
	asserts(c"declaration moved into the namespace", index_of(e.document.source, c"  class Customer\n}\n") >= 0)
	eg_restores(e, source)
	assert_equal(1, mm_editor_add_node_in(e, c"Line", c"Line item", domain))
	assert_equal(domain, eg_parent(e, c"Line"))
	assert_strings_equal(c"Line item", e.document.nodes[eg_find(e, c"Line")].label)
	eg_restores(e, source)
	assert_equal(1, mm_editor_ungroup(e, domain))
	assert_equal(-1, eg_parent(e, c"Record"))
	eg_restores(e, source)
	mm_editor_free(e)

void test_state_composite_rename_reparent_and_move():
	char* source = c"stateDiagram-v2\n[*] --> Idle\nstate Busy {\n  [*] --> Working\n}\nIdle --> Busy\nstate Waiting\n"
	mm_editor* e = mm_editor_new(c"unused.mmd", source)
	asserts(c"parses", e.document.error == 0)
	int busy = eg_find(e, c"Busy")
	assert_equal(1, mm_editor_set_label(e, busy, c"Busy work"))
	assert_strings_equal(c"Busy work", e.document.nodes[eg_find(e, c"Busy")].label)
	assert_equal(1, e.document.nodes[eg_find(e, c"Busy")].group)
	eg_restores(e, source)
	assert_equal(1, mm_editor_reparent(e, eg_find(e, c"Waiting"), busy))
	assert_equal(busy, eg_parent(e, c"Waiting"))
	eg_restores(e, source)
	assert_equal(1, mm_editor_add_node_in(e, c"Paused", c"On hold", busy))
	assert_equal(busy, eg_parent(e, c"Paused"))
	eg_restores(e, source)
	mm_editor_free(e)

void test_usecase_boundary_swimlane_c4_and_architecture_groups():
	char* source = c"usecase-beta\nactor Customer\nsystemBoundary Store[\"Order system\"]\n  Checkout(Place order)\n  Review[Review order]\nend\nCustomer --> Checkout\n"
	mm_editor* e = mm_editor_new(c"unused.mmd", source)
	asserts(c"use case parses", e.document.error == 0)
	int store = eg_find(e, c"Store")
	assert_equal(1, mm_editor_set_label(e, eg_find(e, c"Checkout"), c"Buy now"))
	asserts(c"label in place", index_of(e.document.source, c"  Checkout(Buy now)\n") >= 0)
	eg_restores(e, source)
	assert_equal(1, mm_editor_reparent(e, eg_find(e, c"Review"), -1))
	assert_equal(-1, eg_parent(e, c"Review"))
	eg_restores(e, source)
	assert_equal(1, mm_editor_add_node_in(e, c"Pay", c"Pay order", store))
	assert_equal(store, eg_parent(e, c"Pay"))
	eg_restores(e, source)
	assert_equal(1, mm_editor_delete_node(e, store))
	assert_strings_equal(c"usecase-beta\nactor Customer\n", e.document.source)
	eg_restores(e, source)
	mm_editor_free(e)
	source = c"swimlane-beta LR\nsubgraph Customer\n  request([Request])\nend\nsubgraph Engineering\n  work[Implement]\nend\nrequest --> work\n"
	e = mm_editor_new(c"unused.mmd", source)
	asserts(c"swimlane parses", e.document.error == 0)
	assert_equal(1, mm_editor_reparent(e, eg_find(e, c"request"), eg_find(e, c"Engineering")))
	assert_equal(eg_find(e, c"Engineering"), eg_parent(e, c"request"))
	asserts(c"declaration carried with its shape", index_of(e.document.source, c"  request([Request])\nend\nrequest --> work") >= 0)
	eg_restores(e, source)
	assert_equal(1, mm_editor_add_node_in(e, c"ship", c"Ship", eg_find(e, c"Engineering")))
	assert_equal(eg_find(e, c"Engineering"), eg_parent(e, c"ship"))
	eg_restores(e, source)
	mm_editor_free(e)
	source = c"C4Container\nPerson(user, \"User\")\nSystem_Boundary(editor, \"Desktop editor\") {\n  Container(parser, \"Parser\", \"W\")\n  ContainerDb(model, \"Model\", \"W structs\")\n}\nRel(user, parser, \"Edits source\")\nRel(parser, model, \"Reads\")\n"
	e = mm_editor_new(c"unused.mmd", source)
	asserts(c"C4 parses", e.document.error == 0)
	int editor = eg_find(e, c"editor")
	assert_equal(1, mm_editor_reparent(e, eg_find(e, c"user"), editor))
	assert_equal(eg_find(e, c"editor"), eg_parent(e, c"user"))
	eg_restores(e, source)
	assert_equal(1, mm_editor_set_label(e, editor, c"Editor app"))
	asserts(c"boundary label in place", index_of(e.document.source, c"System_Boundary(editor, \"Editor app\") {") >= 0)
	eg_restores(e, source)
	assert_equal(1, mm_editor_delete_node(e, eg_find(e, c"model")))
	assert_strings_equal(c"C4Container\nPerson(user, \"User\")\nSystem_Boundary(editor, \"Desktop editor\") {\n  Container(parser, \"Parser\", \"W\")\n}\nRel(user, parser, \"Edits source\")\n", e.document.source)
	eg_restores(e, source)
	mm_editor_free(e)
	source = c"architecture-beta\ngroup api(cloud)[API]\nservice db(database)[Database] in api\nservice edge(internet)[Gateway]\nedge:R --> L:db\n"
	e = mm_editor_new(c"unused.mmd", source)
	asserts(c"architecture parses", e.document.error == 0)
	int api = eg_find(e, c"api")
	assert_equal(1, mm_editor_reparent(e, eg_find(e, c"edge"), api))
	assert_equal(api, eg_parent(e, c"edge"))
	asserts(c"in suffix added", index_of(e.document.source, c"service edge(internet)[Gateway] in api\n") >= 0)
	eg_restores(e, source)
	assert_equal(1, mm_editor_reparent(e, eg_find(e, c"db"), -1))
	assert_equal(-1, eg_parent(e, c"db"))
	asserts(c"in suffix removed", index_of(e.document.source, c"service db(database)[Database]\n") >= 0)
	eg_restores(e, source)
	assert_equal(1, mm_editor_ungroup(e, api))
	assert_strings_equal(c"architecture-beta\nservice db(database)[Database]\nservice edge(internet)[Gateway]\nedge:R --> L:db\n", e.document.source)
	eg_restores(e, source)
	assert_equal(1, mm_editor_move_node(e, api, 300, 200))
	assert_equal(300, e.scene.nodes[eg_find(e, c"api")].x)
	mm_editor_free(e)

void test_deleting_a_group_keeps_survivors_declared_by_its_edges():
	char* source = c"flowchart LR\nsubgraph G[Group]\n  A[Alpha]\nend\nA --> B[Beta]\nB --> C\n"
	mm_editor* e = mm_editor_new(c"unused.mmd", source)
	assert_equal(1, mm_editor_delete_node(e, eg_find(e, c"G")))
	assert_strings_equal(c"flowchart LR\nB[Beta]\nB --> C\n", e.document.source)
	assert_strings_equal(c"Beta", e.document.nodes[eg_find(e, c"B")].label)
	assert_equal(1, mm_editor_undo(e, 0))
	assert_strings_equal(source, e.document.source)
	mm_editor_free(e)
