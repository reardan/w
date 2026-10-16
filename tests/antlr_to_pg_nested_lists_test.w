# wbuild: target=antlr_to_pg_nested_lists_test tag=tests dep=antlr_to_pg
# wbuild: step="bin/wv2 tests/antlr_to_pg_nested_lists_test.w -o bin/antlr_to_pg_nested_lists_test"
# wbuild: step="bin/antlr_to_pg_nested_lists_test"
# wbuild: step="bin/antlr_to_pg --strict tests/grammars/antlr_nested_lists/nested.g4 -o bin/antlr_nested_lists.pg --parser-name nested_lists --matchers bin/antlr_nested_lists_matchers.w"
# wbuild: step="bin/parser_generator_grammars bin/antlr_nested_lists.pg -o bin/antlr_nested_lists_parser.w"
# wbuild: step="bin/antlr_to_pg --strict tests/grammars/antlr_nested_lists/empty.g4 -o bin/antlr_empty_lists.pg --parser-name empty_lists --matchers bin/antlr_empty_lists_matchers.w"
# wbuild: step="bin/parser_generator_grammars bin/antlr_empty_lists.pg -o bin/antlr_empty_lists_parser.w"
# wbuild: step="bin/wv2 tests/grammars/antlr_nested_lists/runtime.w -o bin/antlr_nested_lists_runtime"
# wbuild: step="bin/antlr_nested_lists_runtime"
import bin.generated_antlr4_parser
import lib.assert
import libs.extras.grammars.antlr_to_pg.ast
import libs.extras.grammars.antlr_to_pg.normalize_lists
import libs.extras.grammars.antlr_to_pg.classify
import libs.extras.grammars.antlr_to_pg.matchers_emit


list[at_rule*] nested_list_rules(char* source):
	g_seen_rule_names = new map[char*, int]
	g_report_lines = new list[char*]
	g_parser_refs = new map[char*, int]
	g_fragments = new map[char*, at_rule*]
	g_lexer_rules = new map[char*, at_rule*]
	g_at_dependencies = new list[at_site*]
	g_at_declared_modes = new list[char*]
	g_at_source = source
	pg_diagnostics* diagnostics = pg_diagnostics_new()
	pg_ast_node* root = antlr4_parse(source, c"nested_lists.g4", diagnostics)
	assert1(root != 0)
	assert_equal(0, pg_diagnostics_count(diagnostics))
	list[at_rule*] rules = at_collect_rules(root)
	at_audit_prepare_rules(rules)
	return rules


void nested_list_refused(char* source):
	list[at_rule*] rules = nested_list_rules(source)
	list[at_alt*] original = rules[0].alts
	assert_equal(0, at_normalize_parser_list(rules[0]))
	assert1(original == rules[0].alts)
	assert_equal(1, at_audit(rules))


void nested_list_allowed(char* source):
	list[at_rule*] rules = nested_list_rules(source)
	assert_equal(1, at_normalize_parser_list(rules[0]))
	assert_equal(0, at_audit(rules))
	assert_equal(0, g_at_semantic_losses)
	assert_equal(0, at_normalize_parser_list(rules[0]))


int main():
	nested_list_allowed(c"grammar G; a: a '+' term | term; term: ID | paren; paren: '(' other ')'; other: a; ID: [a-z]+;")
	nested_list_allowed(c"grammar G; a: a '(' a ')' | 'x';")
	nested_list_allowed(c"grammar G; a: a term |; term: 'x' | '(' a ')';")
	nested_list_refused(c"grammar G; a: a 'x' | 'y'?;")
	nested_list_refused(c"grammar G; a: a 'x' 'y' | 'x'?;")
	# Ordered base choices must not let epsilon hide another base.
	nested_list_refused(c"grammar G; a: a 'x' | | 'y';")
	nested_list_refused(c"grammar G; a: a 'x' | 'y'? | 'z'?;")
	nested_list_refused(c"grammar G; a: a 'x' | 'y' |; ")
	# Indirect un-delimited operands would need expression precedence analysis.
	nested_list_refused(c"grammar G; a: a '+' term | 'x'; term: a | 'y';")
	nested_list_refused(c"grammar G; a: a '+' term | 'x'; term: '+' a;")
	nested_list_refused(c"grammar G; a: a '+' a | 'x';")
	nested_list_refused(c"grammar G; a: a '?' a ':' a | 'x';")
	# Both surrounding delimiters must consume and match.
	nested_list_refused(c"grammar G; a: a LP a RP | 'x'; LP: '(' -> skip; RP: ')';")
	nested_list_refused(c"grammar G; a: a LP a RP | 'x'; LP: '(' {action();}; RP: ')';")
	nested_list_refused(c"grammar G; a: a '+' term | 'x'; term: '('? a ')';")
	nested_list_refused(c"grammar G; a: a '+' term | 'x'; term: '(' a ')' ?;")
	nested_list_refused(c"grammar G; a: a '+' term | 'x'; term: '(' a ']';")
	nested_list_refused(c"grammar G; a: a empty |; empty: 'x'?;")
	nested_list_refused(c"grammar G; a: a EOF |;")
	nested_list_refused(c"grammar G; a: a 'x';")
	nested_list_refused(c"grammar G; a: other | 'x'; other: a 'y';")
	nested_list_refused(c"grammar G; a: a '(' a ')' # More | 'x' # Base;")
	nested_list_refused(c"grammar G; a: a {action();} '(' a ')' | 'x';")
	nested_list_refused(c"grammar G; a: previous=a '(' a ')' | 'x';")
	# A safe outer pair does not excuse a separate left cycle in the grammar.
	list[at_rule*] rules = nested_list_rules(c"grammar G; a: a '(' other ')' | 'x'; other: other | a;")
	assert_equal(1, at_normalize_parser_list(rules[0]))
	assert_equal(1, at_audit(rules))
	println(c"antlr delimiter-contained and nullable-base list normalization passed")
	return 0
