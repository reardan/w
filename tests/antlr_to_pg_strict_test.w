# wbuild: target=antlr_to_pg_strict_test tag=tests dep=antlr_to_pg
# wbuild: step="bin/wv2 tests/antlr_to_pg_strict_test.w -o bin/antlr_to_pg_strict_test"
# wbuild: step="bin/antlr_to_pg_strict_test"
# wbuild: step="sh libs/extras/grammars/antlr_to_pg/testdata/strict/check.sh"
import bin.generated_pg_parser
import lib.assert
import lib.sha256
import libs.extras.grammars.antlr_to_pg.ast
import libs.extras.grammars.antlr_to_pg.audit
import libs.extras.grammars.antlr_to_pg.classify

list[at_rule*] strict_test_rules(char* source):
	g_seen_rule_names = new map[char*, int]
	g_report_lines = new list[char*]
	g_parser_refs = new map[char*, int]
	g_fragments = new map[char*, at_rule*]
	g_at_dependencies = new list[at_site*]
	g_at_source = source
	pg_diagnostics* diagnostics = pg_diagnostics_new()
	pg_ast_node* root = antlr4_parse(source, c"semantic-fixture.g4", diagnostics)
	pg_diagnostics_print(diagnostics)
	assert1(root != 0)
	assert_equal(0, pg_diagnostics_count(diagnostics))
	return at_collect_rules(root)


void strict_test_pin(char* path, char* expected):
	char* source = file_read_text(path)
	assert1(source != 0)
	char* digest = cast(char*, malloc(32))
	sha256(source, strlen(source), digest)
	char* digits = c"0123456789abcdef"
	char* actual = cast(char*, malloc(65))
	int i = 0
	while (i < 32):
		int b = digest[i] & 255
		actual[i * 2] = digits[(b >> 4) & 15]
		actual[i * 2 + 1] = digits[b & 15]
		i = i + 1
	actual[64] = 0
	assert_strings_equal(expected, actual)
	free(source)
	free(digest)
	free(actual)


void strict_test_pg(char* path):
	char* source = file_read_text(path)
	assert1(source != 0)
	pg_diagnostics* diagnostics = pg_diagnostics_new()
	pg_ast_node* root = pg_parse(source, path, diagnostics)
	pg_diagnostics_print(diagnostics)
	assert1(root != 0)
	assert_equal(0, pg_diagnostics_count(diagnostics))


int main():
	strict_test_pg(c"tests/parser_generator/stateful_sample.pg")
	strict_test_pg(c"tests/parser_generator/ast_predicate.pg")
	strict_test_pg(c"libs/extras/grammars/javascript.pg")
	strict_test_pin(c"libs/extras/grammars/antlr_to_pg/testdata/antlr/javascript/JavaScriptLexer.g4", c"bddbd846633b6d6ef2b5de205cd3a639a72d3f01ec3254c720e10f9a96099278")
	strict_test_pin(c"libs/extras/grammars/antlr_to_pg/testdata/antlr/javascript/JavaScriptParser.g4", c"c50664be00277d48c8a06d1ceabe4f6d46a04284a5e17eb287628727a95efca4")
	strict_test_pin(c"libs/extras/grammars/antlr_to_pg/testdata/antlr/javascript/Java/JavaScriptLexerBase.java", c"f1709c70305c0f7c37c1db68c356d3a19f720af27c90e4371423a9ec5874547b")
	strict_test_pin(c"libs/extras/grammars/antlr_to_pg/testdata/antlr/javascript/Java/JavaScriptParserBase.java", c"2e8c5fa857bc5b4e49894b7516d8d7204adf0152612c57a5181672b52ab685c8")
	strict_test_pin(c"libs/extras/grammars/antlr_to_pg/testdata/antlr/javascript/UPSTREAM_README.md", c"b89ae2d33934ae415d575c3faaafb0c38d571f06ae414dc9d209cb6d0a851c39")
	char* source = c"grammar Proof; options {tokenVocab=Other; superClass=Base;} @header { /* } */ const x = \"{\"; } root: <assoc=right> A {yes()}? B {act();} # Right; A: 'a'; mode TEMPLATE; B: 'b' -> type(A), popMode; C: .+?;"
	list[at_rule*] rules = strict_test_rules(source)
	assert_equal(4, rules.length)
	assert_equal(3, g_at_dependencies.length)
	at_rule* root = rules[0]
	at_alt* alt = root.alts[0]
	assert_equal(2, alt.elements.length)
	assert_equal(3, alt.sites.length)
	assert_strings_equal(c"<assoc=right>", alt.sites[0].raw)
	assert_strings_equal(c"predicate", alt.sites[1].kind)
	assert_strings_equal(c"{yes()}?", alt.sites[1].raw)
	assert_equal(1, alt.sites[1].position)
	assert_equal(2, alt.sites[2].position)
	assert_strings_equal(c"Right", alt.label)
	assert1(alt.sites[1].first.offset > root.first.offset)
	at_rule* b = rules[2]
	assert_strings_equal(c"TEMPLATE", b.mode)
	assert_equal(2, b.commands.length)
	assert_strings_equal(c"type", b.commands[0].name)
	assert_strings_equal(c"A", b.commands[0].argument)
	assert_strings_equal(c"popMode", b.commands[1].name)
	assert1(b.commands[1].argument == 0)
	assert1(rules[3].alts[0].elements[0].nongreedy)
	assert_equal(0, at_audit(rules))
	assert1(g_at_semantic_losses >= 9)

	# Nullable-prefix indirect left recursion must terminate the audit.
	rules = strict_test_rules(c"grammar Cycle; root: empty other | 'x'; empty: ; other: root;")
	assert_equal(1, at_audit(rules))
	assert_equal(2, g_at_semantic_losses)
	rules = strict_test_rules(c"grammar Repeat; root: empty* EOF; empty: ;")
	assert_equal(1, at_audit(rules))
	assert_equal(1, g_at_semantic_losses)

	rules = strict_test_rules(c"grammar RepeatedEOF; root: EOF*;")
	assert_equal(1, at_audit(rules))
	assert_equal(1, g_at_semantic_losses)

	# Exact action scanning: quoted braces, escaped quotes, comments, nesting.
	assert_equal(22, pg_lexer_matcher_brace_block(c"{ /* } */ \"{\"; {x;} }?", 0))
	assert_equal(0, pg_lexer_matcher_bracket_charset(c"[unterminated", 0))
	assert_equal(0, pg_lexer_matcher_brace_block(c"{ unterminated", 0))
	assert_equal(0, pg_lexer_matcher_brace_block(c"{ /* unterminated }", 0))
	rules = strict_test_rules(c"grammar Plain; root: A EOF; A: 'a';")
	assert_equal(0, at_audit(rules))
	assert_equal(0, g_at_semantic_losses)
	at_audit_lexer_contract(rules)
	assert_equal(1, g_at_semantic_losses)
	assert_contains(g_at_loss_lines[0], c"implicit space/tab/CR/LF")
	rules = strict_test_rules(c"grammar Trivia; root: A EOF; A: 'a'; WS: [ \t\r\n]+ -> skip;")
	assert_equal(0, at_audit(rules))
	at_audit_lexer_contract(rules)
	assert_equal(0, g_at_semantic_losses)
	rules = strict_test_rules(c"grammar Priority; root: WORD KEY EOF; WORD: [a-z]+; KEY: 'key'; WS: [ \t\r\n]+ -> skip;")
	assert_equal(0, at_audit(rules))
	at_audit_lexer_contract(rules)
	assert_equal(1, g_at_semantic_losses)
	assert_contains(g_at_loss_lines[0], c"literal priority")
	println(c"antlr semantic preservation and strict audit tests passed")
	return 0
