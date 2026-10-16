# wbuild: x64
import lib.testing
import libs.extras.mermaid.parser
import libs.extras.mermaid.render

mm_document* rail_parse(char* text):
	mm_document* d = mm_parse(text, strlen(text))
	if (d.error != 0): println2(d.error)
	asserts(c"railroad parses", d.error == 0)
	return d

void rail_bad(char* text):
	mm_document* d = mm_parse(text, strlen(text))
	asserts(c"invalid grammar has diagnostic", d.error != 0)
	asserts(c"invalid grammar suppresses preview", mm_render(d) == 0)
	asserts(c"diagnostic bounded", d.error_offset >= 0 && d.error_offset <= d.length)
	mm_document_free(d)

int rail_count(mm_document* d, int kind):
	int count = 0
	for mm_rail_expr* e in d.railroad.expressions:
		if (e.kind == kind): count = count + 1
	return count

void test_rail_ebnf_trees_and_comments():
	char* source = c"railroad-ebnf-beta\ntitle \"Identifier\"\n(* ISO comment *)\nidentifier = letter (letter | digit | \"_\")* ;\nletter ::= 'a' | 'b' ; /* W3C */\ndigit = \"0\" | \"1\" ;\nsign = [\"+\"] , {\"-\"}, ? implementation-defined ? ;\n"
	mm_document* d = rail_parse(source)
	assert_equal(MM_RAIL_EBNF, d.kind)
	assert_equal(4, d.railroad.rules.length)
	assert_equal(3, rail_count(d, MM_RAIL_CHOICE))
	assert_equal(2, rail_count(d, MM_RAIL_ZERO))
	assert_equal(1, rail_count(d, MM_RAIL_OPTIONAL))
	assert_equal(1, rail_count(d, MM_RAIL_SPECIAL))
	char* copy = mm_write(d)
	assert_strings_equal(source, copy)
	free(copy)
	mm_scene* s = mm_render(d)
	mm_document_free(d)
	char* svg = mm_svg(s)
	asserts(c"title survives source disposal", index_of(svg, c">Identifier</text>") >= 0)
	asserts(c"terminal round corners", index_of(svg, c"rx=\"12\"") >= 0)
	free(svg)
	mm_scene_free(s)

void test_rail_ir_constructor_equivalence():
	mm_document* d = rail_parse(c"railroad-beta\nr = sequence(terminal(\"a\"), optional(nonterminal(\"b\")), zeroOrMore(terminal(\",\")), oneOrMore(special(\"digit\")), choice(terminal(\"x\"), terminal(\"y\")));\n")
	assert_equal(1, rail_count(d, MM_RAIL_SEQUENCE))
	assert_equal(1, rail_count(d, MM_RAIL_OPTIONAL))
	assert_equal(1, rail_count(d, MM_RAIL_ZERO))
	assert_equal(1, rail_count(d, MM_RAIL_ONE))
	mm_scene* s = mm_render(d)
	asserts(c"IR rail has display list", s.items.length > 20)
	mm_scene_free(s)
	mm_document_free(d)
	rail_bad(c"railroad-beta\nr = optional(terminal(\"a\"), terminal(\"b\"));\n")
	rail_bad(c"railroad-beta\nr = unknown(\"a\");\n")
	rail_bad(c"railroad-beta\nr = sequence();\n")

void test_rail_abnf_repeat_and_numeric_literals():
	mm_document* d = rail_parse(c"railroad-abnf-beta\n; initial comment\naddress = local-part \"@\" domain ; comment after rule\nlocal-part = 1*(ALPHA / DIGIT / \".\") ;\ndomain = 2*4ALPHA *DIGIT 3\"x\" ;\ndigit = %x30-39 / %d65.66 / %b1000001 ;\n")
	assert_equal(MM_RAIL_ABNF, d.kind)
	assert_equal(4, rail_count(d, MM_RAIL_REPEAT))
	assert_equal(3, rail_count(d, MM_RAIL_NUMERIC))
	int range = 0
	for mm_rail_expr* e in d.railroad.expressions:
		if (e.kind == MM_RAIL_REPEAT && e.minimum == 2 && e.maximum == 4): range = 1
	asserts(c"ABNF bounded repeat retained", range)
	mm_scene* s = mm_render(d)
	char* svg = mm_svg(s)
	asserts(c"bounded repeat annotation", index_of(svg, c"2..4 repetitions") >= 0)
	asserts(c"case-insensitive semantics visible", index_of(svg, c"case-insensitive") >= 0)
	free(svg)
	mm_scene_free(s)
	mm_document_free(d)
	rail_bad(c"railroad-abnf-beta\nr = 4*2A ;\n")
	rail_bad(c"railroad-abnf-beta\nr = %x39-30 ;\n")
	rail_bad(c"railroad-abnf-beta\nr = %x110000 ;\n")
	rail_bad(c"railroad-abnf-beta\nr = %b2 ;\n")

void test_rail_peg_ordered_choice_and_predicates():
	mm_document* d = rail_parse(c"railroad-peg-beta\n# leading comment\nIdentifier <- !Keyword &Letter Letter Letter* ;\nKeyword <- \"if\" / \"else\" ;\nLetter <- \"a\" / . ;\n")
	assert_equal(MM_RAIL_PEG, d.kind)
	assert_equal(1, rail_count(d, MM_RAIL_NOT))
	assert_equal(1, rail_count(d, MM_RAIL_AND))
	mm_scene* s = mm_render(d)
	char* svg = mm_svg(s)
	asserts(c"predicates distinguished from consumption", index_of(svg, c"no consumption") >= 0)
	asserts(c"ordered alternatives numbered", index_of(svg, c">2</text>") >= 0)
	asserts(c"wildcard visible", index_of(svg, c">any character</text>") >= 0)
	free(svg)
	mm_scene_free(s)
	mm_document_free(d)
	rail_bad(c"railroad-peg-beta\nr = \"a\" ;\n")
	rail_bad(c"railroad-peg-beta\nr <- \"a\" | \"b\" ;\n")

void test_rail_geometry_bypasses_loops_and_zero_count():
	mm_document* d = rail_parse(c"railroad-abnf-beta\nr = 0\"never\" 0*1A 1*B ;\n")
	mm_scene* s = mm_render(d)
	char* svg = mm_svg(s)
	asserts(c"zero repetition is empty", index_of(svg, c"0 repetitions (empty)") >= 0)
	asserts(c"zero body not falsely drawn", index_of(svg, c"never") < 0)
	int backwards = 0
	for mm_primitive* p in s.items:
		if (p.kind == MM_LINE && p.x > p.x2 && p.x - p.x2 == 6): backwards = backwards + 1
	asserts(c"repetition loop points backwards", backwards > 0)
	free(svg)
	mm_scene_free(s)
	mm_document_free(d)

void test_rail_errors_limits_and_escaping():
	rail_bad(c"railroad-ebnf-beta\nr = \"a\"\n")
	rail_bad(c"railroad-ebnf-beta\nr = \"a\";\nr = \"b\";\n")
	rail_bad(c"railroad-ebnf-beta\nr = A - B;\n")
	rail_bad(c"railroad-ebnf-beta\n/* missing\n")
	rail_bad(c"railroad-ebnf-beta\n")
	string_builder* text = string_from(c"railroad-ebnf-beta\nr = ")
	for i in range(40): string_append_char(text, '(')
	string_append(text, c"\"x\"")
	for i in range(40): string_append_char(text, ')')
	string_append_char(text, ';')
	rail_bad(text.data)
	string_free(text)
	text = string_from(c"railroad-ebnf-beta\nr = ")
	for i in range(1100): string_append(text, c"\"x\" ")
	string_append_char(text, ';')
	rail_bad(text.data)
	string_free(text)
	mm_document* d = rail_parse(c"railroad-ebnf-beta\nr = \"<&>\" ;\n")
	mm_scene* s = mm_render(d)
	char* svg = mm_svg(s)
	asserts(c"grammar terminal escaped", index_of(svg, c"&lt;&amp;&gt;") >= 0)
	free(svg)
	mm_scene_free(s)
	mm_document_free(d)

void test_rail_truncated_prefixes_and_source_edits():
	list[char*] sources = list[char*]{c"railroad-beta\nr = sequence(terminal(\"a\"),optional(nonterminal(\"b\")));\n", c"railroad-ebnf-beta\nr = (\"a\" | 'b')+ [C] {D};\n", c"railroad-abnf-beta\nr = 2*4(A / %x30-39) ;\n", c"railroad-peg-beta\nr <- !A (\"b\" / .)*;\n"}
	for char* source in sources:
		for length in range(strlen(source) + 1):
			mm_document* d = mm_parse(source, length)
			mm_scene* s = mm_render(d)
			if (d.error != 0): asserts(c"invalid prefix has no scene", s == 0)
			else: asserts(c"valid prefix renders", s != 0)
			mm_scene_free(s)
			mm_document_free(d)
		mm_document* d = rail_parse(source)
		mm_document* edited = mm_edit(d, d.length, d.length, c"\n%% comment\n", 12)
		asserts(c"railroad source edit", edited != 0 && edited.error == 0)
		assert_strings_equal(source, d.source)
		mm_document_free(edited)
		mm_document_free(d)
	__w_list_free(cast(__w_list*, sources))

void test_railroad_document_metadata_and_title_precedence():
	char* text = c"---\ntitle: Grammar overview\n---\nrailroad-beta\ntitle Internal title\naccTitle: Accessible grammar\nword = terminal(\"yes\");\n"
	mm_document* d = mm_parse(text, strlen(text))
	asserts(c"railroad envelope parses", d.error == 0)
	mm_scene* s = mm_render(d)
	int titles = 0
	for mm_primitive* p in s.items:
		if (p.kind == MM_TEXT && strcmp(p.text, c"Grammar overview") == 0): titles = titles + 1
		asserts(c"frontmatter title takes precedence", strcmp(p.text, c"Internal title") != 0)
	assert_equal(1, titles)
	char* svg = mm_svg(s)
	asserts(c"accessible title exported", index_of(svg, c"Accessible grammar") >= 0)
	free(svg)
	mm_scene_free(s)
	mm_document_free(d)
