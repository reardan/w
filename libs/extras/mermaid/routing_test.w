# wbuild: x64
# Stress fixtures for layered ordering, channel routing and label placement:
# every check measures the rendered scene (crossings, edges through nodes,
# overlapping labels and segments), not only that something rendered.
import lib.testing
import libs.extras.mermaid.parser
import libs.extras.mermaid.route_metrics

# Small deterministic generator, identical on 32- and 64-bit targets.
int routing_next(int* state):
	state[0] = (state[0] * 75 + 74) % 65537
	return state[0]

# A layered DAG: nodes split into `ranks` bands, edges only go down the bands
# (often skipping several), every third one labeled.
char* routing_dense_flow(char* direction, int nodes, int edges, int ranks, int seed):
	string_builder* s = string_from(c"flowchart ")
	string_append(s, direction)
	string_append_char(s, 10)
	for i in range(nodes):
		string_append(s, c"n")
		string_append_int(s, i)
		string_append(s, c"[Node ")
		string_append_int(s, i)
		string_append(s, c"]\n")
	int state = seed
	for k in range(edges):
		int a = routing_next(&state) % nodes
		int b = routing_next(&state) % nodes
		if (a * ranks / nodes == b * ranks / nodes): continue
		if (a * ranks / nodes > b * ranks / nodes):
			int t = a
			a = b
			b = t
		string_append(s, c"n")
		string_append_int(s, a)
		if (k % 3 == 0):
			string_append(s, c" -->|l")
			string_append_int(s, k)
			string_append(s, c"| n")
		else: string_append(s, c" --> n")
		string_append_int(s, b)
		string_append_char(s, 10)
	char* text = s.data
	free(s)
	return text

char* routing_crowded_er(int entities, int relationships, int seed):
	string_builder* s = string_from(c"erDiagram\n")
	for i in range(entities):
		string_append(s, c"E")
		string_append_int(s, i)
		string_append(s, c" {\nint id PK\n}\n")
	list[char*] cards = list[char*]{c" ||--o{ ", c" }o--|| ", c" ||--|| ", c" }|..|{ "}
	int state = seed
	for k in range(relationships):
		int a = routing_next(&state) % entities
		int b = routing_next(&state) % entities
		if (a == b): continue
		string_append(s, c"E")
		string_append_int(s, a)
		string_append(s, cards[k % 4])
		string_append(s, c"E")
		string_append_int(s, b)
		string_append(s, c" : rel")
		string_append_int(s, k)
		string_append_char(s, 10)
	__w_list_free(cast(__w_list*, cards))
	char* text = s.data
	free(s)
	return text

mm_route_quality* routing_measure(char* text, mm_scene** scene, mm_document** doc):
	mm_document* d = mm_parse(text, strlen(text))
	asserts(c"routing fixture parses", d.error == 0)
	mm_scene* s = mm_render(d)
	asserts(c"routing fixture renders", s != 0)
	scene[0] = s
	doc[0] = d
	return mm_route_measure(d, s)

void test_long_edge_routes_through_a_dummy_channel():
	# The A --> D edge spans two ranks that also hold B and C.
	char* text = c"flowchart TB\nA --> B\nB --> C\nC --> D\nA --> D\nA --> C\n"
	mm_scene* s = 0
	mm_document* d = 0
	mm_route_quality* q = routing_measure(text, &s, &d)
	assert_equal(0, q.node_hits)
	assert_equal(0, q.overlaps)
	mm_edge_route* r = mm_edge_route_of(s.nodes[0], d.edges[3], 0)
	asserts(c"long edge has a route", r != 0 && r.lanes != 0)
	assert_equal(2, r.lanes.length)
	assert_equal(3, r.gaps.length / 2)
	free(q)
	mm_scene_free(s)
	mm_document_free(d)
	# Back edges route through channels too, in reverse rank order.
	text = c"flowchart LR\nA --> B\nB --> C\nC --> D\nD --> A\n"
	q = routing_measure(text, &s, &d)
	assert_equal(0, q.node_hits)
	free(q)
	mm_scene_free(s)
	mm_document_free(d)

void test_every_curve_style_avoids_unrelated_nodes():
	list[char*] curves = list[char*]{c"step", c"linear", c"basis"}
	for char* curve in curves:
		string_builder* text = string_from(c"---\nconfig:\n  flowchart:\n    curve: ")
		string_append(text, curve)
		string_append(text, c"\n---\nflowchart TB\nA --> B\nB --> C\nC --> D\nA --> D\nX --> B\nX --> D\n")
		mm_scene* s = 0
		mm_document* d = 0
		mm_route_quality* q = routing_measure(text.data, &s, &d)
		assert_equal(0, q.node_hits)
		free(q)
		mm_scene_free(s)
		mm_document_free(d)
		string_free(text)
	__w_list_free(cast(__w_list*, curves))

void test_ordering_removes_avoidable_crossings():
	# In source order every top node points at the bottom node opposite it.
	char* text = c"flowchart TB\nA\nB\nC\nD\nE\nF\nA --> F\nB --> E\nC --> D\n"
	mm_document* d = mm_parse(text, strlen(text))
	mm_scene* s = mm_render(d)
	assert_equal(0, mm_layered_last_crossings)
	mm_route_quality* q = mm_route_measure(d, s)
	assert_equal(0, q.crossings)
	free(q)
	mm_scene_free(s)
	mm_document_free(d)
	# K(2,2) plus a long edge: only the unavoidable crossing remains.
	text = c"flowchart TB\nA --> C\nA --> D\nB --> C\nB --> D\nA --> E\nC --> E\n"
	d = mm_parse(text, strlen(text))
	s = mm_render(d)
	assert_equal(1, mm_layered_last_crossings)
	mm_scene_free(s)
	mm_document_free(d)

# Measured on these generators: before layered routing the TB fixture drew
# 22 edges through unrelated nodes with 95 collinear overlaps and 6
# overlapping labels; the LR one 23, 119 and 5 (docs/projects/mermaid_layout.md).
void test_dense_flowchart_stress():
	list[char*] directions = list[char*]{c"TB", c"LR"}
	for char* direction in directions:
		char* text = routing_dense_flow(direction, 24, 54, 5, 7)
		mm_scene* s = 0
		mm_document* d = 0
		mm_route_quality* q = routing_measure(text, &s, &d)
		asserts(c"fixture is dense", d.edges.length >= 36)
		assert_equal(0, q.node_hits)
		assert_equal(0, q.overlaps)
		assert_equal(0, q.label_overlaps)
		assert_equal(0, q.label_node_overlaps)
		asserts(c"crossings bounded", q.crossings <= d.edges.length * 2)
		# Deterministic display list.
		mm_scene* again = mm_render(d)
		char* first = mm_svg(s)
		char* second = mm_svg(again)
		assert_strings_equal(first, second)
		free(first)
		free(second)
		mm_scene_free(again)
		free(q)
		mm_scene_free(s)
		mm_document_free(d)
		free(text)
	__w_list_free(cast(__w_list*, directions))

void test_crowded_er_ports_and_labels():
	char* text = routing_crowded_er(7, 17, 3)
	mm_scene* s = 0
	mm_document* d = 0
	mm_route_quality* q = routing_measure(text, &s, &d)
	asserts(c"fixture is crowded", d.edges.length >= 14)
	assert_equal(0, q.node_hits)
	assert_equal(0, q.shared_ports)
	assert_equal(0, q.label_overlaps)
	assert_equal(0, q.label_node_overlaps)
	assert_equal(0, q.overlaps)
	free(q)
	mm_scene_free(s)
	mm_document_free(d)
	free(text)
	# Parallel relationships between one pair take distinct, ordered ports.
	text = c"erDiagram\nA ||--o{ B : places\nA ||--o{ B : returns\nA ||--|| B : owns\n"
	q = routing_measure(text, &s, &d)
	assert_equal(0, q.shared_ports)
	assert_equal(0, q.label_overlaps)
	assert_equal(0, q.crossings)
	for i in range(3):
		mm_edge_route* r = mm_edge_route_of(s.nodes[0], d.edges[i], 0)
		assert_equal(3, r.from_count)
		assert_equal(i, r.from_slot)
		assert_equal(i, r.to_slot)
	free(q)
	mm_scene_free(s)
	mm_document_free(d)

void test_parallel_flowchart_edges_spread():
	char* text = c"flowchart TB\nA --> B\nA -->|again| B\n"
	mm_scene* s = 0
	mm_document* d = 0
	mm_route_quality* q = routing_measure(text, &s, &d)
	assert_equal(0, q.shared_ports)
	assert_equal(0, q.overlaps)
	free(q)
	mm_scene_free(s)
	mm_document_free(d)

void test_manual_positions_override_layout_routes():
	char* text = c"flowchart TB\nA --> B\nB --> C\nA --> C\n%% @w-position \"C\" 900 40\n"
	mm_document* d = mm_parse(text, strlen(text))
	mm_scene* s = mm_render(d)
	mm_bounds* c = s.nodes[2]
	assert_equal(900, c.x)
	assert_equal(40, c.y)
	mm_edge_route* r = mm_edge_route_of(s.nodes[0], d.edges[2], 0)
	int tx = 0
	int ty = 0
	asserts(c"moved endpoint drops its stale route", mm_route_usable(r, s.nodes[0], c, 0, &tx, &ty) == 0)
	# The direct route ends on the moved node.
	mm_scene* view = mm_route_edge_scene(d, s, d.edges[2], 1)
	mm_primitive* last = view.items[view.items.length - 1]
	asserts(c"edge reaches the moved node", last.x2 >= c.x && last.x2 <= c.x + c.w)
	mm_route_edge_scene_free(view)
	mm_scene_free(s)
	mm_document_free(d)
	# A title shifts both endpoints alike, so the route survives it.
	text = c"---\ntitle: Routed\n---\nflowchart TB\nA --> B\nB --> C\nA --> C\n"
	d = mm_parse(text, strlen(text))
	s = mm_render(d)
	r = mm_edge_route_of(s.nodes[0], d.edges[2], 0)
	asserts(c"title keeps the route", mm_route_usable(r, s.nodes[0], s.nodes[2], 0, &tx, &ty))
	assert_equal(40, ty)
	mm_route_quality* q = mm_route_measure(d, s)
	assert_equal(0, q.node_hits)
	free(q)
	mm_scene_free(s)
	mm_document_free(d)

void test_edge_redraw_reuses_placed_label():
	char* text = c"flowchart TB\nA -->|one| C\nB -->|two| C\nD -->|three| C\n"
	mm_document* d = mm_parse(text, strlen(text))
	mm_scene* s = mm_render(d)
	for mm_edge* e in d.edges:
		mm_scene* view = mm_route_edge_scene(d, s, e, 0)
		int found = 0
		for mm_primitive* p in view.items:
			if (p.kind != MM_TEXT): continue
			for mm_primitive* full in s.items:
				if (full.kind == MM_TEXT && strcmp(full.text, p.text) == 0 && full.x == p.x && full.y == p.y): found = 1
		asserts(c"edge-only redraw matches the full scene label", found)
		mm_route_edge_scene_free(view)
	mm_scene_free(s)
	mm_document_free(d)

void test_large_graph_budgets():
	char* text = routing_dense_flow(c"TB", 2000, 3000, 80, 11)
	mm_document* d = mm_parse(text, strlen(text))
	asserts(c"2000-node flowchart within budget", d.error == 0)
	mm_scene* s = mm_render(d)
	asserts(c"large flowchart renders", s != 0 && s.nodes.length == 2000)
	mm_scene_free(s)
	mm_document_free(d)
	free(text)
	text = routing_crowded_er(1500, 1800, 5)
	d = mm_parse(text, strlen(text))
	asserts(c"1500-entity ER within budget", d.error == 0)
	s = mm_render(d)
	asserts(c"large ER renders", s != 0)
	mm_scene_free(s)
	mm_document_free(d)
	free(text)
	# The quadratic force layout keeps the general budget.
	string_builder* force = string_from(c"---\nconfig:\n  layout: force\n---\nflowchart TB\n")
	for i in range(MM_MAX_ITEMS + 1):
		string_append(force, c"n")
		string_append_int(force, i)
		string_append_char(force, 10)
	d = mm_parse(force.data, force.length)
	assert_strings_equal(c"force layout node limit exceeded", d.error)
	mm_document_free(d)
	string_free(force)
