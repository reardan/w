# wbuild: target=antlr_to_pg_safety_test tag=tests dep=antlr_to_pg
# wbuild: step="bin/wv2 tests/antlr_to_pg_safety_test.w -o bin/antlr_to_pg_safety_test"
# wbuild: step="bin/antlr_to_pg_safety_test"
# wbuild: step="bin/wv2 tests/grammars/antlr_safety/matchers_runtime.w -o bin/antlr_safety_matchers_runtime"
# wbuild: step="bin/antlr_safety_matchers_runtime"
# wbuild: step="bin/antlr_to_pg tests/grammars/antlr_safety/lists.g4 -o bin/antlr_safety_lists.pg --parser-name safety_lists --matchers bin/antlr_safety_lists_matchers.w"
# wbuild: step="bin/parser_generator_grammars bin/antlr_safety_lists.pg -o bin/antlr_safety_lists_parser.w"
# wbuild: step="bin/antlr_to_pg --strict tests/grammars/antlr_safety/nullable.g4 -o bin/antlr_safety_nullable.pg --parser-name safety_nullable --matchers bin/antlr_safety_nullable_matchers.w"
# wbuild: step="bin/parser_generator_grammars bin/antlr_safety_nullable.pg -o bin/antlr_safety_nullable_parser.w"
# wbuild: step="bin/wv2 tests/grammars/antlr_safety/lists_runtime.w -o bin/antlr_safety_lists_runtime"
# wbuild: step="bin/antlr_safety_lists_runtime"
# wbuild: step="bin/antlr_to_pg --strict --stateful tests/grammars/antlr_safety/precedence.g4 -o bin/antlr_safety_precedence.pg --parser-name safety_precedence --matchers bin/antlr_safety_precedence_matchers.w"
# wbuild: step="bin/parser_generator_grammars bin/antlr_safety_precedence.pg -o bin/antlr_safety_precedence_parser.w"
# wbuild: step="bin/wv2 tests/grammars/antlr_safety/precedence_runtime.w -o bin/antlr_safety_precedence_runtime"
# wbuild: step="bin/antlr_safety_precedence_runtime"
# wbuild: step="sh tests/grammars/antlr_safety/check.sh"
import bin.generated_antlr4_parser
import lib.assert
import libs.extras.grammars.antlr_to_pg.ast
import libs.extras.grammars.antlr_to_pg.audit
import libs.extras.grammars.antlr_to_pg.normalize
import libs.extras.grammars.antlr_to_pg.classify
import libs.extras.grammars.antlr_to_pg.matchers_analyze
import libs.extras.grammars.antlr_to_pg.matchers_emit


list[at_rule*] safety_rules(char* source):
	g_seen_rule_names = new map[char*, int]
	g_report_lines = new list[char*]
	g_parser_refs = new map[char*, int]
	g_fragments = new map[char*, at_rule*]
	g_lexer_rules = new map[char*, at_rule*]
	g_at_dependencies = new list[at_site*]
	g_at_declared_modes = new list[char*]
	g_at_source = source
	pg_diagnostics* diagnostics = pg_diagnostics_new()
	pg_ast_node* root = antlr4_parse(source, c"safety.g4", diagnostics)
	assert1(root != 0)
	assert_equal(0, pg_diagnostics_count(diagnostics))
	list[at_rule*] rules = at_collect_rules(root)
	for at_rule* rule in rules:
		if (rule.is_lexer): g_lexer_rules[rule.name] = rule
		if (rule.is_fragment): g_fragments[rule.name] = rule
	return rules


void safety_audit(char* source, int unsafe):
	list[at_rule*] rules = safety_rules(source)
	assert_equal(unsafe, at_audit(rules))


void safety_refuse_rewrite(char* source):
	list[at_rule*] rules = safety_rules(source)
	assert_equal(0, at_unroll_right_recursion(rules[0]))
	g_frag_generating = new map[char*, int]
	assert1(at_refuse_reason_rule(rules[0]) != 0)


void safety_parser_refused(char* source):
	list[at_rule*] rules = safety_rules(source)
	assert_equal(0, at_normalize_parser_lists(rules))
	assert_equal(1, at_audit(rules))


int main():
	# Nullable fragments can succeed without consuming. Actual tokens and
	# repeated bodies must still consume, including transitive references.
	safety_audit(c"grammar Safe; root: A EOF; A: 'a' Optional; fragment Optional: Other; fragment Other: 'b'?;", 0)
	safety_audit(c"grammar Safe; root: A EOF; A: 'a' Optional; fragment Optional: 'b' |;", 0)
	safety_audit(c"grammar Bad; root: A EOF; A: Optional; fragment Optional: 'b'?;", 1)
	safety_audit(c"grammar Bad; root: A EOF; A: 'a' Optional*; fragment Optional: 'b'?;", 1)
	safety_audit(c"grammar Bad; root: A EOF; A: 'a' Optional+; fragment Optional: 'b' |;", 1)
	safety_audit(c"grammar Bad; root: empty other | 'x'; empty: ; other: root;", 1)
	safety_audit(c"grammar Bad; root: EOF*;", 1)
	safety_audit(c"grammar Bad; root: A EOF; A: EOF;", 1)

	# No productive base case means no finite token, not PREFIX+.
	safety_refuse_rewrite(c"lexer grammar Bad; X: 'a' X;")
	safety_refuse_rewrite(c"lexer grammar Bad; X: 'a' | 'a' X;")
	safety_refuse_rewrite(c"lexer grammar Bad; X: 'ab' | 'a' X;")
	safety_refuse_rewrite(c"lexer grammar Bad; X: [0-9]+ | ('+' | [0-5]) X;")
	safety_refuse_rewrite(c"lexer grammar Bad; X: [0-9]+ | '+'? [0-5] X;")
	safety_refuse_rewrite(c"lexer grammar Bad; X: [0-9]+ | Start X; fragment Start: '+'? ([0-5] | '-');")
	list[at_rule*] unknown = safety_rules(c"lexer grammar Bad; X: [0-9]+ | [\\p{L}] X;")
	assert_equal(0, at_unroll_right_recursion(unknown[0]))
	unknown = safety_rules(c"lexer grammar Bad; X: [0-9]+ | [\\u0030] X;")
	assert_equal(0, at_unroll_right_recursion(unknown[0]))
	unknown = safety_rules(c"lexer grammar Bad; X: [0-9]+ | [\\q] X;")
	assert_equal(0, at_unroll_right_recursion(unknown[0]))
	# The closing suffix belongs to every recursive invocation.
	safety_refuse_rewrite(c"lexer grammar Bad; X: 'a' ('b' X)? 'c';")
	safety_refuse_rewrite(c"lexer grammar Bad; X: 'a' ('b' X)* 'c';")
	list[at_rule*] rules = safety_rules(c"lexer grammar Bad; X: 'a'? X?;")
	assert_equal(0, at_unroll_right_recursion(rules[0]))
	rules = safety_rules(c"lexer grammar Bad; X: 'a' {predicate()}? X?;")
	assert_equal(0, at_unroll_right_recursion(rules[0]))

	# List/postfix normalization must not guess expression precedence or
	# discard annotations. Indirect and nullable cycles stay rejected.
	rules = safety_rules(c"grammar Lists; root: root ',' 'a' | 'a';")
	assert_equal(1, at_normalize_parser_lists(rules))
	assert_equal(0, at_audit(rules))
	assert_equal(0, at_normalize_parser_lists(rules))
	safety_parser_refused(c"grammar Expr; root: root '?' root ':' root | 'a';")
	safety_parser_refused(c"grammar Expr; root: root '+' operand | 'a'; operand: '(' root ')';")
	safety_parser_refused(c"grammar Expr; root: <assoc=sideways> root '^' root | 'a';")
	safety_parser_refused(c"grammar Label; root: root ',' 'a' # More | 'a' # Base;")
	safety_parser_refused(c"grammar Action; root: root {act();} ',' 'a' | 'a';")
	safety_parser_refused(c"grammar Label; root: previous=root ',' 'a' | 'a';")
	safety_parser_refused(c"grammar Empty; root: root empty | 'a'; empty: ;")
	safety_parser_refused(c"grammar Empty; root: root EOF | 'a';")
	safety_parser_refused(c"grammar Cycle; root: other | 'a'; other: root ',' 'a';")
	safety_parser_refused(c"grammar NoBase; root: root ',' 'a';")

	rules = safety_rules(c"grammar Expr; root: root '+' root | 'a';")
	assert_equal(1, at_normalize_parser_lists(rules))
	assert_equal(0, at_audit(rules))
	rules = safety_rules(c"grammar Expr; root: <assoc=right> root '^' root | 'a';")
	assert_equal(1, at_normalize_parser_lists(rules))
	assert_equal(0, at_audit(rules))
	rules = safety_rules(c"grammar Expr; root: <assoc = left> root '+' root | 'a'; root_prec0: 'z';")
	assert_equal(1, at_normalize_parser_lists(rules))
	assert_equal(0, at_audit(rules))
	assert_strings_equal(c"root_prec0_", rules[0].alts[0].elements[0].text)
	safety_parser_refused(c"grammar Expr; root: root '+' root | '-' root | 'a';")
	safety_parser_refused(c"grammar Expr; root: root '+' root | root '+' root | 'a';")
	safety_parser_refused(c"grammar Expr; root: root '+' root # Plus | 'a' # Atom;")
	safety_parser_refused(c"grammar Expr; root: root '+' {allowed()}? root | 'a';")
	safety_parser_refused(c"grammar Expr; root: <assoc=right> root '+' root | '(' root ')' ;")

	# Compile and execute generated matchers in the next target step.
	rules = safety_rules(c"lexer grammar Runtime; A: 'a' Optional; fragment Optional: Other; fragment Other: 'b' |; B: 'q' B?; C: 'a' ('b' C)?; D: 'a' ('b' D)*; E: 'z' | 'x' E; F: 'z' | F 'x'; G: DIGIT+ ('.' DIGIT*)? | ('+' | '-') G; fragment DIGIT: [0-9];")
	g_matchers_out = string_new()
	g_generated_frags = new map[char*, int]
	g_frag_generating = new map[char*, int]
	g_matcher_tmp = 0
	g_matcher_parser_prefix = c"safety"
	g_at_stateful = 1
	for at_rule* rule in rules:
		if (rule.is_fragment == 0): assert1(at_try_generate_matcher(rule) != 0)
	assert1(file_write_text(c"bin/antlr_safety_matchers.w", g_matchers_out.data))
	println(c"antlr structural safety and recursive matcher generation passed")
	return 0
