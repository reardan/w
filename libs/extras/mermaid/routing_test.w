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

# Measured on these generators: before layered routing both fixtures drew 17
# edges through unrelated nodes, 99 collinear overlaps, 4-5 overlapping labels
# and 20 visible crossings (docs/projects/mermaid_layout.md).
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
		# Every drawn crossing is a rank-to-rank crossing the ordering kept
		# (39 here; random-restart search finds 36 at best).
		asserts(c"drawn crossings match the layered ones", q.crossings <= mm_layered_last_crossings)
		asserts(c"crossings pinned", q.crossings <= 39)
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
	asserts(c"crowded ER crossings pinned", q.crossings <= 1)
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

# Subgraphs of `per` chained nodes each, plus random edges between nodes of
# different subgraphs (laid out against their group boxes, so not
# channel-routed).
char* routing_nested_flow(char* direction, int groups, int per, int edges, int seed):
	string_builder* s = string_from(c"flowchart ")
	string_append(s, direction)
	string_append_char(s, 10)
	for g in range(groups):
		string_append(s, c"subgraph g")
		string_append_int(s, g)
		string_append(s, c"[Group ")
		string_append_int(s, g)
		string_append(s, c"]\n")
		for k in range(per):
			string_append(s, c"n")
			string_append_int(s, g * per + k)
			if (k + 1 < per):
				string_append(s, c" --> n")
				string_append_int(s, g * per + k + 1)
			string_append_char(s, 10)
		string_append(s, c"end\n")
	int state = seed
	int nodes = groups * per
	for k in range(edges):
		int a = routing_next(&state) % nodes
		int b = routing_next(&state) % nodes
		if (a / per == b / per): continue
		string_append(s, c"n")
		string_append_int(s, a)
		string_append(s, c" --> n")
		string_append_int(s, b)
		string_append_char(s, 10)
	char* text = s.data
	free(s)
	return text

# Quality of the direct routes the obstacle router replaces (the renderer
# before it), for the before/after comparisons below.
mm_route_quality* routing_measure_direct(char* text):
	mm_render_obstacle_enabled = 0
	mm_scene* s = 0
	mm_document* d = 0
	mm_route_quality* q = routing_measure(text, &s, &d)
	mm_render_obstacle_enabled = 1
	mm_scene_free(s)
	mm_document_free(d)
	return q

void routing_print(char* name, mm_route_quality* q):
	print_error(name)
	print_int0(c": crossings ", q.crossings)
	print_int0(c" node hits ", q.node_hits)
	print_int0(c" title hits ", q.title_hits)
	print_int0(c" end hits ", q.end_hits)
	print_int0(c" overlaps ", q.overlaps)
	print_int0(c" label overlaps ", q.label_overlaps)
	print_int0(c" label-node ", q.label_node_overlaps)
	print_int(c" shared ports ", q.shared_ports)

void test_self_loops_avoid_neighbors():
	# A's loop would run through B, packed beside it in the same rank.
	char* text = c"---\nconfig:\n  flowchart:\n    nodeSpacing: 20\n---\nflowchart TB\nR --> A\nR --> B\nA --> A\nB --> B\nR --> C\nC --> C\n"
	mm_route_quality* before = routing_measure_direct(text)
	routing_print(c"self loops before", before)
	mm_scene* s = 0
	mm_document* d = 0
	mm_route_quality* q = routing_measure(text, &s, &d)
	routing_print(c"self loops after", q)
	asserts(c"direct loops hit their neighbors", before.node_hits > 0)
	assert_equal(0, q.node_hits)
	assert_equal(0, q.overlaps)
	mm_edge_route* r = mm_edge_route_of(s.nodes[1], d.edges[2], 0)
	asserts(c"blocked loop gets an obstacle route", r != 0 && r.points != 0)
	free(before)
	free(q)
	mm_scene_free(s)
	mm_document_free(d)

void test_same_rank_edges_route_around_nodes():
	# Three nodes held in one row by persisted positions; A and B are joined
	# both ways past M, and A to M twice.
	char* text = c"flowchart TB\nA --> B\nB --> A\nA --> M\nA -->|again| M\nM\n%% @w-position \"A\" 40 40\n%% @w-position \"M\" 300 40\n%% @w-position \"B\" 560 40\n"
	mm_route_quality* before = routing_measure_direct(text)
	routing_print(c"same rank before", before)
	mm_scene* s = 0
	mm_document* d = 0
	mm_route_quality* q = routing_measure(text, &s, &d)
	routing_print(c"same rank after", q)
	asserts(c"direct same-rank routes run through their ends", before.end_hits > 0)
	assert_equal(0, q.end_hits)
	assert_equal(0, q.node_hits)
	assert_equal(0, q.overlaps)
	assert_equal(0, q.shared_ports)
	# Four A-side ports in one 80px gap: the route ordering keeps 4 crossings.
	asserts(c"same-rank crossings pinned", q.crossings <= 4)
	# Same-rank edges leave by the facing sides, with arrowheads level.
	mm_edge_route* r = mm_edge_route_of(s.nodes[0], d.edges[2], 0)
	asserts(c"side ports", r != 0 && r.points != 0 && r.from_dx == 1 && r.to_dx == -1)
	free(before)
	free(q)
	mm_scene_free(s)
	mm_document_free(d)

void test_nested_subgraph_edges_avoid_nodes_and_titles():
	list[char*] directions = list[char*]{c"TB", c"LR"}
	for char* direction in directions:
		char* text = routing_nested_flow(direction, 4, 3, 12, 5)
		mm_route_quality* before = routing_measure_direct(text)
		routing_print(c"nested before", before)
		mm_scene* s = 0
		mm_document* d = 0
		mm_route_quality* q = routing_measure(text, &s, &d)
		routing_print(c"nested after", q)
		asserts(c"direct nested routes cross nodes", before.node_hits > 0)
		assert_equal(0, q.node_hits)
		assert_equal(0, q.title_hits)
		assert_equal(0, q.overlaps)
		asserts(c"no more crossings than direct routes", q.crossings <= before.crossings)
		# Deterministic display list.
		mm_scene* again = mm_render(d)
		char* first = mm_svg(s)
		char* second = mm_svg(again)
		assert_strings_equal(first, second)
		free(first)
		free(second)
		mm_scene_free(again)
		free(before)
		free(q)
		mm_scene_free(s)
		mm_document_free(d)
		free(text)
	__w_list_free(cast(__w_list*, directions))

void test_agentflow_curves_follow_routes():
	# The long A --> D edge has a curve and two nodes in its way.
	list[char*] curves = list[char*]{c"step", c"linear", c"basis"}
	for char* curve in curves:
		string_builder* text = string_from(c"agentflow-beta TB\nA --> B\nB --> C\nC --> D\nA e1@--> D\nX --> B\nX --> D\nflow G[\"Group\"]\n  P --> Q\nend\nA e2@--> Q\ne1@{curve: ")
		string_append(text, curve)
		string_append(text, c"}\ne2@{curve: ")
		string_append(text, curve)
		string_append(text, c"}\n")
		mm_route_quality* before = routing_measure_direct(text.data)
		routing_print(curve, before)
		mm_scene* s = 0
		mm_document* d = 0
		mm_route_quality* q = routing_measure(text.data, &s, &d)
		routing_print(curve, q)
		assert_equal(0, q.node_hits)
		assert_equal(0, q.title_hits)
		mm_edge_route* r = mm_edge_route_of(s.nodes[0], d.edges[3], 0)
		asserts(c"curved agentflow edge keeps its channel", r != 0 && r.lanes != 0 && r.lanes.length == 2)
		free(before)
		free(q)
		mm_scene_free(s)
		mm_document_free(d)
		string_free(text)
	__w_list_free(cast(__w_list*, curves))

void test_obstacle_router_unit():
	# A wall between the stubs: the route goes around it, clear of the wall.
	list[int] rects = list[int]{100, -200, 140, 200}
	list[int] segs = new list[int]
	list[int] kinds = new list[int]
	list[int] out = new list[int]
	list[int] chosen = list[int]{0, 0}
	list[int] starts = list[int]{0, 0, 0, 0}
	list[int] targets = list[int]{240, 0, 0, 0}
	asserts(c"route found", mm_obstacle_route(rects, segs, kinds, starts, targets, out, chosen))
	asserts(c"route has corners", out.length >= 8)
	for k in range(out.length / 2 - 1): asserts(c"leg clear of the wall", mm_obstacle_segment_blocked(rects, 0, out[k * 2], out[k * 2 + 1], out[k * 2 + 2], out[k * 2 + 3]) == 0)
	# An occupied unrelated leg on the free line pushes the route off it.
	while (out.length > 0): out.pop()
	__w_list_free(cast(__w_list*, rects))
	rects = new list[int]
	segs.push(-100)
	segs.push(0)
	segs.push(400)
	segs.push(0)
	kinds.push(2)
	starts[2] = 1
	targets[2] = 1
	asserts(c"route found", mm_obstacle_route(rects, segs, kinds, starts, targets, out, chosen))
	for k in range(out.length / 2 - 1): asserts(c"no collinear overlap", mm_render_segments_overlap(out, k * 2, segs, 0) == 0)
	__w_list_free(cast(__w_list*, rects))
	__w_list_free(cast(__w_list*, segs))
	__w_list_free(cast(__w_list*, kinds))
	__w_list_free(cast(__w_list*, out))
	__w_list_free(cast(__w_list*, chosen))
	__w_list_free(cast(__w_list*, starts))
	__w_list_free(cast(__w_list*, targets))
