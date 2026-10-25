# wbuild: x64
# Graphical edits on unusual sources: CR LF line endings, tab indentation,
# trailing `%%` comments, Unicode labels and identifiers, quoted ids and a
# body without a final newline. Inserted lines must use the document's line
# ending (never a mixed file), a serialized statement must not leave a blank
# line, and every edit round-trips (save -> reopen -> SVG export) and
# undoes back to the original bytes.
import lib.testing
import libs.extras.mermaid.canvas

char* rb_crlf(char* text):
	string_builder* out = string_new()
	for i in range(strlen(text)):
		if (text[i] == 10): string_append_char(out, 13)
		string_append_char(out, text[i])
	char* result = out.data
	free(out)
	return result

# 1 when every line break is CR LF (crlf) or every one is a bare LF.
int rb_uniform(char* text, int crlf):
	for i in range(strlen(text)):
		if (text[i] == 10 && (i > 0 && text[i - 1] == 13) != crlf): return 0
	return 1

int rb_find(mm_editor* e, char* name):
	int at = mm_find_node(e.document, name)
	if (at >= 0): return at
	for i in range(e.document.nodes.length):
		if (strcmp(e.document.nodes[i].label, name) == 0): return i
	return -1

int rb_saves

void rb_round_trip(mm_editor* e, char* name, int crlf):
	asserts(name, e.document.error == 0)
	asserts(c"one line-ending style", rb_uniform(e.document.source, crlf))
	asserts(c"no blank line inserted", index_of(e.document.source, c"\n\n") < 0 && index_of(e.document.source, c"\n\r\n") < 0)
	# A fresh path per save: the editor adopts the saved path.
	rb_saves = rb_saves + 1
	string_builder* path = string_from(c"bin/mermaid_edit_robust_")
	string_append(path, name)
	string_append_char(path, '_')
	string_append_int(path, rb_saves)
	string_append(path, c".mmd")
	unlink(path.data)
	assert_equal(1, mm_editor_save_as(e, path.data))
	mm_document* reopened = mm_read_selected(path.data, e.selected)
	asserts(c"reopens", reopened != 0 && reopened.error == 0)
	assert_strings_equal(e.document.source, reopened.source)
	mm_scene* scene = mm_render(reopened)
	char* svg = mm_svg(scene)
	asserts(c"exports SVG", svg != 0 && index_of(svg, c"<svg") >= 0)
	free(svg)
	mm_scene_free(scene)
	mm_document_free(reopened)
	unlink(path.data)
	string_free(path)

void rb_undo_all(mm_editor* e, char* source):
	while (e.position > 0): assert_equal(1, mm_editor_undo(e, 0))
	assert_strings_equal(source, e.document.source)

# Rename, add, connect, label and delete in a graph family, LF then CR LF.
void rb_graph(char* name, char* lf_source, char* rename, char* from, char* removed):
	for pass in range(2):
		char* source = lf_source
		if (pass == 1): source = rb_crlf(lf_source)
		mm_editor* e = mm_editor_new(c"bin/unused.mmd", source)
		asserts(name, e.document.error == 0)
		assert_equal(1, mm_editor_set_label(e, rb_find(e, rename), c"Ünïcode label"))
		rb_round_trip(e, name, pass)
		assert_equal(1, mm_editor_add_graph_node(e, c"Nn", c"Nëw"))
		assert_equal(1, mm_editor_connect(e, from, c"Nn"))
		assert_equal(1, mm_editor_edge_label(e, e.document.edges.length - 1, c"läbel"))
		rb_round_trip(e, name, pass)
		assert_equal(1, mm_editor_move_node(e, rb_find(e, from), 320, 240))
		assert_equal(1, mm_editor_delete_node(e, rb_find(e, removed)))
		rb_round_trip(e, name, pass)
		rb_undo_all(e, source)
		mm_editor_free(e)

void test_graph_families_keep_line_endings():
	rb_graph(c"flow", c"flowchart LR\n\tsubgraph G[\"Grüppe\"] %% group\n\t\tA[Älpha] --> B\n\tend\n\tC[Gamma] %% tail\n\tB --> C\n", c"A", c"A", c"C")
	rb_graph(c"flow_no_eol", c"flowchart LR\nA --> B\nC", c"C", c"A", c"B")
	rb_graph(c"er", c"erDiagram\n\tCUSTOMER ||--o{ ORDER : places %% c\n\t\"LINE ITEM\" {\n\t\tstring name\n\t}\n", c"CUSTOMER", c"CUSTOMER", c"LINE ITEM")
	rb_graph(c"class", c"classDiagram\n\tclass Ördr[\"Order\"] %% c\n\tclass Line\n\tÖrdr --> Line\n", c"Line", c"Ördr", c"Line")
	rb_graph(c"state", c"stateDiagram-v2\n\t[*] --> Idle %% start\n\tIdle --> Busy : go\n", c"Busy", c"Idle", c"Busy")
	rb_graph(c"usecase", c"usecase-beta\n\tactor User\n\tsystemBoundary S[\"Säl\"]\n\t\tLogin(Log ïn)\n\tend\n\tUser --> Login\n", c"Login", c"User", c"Login")
	rb_graph(c"agent", c"agentflow-beta TB\n\ta[\"Ask\"] --> b[\"Böth\"] %% c\n", c"b", c"a", c"b")
	rb_graph(c"c4", c"C4Context\n\tPerson(user, \"Üser\") %% c\n\tSystem(app, \"App\")\n\tRel(user, app, \"Uses\")\n", c"user", c"user", c"app")

void test_reparent_uses_the_group_indentation():
	char* source = c"flowchart LR\n\tsubgraph G\n\t\tA\n\tend\n\tC[Gamma] %% tail\n"
	mm_editor* e = mm_editor_new(c"bin/unused.mmd", source)
	assert_equal(1, mm_editor_reparent(e, rb_find(e, c"C"), rb_find(e, c"G")))
	asserts(c"indented like the members", index_of(e.document.source, c"\t\tA\n\t\tC[Gamma]\n\tend\n") >= 0)
	rb_round_trip(e, c"reparent_indent", 0)
	rb_undo_all(e, source)
	mm_editor_free(e)

# Outline add, reorder, reparent and multi-selection moves.
void rb_outline(char* name, char* lf_source, char* a, char* b):
	for pass in range(2):
		char* source = lf_source
		if (pass == 1): source = rb_crlf(lf_source)
		mm_editor* e = mm_editor_new(c"bin/unused.mmd", source)
		asserts(name, e.document.error == 0)
		assert_equal(1, mm_outline_add(e, rb_find(e, a), c"Sïb", 1))
		assert_equal(1, mm_outline_add(e, rb_find(e, a), c"Ünder", 0))
		rb_round_trip(e, name, pass)
		assert_equal(1, mm_editor_slot_step(e, rb_find(e, a), 1))
		assert_equal(1, mm_editor_slot_move(e, rb_find(e, a), rb_find(e, b)))
		rb_round_trip(e, name, pass)
		list[int] chosen = list[int]{rb_find(e, c"Sïb"), rb_find(e, c"Ünder")}
		assert_equal(1, mm_editor_slot_move_set(e, chosen, chosen[0], rb_find(e, b)))
		__w_list_free(cast(__w_list*, chosen))
		assert_equal(1, mm_editor_set_label(e, rb_find(e, b), c"Bé"))
		assert_equal(1, mm_editor_delete_node(e, rb_find(e, c"Bé")))
		rb_round_trip(e, name, pass)
		rb_undo_all(e, source)
		mm_editor_free(e)

void test_outlines_keep_line_endings():
	rb_outline(c"mindmap", c"mindmap\n\troot((Röot))\n\t\tA\n\t%% own line\n\t\t\tA1\n\t\tB\n", c"A", c"B")
	rb_outline(c"mindmap_no_eol", c"mindmap\n  root\n    A\n    B", c"A", c"B")
	rb_outline(c"treeview", c"treeView-beta\nw/\n\tlibs/\n\t\tp.w\n\tdocs/\n", c"libs/", c"docs/")

void test_kanban_keeps_line_endings():
	for pass in range(2):
		char* source = c"kanban\n\ttodo[Todo]\n\t\tt1[Öne]@{ priority: 'High' }\n\t%% note\n\t\tt2[Two]\n\tdone[Done]"
		if (pass == 1): source = rb_crlf(source)
		mm_editor* e = mm_editor_new(c"bin/unused.mmd", source)
		asserts(c"kanban parses", e.document.error == 0)
		list[int] chosen = list[int]{rb_find(e, c"t1"), rb_find(e, c"t2")}
		assert_equal(1, mm_editor_slot_move_set(e, chosen, chosen[1], rb_find(e, c"done")))
		asserts(c"both in Done", e.document.nodes[rb_find(e, c"t1")].parent == rb_find(e, c"done") && e.document.nodes[rb_find(e, c"t2")].parent == rb_find(e, c"done"))
		rb_round_trip(e, c"kanban", pass)
		assert_equal(1, mm_outline_add(e, rb_find(e, c"todo"), c"Thrëe", 0))
		assert_equal(1, mm_editor_slot_column(e, rb_find(e, c"t1"), -1))
		rb_round_trip(e, c"kanban", pass)
		__w_list_free(cast(__w_list*, chosen))
		rb_undo_all(e, source)
		mm_editor_free(e)

void test_block_keeps_line_endings():
	for pass in range(2):
		char* source = c"block\n\tcolumns 3\n\ta[\"Ä\"] b %% row\n\tblock:g\n\t\tx\n\tend\n\td"
		if (pass == 1): source = rb_crlf(source)
		mm_editor* e = mm_editor_new(c"bin/unused.mmd", source)
		asserts(c"block parses", e.document.error == 0)
		assert_equal(1, mm_editor_slot_move(e, rb_find(e, c"g"), rb_find(e, c"d")))
		rb_round_trip(e, c"block", pass)
		assert_equal(1, mm_editor_slot_move(e, rb_find(e, c"d"), rb_find(e, c"a")))
		assert_equal(1, mm_editor_slot_step(e, rb_find(e, c"b"), 1))
		rb_round_trip(e, c"block", pass)
		list[int] chosen = list[int]{rb_find(e, c"a"), rb_find(e, c"g")}
		assert_equal(1, mm_editor_slot_move_set(e, chosen, chosen[0], rb_find(e, c"d")))
		__w_list_free(cast(__w_list*, chosen))
		assert_equal(1, mm_editor_block_span(e, rb_find(e, c"g"), 2))
		assert_equal(1, mm_editor_set_label(e, rb_find(e, c"b"), c"Bé"))
		assert_equal(1, mm_editor_delete_node(e, rb_find(e, c"g")))
		rb_round_trip(e, c"block", pass)
		rb_undo_all(e, source)
		mm_editor_free(e)
