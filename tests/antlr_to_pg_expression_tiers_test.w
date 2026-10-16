# wbuild: target=antlr_to_pg_expression_tiers_test tag=tests dep=antlr_to_pg
# wbuild: step="bin/wv2 tests/antlr_to_pg_expression_tiers_test.w -o bin/antlr_to_pg_expression_tiers_test"
# wbuild: step="bin/antlr_to_pg_expression_tiers_test"
# wbuild: step="bin/antlr_to_pg --strict --stateful tests/grammars/antlr_expression_tiers/tiers.g4 -o bin/antlr_expression_tiers.pg --parser-name expression_tiers --matchers bin/antlr_expression_tiers_matchers.w"
# wbuild: step="bin/parser_generator_grammars bin/antlr_expression_tiers.pg -o bin/antlr_expression_tiers_parser.w"
# wbuild: step="bin/wv2 tests/grammars/antlr_expression_tiers/runtime.w -o bin/antlr_expression_tiers_runtime"
# wbuild: step="bin/antlr_expression_tiers_runtime"
import bin.generated_antlr4_parser
import lib.assert
import libs.extras.grammars.antlr_to_pg.ast
import libs.extras.grammars.antlr_to_pg.normalize
import libs.extras.grammars.antlr_to_pg.classify
import libs.extras.grammars.antlr_to_pg.matchers_emit


list[at_rule*] tiers_rules(char* source):
	g_seen_rule_names = new map[char*, int]
	g_report_lines = new list[char*]
	g_parser_refs = new map[char*, int]
	g_fragments = new map[char*, at_rule*]
	g_lexer_rules = new map[char*, at_rule*]
	g_at_dependencies = new list[at_site*]
	g_at_declared_modes = new list[char*]
	g_at_source = source
	pg_diagnostics* diagnostics = pg_diagnostics_new()
	pg_ast_node* root = antlr4_parse(source, c"tiers.g4", diagnostics)
	assert1(root != 0)
	assert_equal(0, pg_diagnostics_count(diagnostics))
	list[at_rule*] rules = at_collect_rules(root)
	at_audit_prepare_rules(rules)
	return rules


void tiers_refused(char* source):
	list[at_rule*] rules = tiers_rules(source)
	list[at_alt*] before = rules[0].alts
	int count = rules.length
	assert_equal(0, at_normalize_expression(rules[0], rules))
	assert_equal(count, rules.length)
	assert1(before == rules[0].alts)


void tiers_allowed(char* source):
	list[at_rule*] rules = tiers_rules(source)
	assert_equal(1, at_normalize_expression(rules[0], rules))
	assert_equal(0, at_audit(rules))
	assert_equal(0, g_at_semantic_losses)


int main():
	tiers_allowed(c"grammar G; e: e '[' e ']' | e '.' 'x' | e '+' e | '(' e ')' | '1';")
	tiers_allowed(c"grammar G; e: e '+' e | 'forall' 'x' ':' e | '1';")
	tiers_allowed(c"grammar G; e: e '+' e | body; body: 'fn' e 'end' | '1';")
	tiers_allowed(c"grammar G; e: e '+' e | '[' e ',' e ']' | '1';")
	# Suffix tiers must be higher than every binary tier and cannot straddle
	# a prefix binding point. Their choices must have disjoint FIRST sets.
	tiers_refused(c"grammar G; e: e '+' e | e '!' | '1';")
	tiers_refused(c"grammar G; e: e '!' | '-' e | e '?' | e '+' e | '1';")
	tiers_refused(c"grammar G; e: e '.' 'x' | e '.' 'x' '(' e ')' | e '+' e | '1';")
	tiers_refused(c"grammar G; e: e '+' | e '+' e | '1';")
	tiers_refused(c"grammar G; e: e '!'? | e '+' e | '1';")
	tiers_refused(c"grammar G; e: e '?' e ':' e | e '+' e | '1';")
	tiers_refused(c"grammar G; e: e '+' indirect | e '*' e | '1'; indirect: e;")
	tiers_refused(c"grammar G; e: e '+' e | '-' NUMBER? e | NUMBER; NUMBER: [0-9]+;")
	tiers_refused(c"grammar G; e: e '+' e | prefix e | NUMBER; prefix: '-' NUMBER?; NUMBER: [0-9]+;")
	tiers_refused(c"grammar G; e: e '+' e | '-' ':'? ':' e | '1';")
	tiers_refused(c"grammar G; e: e '+' e | prefix ':' e | '1'; prefix: '-' ':'*;")
	tiers_refused(c"grammar G; e: e '+' e | prefix e | '1'; prefix: '-' | '-' ':';")
	# Indirect bases can consume before re-entering at full precedence, but
	# nullable-prefix cycles, unproductive recursion and overlap stay refused.
	tiers_refused(c"grammar G; e: e '+' e | indirect; indirect: e | '1';")
	tiers_refused(c"grammar G; e: e '+' e | '(' e ')';")
	tiers_refused(c"grammar G; e: e '+' e | body; body: 'fn' e 'end';")
	tiers_refused(c"grammar G; e: e '+' e | short | long; short: '(' e ')'; long: '(' e ')' 'x' | '1';")
	tiers_refused(c"grammar G; e: e '+' e | '!'? e | '1';")
	tiers_refused(c"grammar G; e: e '+' e | '(' e ')' e | '1';")
	tiers_refused(c"grammar G; e: e '+' e | 'forall' 'x' ':' e | 'forall' 'x';")
	tiers_refused(c"grammar G; e: e '(' e ')' # Call | e '+' e # Add | '1' # Number;")
	tiers_refused(c"grammar G; e: e '(' {act();} e ')' | e '+' e | '1';")
	tiers_refused(c"grammar G; e: e '+' e | 'forall' value='x' ':' e | '1';")
	println(c"antlr mixed expression tier safety and refusal atomicity passed")
	return 0
