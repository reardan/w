# wbuild: x64
import lib.testing
import libs.extras.mermaid.edit_commands

void test_graphical_labels_preserve_envelope_theme_shapes_and_undo():
	char* source = c"# Notes\n```mermaid\nflowchart LR\nuntouched\n```\nText\n```mermaid\n---\ntitle: Keep this\nconfig:\n  theme: dark\n  layout: force\n---\nflowchart TB\n%% Keep comment\nclassDef hot fill:red\nsubgraph G[Group]\ndirection LR\nA([Start]):::hot --> B{{Finish}}\nend\nstyle A stroke:blue\n```\nTail\n"
	mm_editor* e = mm_editor_new(c"unused.mmd", source)
	assert_equal(1, mm_editor_select(e, 1))
	int index = mm_find_node(e.document, c"A")
	assert_equal(1, mm_editor_set_label(e, index, c"New start"))
	assert_strings_equal(c"New start", e.document.nodes[mm_find_node(e.document, c"A")].label)
	assert_equal(21, e.document.nodes[mm_find_node(e.document, c"A")].shape)
	asserts(c"other fence preserved", index_of(e.document.source, c"flowchart LR\nuntouched\n```\nText") >= 0)
	asserts(c"comment and config preserved", index_of(e.document.source, c"  layout: force\n---\nflowchart TB\n%% Keep comment") >= 0)
	asserts(c"tail preserved", index_of(e.document.source, c"```\nTail\n") >= 0)
	assert_equal(1, e.position)
	assert_equal(1, mm_editor_undo(e, 0))
	assert_strings_equal(source, e.document.source)
	assert_equal(1, mm_editor_undo(e, 1))
	assert_strings_equal(c"New start", e.document.nodes[mm_find_node(e.document, c"A")].label)
	assert_equal(1, mm_editor_set_label(e, mm_find_node(e.document, c"A"), c"New start"))
	assert_equal(1, e.position)
	mm_editor_free(e)

void test_graphical_delete_chain_middle_preserves_inline_neighbors_and_styles():
	char* source = c"flowchart LR\nclassDef hot fill:red\nsubgraph G[Group]\nA([Start]):::hot -->|one| B{Middle} --> C[[Finish]] --> D[Last] %% trailing\nend\nstyle A,B stroke:blue\nclass B,C hot\nlinkStyle 0,1,2 stroke:green\nlinkStyle 2 stroke-width:3\n%% final comment\n"
	mm_editor* e = mm_editor_new(c"unused.mmd", source)
	asserts(c"parse", e.document.error == 0)
	assert_equal(1, mm_editor_delete_node(e, mm_find_node(e.document, c"B")))
	assert_equal(-1, mm_find_node(e.document, c"B"))
	assert_equal(4, e.document.nodes.length)
	assert_equal(1, e.document.edges.length)
	assert_equal(0x008000, e.document.edges[0].style.stroke)
	assert_equal(3, e.document.edges[0].style.width)
	asserts(c"comments retained", index_of(e.document.source, c"%% trailing") >= 0 && index_of(e.document.source, c"%% final comment") >= 0)
	asserts(c"link indices retargeted", index_of(e.document.source, c"linkStyle 0 stroke-width:3") >= 0)
	assert_equal(1, e.position)
	assert_equal(1, mm_editor_undo(e, 0))
	assert_strings_equal(source, e.document.source)
	mm_editor_free(e)

void test_graphical_delete_one_parallel_edge_and_keep_endpoint_declarations():
	char* source = c"flowchart LR; A[\"left; %% label\"] -->|first| B([Right]) --> C{Third}; A -.->|second| B\nlinkStyle 0 stroke:red\nlinkStyle 1,2 stroke:blue\nlinkStyle default color:green\n"
	mm_editor* e = mm_editor_new(c"unused.mmd", source)
	asserts(c"parse", e.document.error == 0)
	assert_equal(1, mm_editor_delete_edge(e, 0))
	assert_equal(3, e.document.nodes.length)
	assert_equal(2, e.document.edges.length)
	assert_strings_equal(c"left; %% label", e.document.nodes[mm_find_node(e.document, c"A")].label)
	assert_equal(21, e.document.nodes[mm_find_node(e.document, c"B")].shape)
	assert_equal(0x0000ff, e.document.edges[0].style.stroke)
	assert_equal(0x0000ff, e.document.edges[1].style.stroke)
	assert_strings_equal(c"second", e.document.edges[1].label)
	asserts(c"default style intact", index_of(e.document.source, c"linkStyle default color:green") >= 0)
	assert_equal(1, mm_editor_undo(e, 0))
	assert_strings_equal(source, e.document.source)
	mm_editor_free(e)

void test_graphical_node_delete_repeated_self_edges_and_styles_only_node():
	mm_editor* e = mm_editor_new(c"unused.mmd", c"flowchart LR\nA --> A --> B --> A\nstyle A fill:red\nclassDef hot stroke:blue\nclass A,B hot\nstyle C fill:green\n")
	assert_equal(1, mm_editor_delete_node(e, mm_find_node(e.document, c"A")))
	assert_equal(2, e.document.nodes.length)
	assert_equal(0, e.document.edges.length)
	assert_equal(1, mm_editor_delete_node(e, mm_find_node(e.document, c"C")))
	assert_equal(1, e.document.nodes.length)
	assert_strings_equal(c"B", e.document.nodes[0].id)
	assert_equal(1, mm_editor_delete_node(e, 0))
	assert_equal(0, e.document.nodes.length)
	assert_equal(1, e.document.style_definitions.length)
	mm_editor_free(e)

void test_graphical_er_delete_entity_attributes_and_relationships():
	char* source = c"erDiagram\n%% keep\nUSER[People] {\n int id PK \"identifier\"\n string name\n}\nUSER ||--o{ ORDER[Orders] : \"places an order\"\nORDER {\n int id PK\n int owner FK\n}\nORDER ||..|{ ITEM : contains\nstyle USER,ORDER fill:red\nlinkStyle 0,1 stroke:blue\n"
	mm_editor* e = mm_editor_new(c"unused.mmd", source)
	asserts(c"parse", e.document.error == 0)
	assert_equal(1, mm_editor_set_label(e, mm_find_node(e.document, c"ORDER"), c"Purchases"))
	assert_equal(1, mm_editor_delete_node(e, mm_find_node(e.document, c"USER")))
	assert_equal(2, e.document.nodes.length)
	assert_equal(2, e.document.nodes[mm_find_node(e.document, c"ORDER")].attributes.length)
	assert_strings_equal(c"Purchases", e.document.nodes[mm_find_node(e.document, c"ORDER")].label)
	assert_equal(1, e.document.edges.length)
	assert_strings_equal(c"contains", e.document.edges[0].label)
	assert_equal(0x0000ff, e.document.edges[0].style.stroke)
	assert_equal(1, mm_editor_delete_edge(e, 0))
	assert_equal(2, e.document.nodes.length)
	assert_equal(0, e.document.edges.length)
	asserts(c"comment survives", index_of(e.document.source, c"%% keep") >= 0)
	mm_editor_free(e)

void test_graphical_edits_reject_invalid_input_without_history_or_source_changes():
	char* source = c"flowchart LR\nsubgraph G[Group]\nA --> B\nend\n"
	mm_editor* e = mm_editor_new(c"unused.mmd", source)
	assert_equal(0, mm_editor_delete_node(e, mm_find_node(e.document, c"G")))
	assert_equal(0, mm_editor_delete_edge(e, 3))
	assert_equal(0, mm_editor_set_label(e, mm_find_node(e.document, c"A"), c"bad\" ]\nX --> Y"))
	assert_equal(0, mm_editor_set_label(e, mm_find_node(e.document, c"A"), c"bad\nline"))
	assert_equal(0, e.position)
	assert_strings_equal(source, e.document.source)
	asserts(c"actionable group reason", index_of(mm_editor_edit_reason(e, MM_EDIT_NODE_DELETE, 0), c"source pane") >= 0)
	mm_editor_free(e)
	e = mm_editor_new(c"unused.mmd", c"pie\n\"A\" : 10\n")
	assert_equal(0, mm_editor_delete_node(e, 0))
	asserts(c"family reason", index_of(mm_editor_edit_reason(e, MM_EDIT_NODE_DELETE, 0), c"flowcharts and ER") >= 0)
	mm_editor_free(e)
	e = mm_editor_new(c"unused.mmd", c"flowchart LR\nA[\n")
	assert_equal(0, mm_editor_delete_node(e, 0))
	assert_equal(0, e.position)
	mm_editor_free(e)

void test_graphical_er_creation_cardinality_and_undo():
	mm_editor* e = mm_editor_new(c"unused.mmd", c"erDiagram\n%% retained\n")
	assert_equal(1, mm_editor_add_entity(e, c"USER", c"People"))
	assert_equal(1, mm_editor_add_entity(e, c"ORDER", c"Orders"))
	assert_equal(1, mm_editor_add_relationship(e, c"USER", c"ORDER", c"places", 1, 2, 1))
	assert_equal(1, e.document.edges.length)
	assert_equal(1, e.document.edges[0].left_card)
	assert_equal(2, e.document.edges[0].right_card)
	assert_equal(1, e.document.edges[0].dashed)
	assert_equal(0, mm_editor_add_entity(e, c"USER", c"duplicate"))
	assert_equal(0, mm_editor_add_relationship(e, c"missing", c"ORDER", c"places", 1, 2, 0))
	assert_equal(0, mm_editor_add_relationship(e, c"USER", c"ORDER", c"places", 4, 2, 0))
	assert_equal(3, e.position)
	assert_equal(1, mm_editor_undo(e, 0))
	assert_equal(0, e.document.edges.length)
	mm_editor_free(e)

void test_graphical_delete_each_chain_position_and_connection():
	char* source = c"flowchart LR\nsubgraph G[\"group; %% literal\"]\nA[\"Alpha\"] --> B([\"Beta\"]) -.-> C{{\"Gamma\"}} --- D[\"Delta\"]\nend\nlinkStyle 0 stroke:red\nlinkStyle 1 stroke:green\nlinkStyle 2 stroke:blue\n"
	list[char*] ids = list[char*]{c"A", c"B", c"C", c"D"}
	for i in range(4):
		mm_editor* e = mm_editor_new(c"unused.mmd", source)
		asserts(c"chain parses", e.document.error == 0)
		assert_equal(1, mm_editor_delete_node(e, mm_find_node(e.document, ids[i])))
		assert_equal(4, e.document.nodes.length)
		assert_equal(-1, mm_find_node(e.document, ids[i]))
		int edges = 1
		if (i == 0 || i == 3): edges = 2
		assert_equal(edges, e.document.edges.length)
		assert_equal(1, mm_editor_undo(e, 0))
		assert_strings_equal(source, e.document.source)
		mm_editor_free(e)
	for i in range(3):
		mm_editor* e = mm_editor_new(c"unused.mmd", source)
		assert_equal(1, mm_editor_delete_edge(e, i))
		assert_equal(5, e.document.nodes.length)
		assert_equal(2, e.document.edges.length)
		assert_equal(1, mm_editor_undo(e, 0))
		assert_strings_equal(source, e.document.source)
		mm_editor_free(e)
	__w_list_free(cast(__w_list*, ids))

void test_graphical_connect_quoted_id_and_delete_preserve_markdown_crlf():
	char* source = c"Prose\r\n```mermaid\r\nflowchart LR\r\n\"First node\"[\"Alpha\"]; \"Second node\"([\"Beta\"])\r\n%% retained\r\n```\r\nTail\r\n"
	mm_editor* e = mm_editor_new(c"unused.mmd", source)
	assert_equal(1, mm_editor_connect(e, c"First node", c"Second node"))
	assert_equal(1, e.document.edges.length)
	assert_equal(1, mm_editor_undo(e, 0))
	assert_strings_equal(source, e.document.source)
	assert_equal(1, mm_editor_delete_node(e, mm_find_node(e.document, c"First node")))
	assert_equal(1, e.document.nodes.length)
	assert_strings_equal(c"Beta", e.document.nodes[0].label)
	asserts(c"retained CRLF envelope", index_of(e.document.source, c"%% retained\r\n```\r\nTail\r\n") >= 0)
	assert_equal(1, mm_editor_undo(e, 0))
	assert_strings_equal(source, e.document.source)
	mm_editor_free(e)

void test_graphical_delete_position_comment_does_not_affect_readded_node():
	char* source = c"flowchart LR\nA[Alpha] --> B[Beta]\n%% @w-position \"A\" 500 700\n%% @w-position \"B\" 600 800\n%% @w-position \"A\" bad 700\n"
	mm_editor* e = mm_editor_new(c"unused.mmd", source)
	assert_equal(1, mm_editor_delete_node(e, mm_find_node(e.document, c"A")))
	asserts(c"deleted metadata removed", index_of(e.document.source, c"%% @w-position \"A\" 500 700") < 0)
	asserts(c"survivor metadata unchanged", index_of(e.document.source, c"%% @w-position \"B\" 600 800") >= 0)
	asserts(c"ordinary malformed comment unchanged", index_of(e.document.source, c"%% @w-position \"A\" bad 700") >= 0)
	assert_equal(1, mm_editor_add_node(e, c"A", c"New"))
	int node = mm_find_node(e.document, c"A")
	asserts(c"new node does not inherit removed position", e.scene.nodes[node].x != 500 || e.scene.nodes[node].y != 700)
	assert_equal(1, mm_editor_undo(e, 0))
	assert_equal(1, mm_editor_undo(e, 0))
	assert_strings_equal(source, e.document.source)
	mm_editor_free(e)
