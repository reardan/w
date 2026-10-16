# wbuild: target=antlr_to_pg_operators_test tag=tests dep=antlr_to_pg
# wbuild: step="bin/wv2 tests/antlr_to_pg_operators_test.w -o bin/antlr_to_pg_operators_test"
# wbuild: step="bin/antlr_to_pg_operators_test"
# wbuild: step="bin/antlr_to_pg --strict --stateful tests/grammars/antlr_operators/operators.g4 -o bin/antlr_operators.pg --parser-name operators --matchers bin/antlr_operators_matchers.w"
# wbuild: step="bin/parser_generator_grammars bin/antlr_operators.pg -o bin/antlr_operators_parser.w"
# wbuild: step="bin/wv2 tests/grammars/antlr_operators/runtime.w -o bin/antlr_operators_runtime"
# wbuild: step="bin/antlr_operators_runtime"
import bin.generated_antlr4_parser
import lib.assert
import libs.extras.grammars.antlr_to_pg.ast
import libs.extras.grammars.antlr_to_pg.audit
import libs.extras.grammars.antlr_to_pg.normalize
import libs.extras.grammars.antlr_to_pg.classify
import libs.extras.grammars.antlr_to_pg.matchers_analyze
import libs.extras.grammars.antlr_to_pg.matchers_emit


list[at_rule*] operator_rules(char* source):
	g_seen_rule_names = new map[char*, int]
	g_report_lines = new list[char*]
	g_parser_refs = new map[char*, int]
	g_fragments = new map[char*, at_rule*]
	g_lexer_rules = new map[char*, at_rule*]
	g_at_dependencies = new list[at_site*]
	g_at_declared_modes = new list[char*]
	g_at_source = source
	pg_diagnostics* diagnostics = pg_diagnostics_new()
	pg_ast_node* root = antlr4_parse(source, c"operators.g4", diagnostics)
	assert1(root != 0)
	assert_equal(0, pg_diagnostics_count(diagnostics))
	list[at_rule*] rules = at_collect_rules(root)
	for at_rule* rule in rules:
		if (rule.is_lexer): g_lexer_rules[rule.name] = rule
		if (rule.is_fragment): g_fragments[rule.name] = rule
	return rules


void operator_refused(char* source):
	list[at_rule*] rules = operator_rules(source)
	at_audit_prepare_rules(rules)
	list[at_alt*] original = rules[0].alts
	int count = rules.length
	assert_equal(0, at_normalize_expression(rules[0], rules))
	assert1(original == rules[0].alts)
	assert_equal(count, rules.length)


int main():
	operator_refused(c"grammar G; expr: expr op expr | 'a'; op: '+'?;")
	operator_refused(c"grammar G; expr: expr op expr | 'a'; op: '+' |;")
	operator_refused(c"grammar G; expr: expr op expr | 'a'; op: other; other: op | '+';")
	operator_refused(c"grammar G; expr: expr op expr | 'a'; op: '+' {action();};")
	operator_refused(c"grammar G; expr: expr op expr | 'a'; op: '+' # Plus;")
	operator_refused(c"grammar G; expr: expr op expr | 'a'; op: symbol='+';")
	operator_refused(c"grammar G; expr: expr op expr | 'a'; op: {allowed()}? '+';")
	operator_refused(c"grammar G; expr: expr op expr | 'a'; op: '+' '-';")
	operator_refused(c"grammar G; expr: expr op expr | expr '+' expr | 'a'; op: ADD; ADD: '+' | '-';")
	operator_refused(c"grammar G; expr: expr op expr | 'a'; op: ADD | '+'; ADD: '+' | '-';")
	operator_refused(c"grammar G; expr: expr op expr | 'a'; op: ADD | PLUS; ADD: '+' | '-'; PLUS: '+';")
	operator_refused(c"grammar G; expr: expr OP expr | 'a'; OP: '+' | '-'+;")
	operator_refused(c"grammar G; expr: expr op expr | 'a'; op: ADD; ADD: '+' | '-' -> skip;")
	operator_refused(c"grammar G; expr: expr op expr | 'a'; op: ADD; ADD: '+' | '-' -> type(OTHER); OTHER: '*';")
	operator_refused(c"grammar G; expr: expr op expr | 'a'; op: PART; fragment PART: '+' | '-';")
	# Finite lexer FIRST sets must collide with prefix spellings and with
	# compound bases whose token reference denotes the same operator set.
	operator_refused(c"grammar G; expr: '-' expr | expr '+' expr | OP 'x' | 'a'; OP: '-' | '~';")
	operator_refused(c"grammar G; expr: unary expr | expr '+' expr | OP 'x' | 'a'; unary: OP; OP: '-' | '~';")
	# A partially discovered finite alias must not mutate the caller's map.
	list[at_rule*] rules = operator_rules(c"grammar G; root: op; op: '+' | cycle; cycle: cycle | '-';")
	at_audit_prepare_rules(rules)
	map[char*, int] spellings = new map[char*, int]
	spellings[c"sentinel"] = 7
	assert_equal(0, at_expression_operator(rules[0].alts[0].elements[0], spellings))
	assert_equal(7, spellings[c"sentinel"])
	assert_equal(0, c"+" in spellings)
	assert_equal(0, c"-" in spellings)
	rules = operator_rules(c"grammar G; root: op; op: '+' | '-';")
	at_audit_prepare_rules(rules)
	spellings = new map[char*, int]
	spellings[c"-"] = 7
	assert_equal(0, at_expression_operator(rules[0].alts[0].elements[0], spellings))
	assert_equal(0, c"+" in spellings)
	assert_equal(7, spellings[c"-"])
	println(c"antlr finite operator safety and atomic refusal passed")
	return 0
