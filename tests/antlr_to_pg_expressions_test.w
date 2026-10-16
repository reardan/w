# wbuild: target=antlr_to_pg_expressions_test tag=tests dep=antlr_to_pg
# wbuild: step="bin/wv2 tests/antlr_to_pg_expressions_test.w -o bin/antlr_to_pg_expressions_test"
# wbuild: step="bin/antlr_to_pg_expressions_test"
# wbuild: step="bin/antlr_to_pg --strict --stateful tests/grammars/antlr_expressions/expressions.g4 -o bin/antlr_expressions.pg --parser-name expressions --matchers bin/antlr_expressions_matchers.w"
# wbuild: step="bin/parser_generator_grammars bin/antlr_expressions.pg -o bin/antlr_expressions_parser.w"
# wbuild: step="bin/wv2 tests/grammars/antlr_expressions/runtime.w -o bin/antlr_expressions_runtime"
# wbuild: step="bin/antlr_expressions_runtime"
import bin.generated_antlr4_parser
import lib.assert
import libs.extras.grammars.antlr_to_pg.ast
import libs.extras.grammars.antlr_to_pg.audit
import libs.extras.grammars.antlr_to_pg.normalize
import libs.extras.grammars.antlr_to_pg.classify
import libs.extras.grammars.antlr_to_pg.matchers_analyze
import libs.extras.grammars.antlr_to_pg.matchers_emit


list[at_rule*] expression_rules(char* source):
	g_seen_rule_names = new map[char*, int]
	g_report_lines = new list[char*]
	g_parser_refs = new map[char*, int]
	g_fragments = new map[char*, at_rule*]
	g_lexer_rules = new map[char*, at_rule*]
	g_at_dependencies = new list[at_site*]
	g_at_declared_modes = new list[char*]
	g_at_source = source
	pg_diagnostics* diagnostics = pg_diagnostics_new()
	pg_ast_node* root = antlr4_parse(source, c"expressions.g4", diagnostics)
	assert1(root != 0)
	assert_equal(0, pg_diagnostics_count(diagnostics))
	list[at_rule*] rules = at_collect_rules(root)
	for at_rule* rule in rules:
		if (rule.is_lexer): g_lexer_rules[rule.name] = rule
		if (rule.is_fragment): g_fragments[rule.name] = rule
	return rules


void expression_refused(char* source):
	list[at_rule*] rules = expression_rules(source)
	at_audit_prepare_rules(rules)
	at_rule* expression = rules[0]
	list[at_alt*] before = expression.alts
	int count = rules.length
	assert_equal(0, at_normalize_expression(expression, rules))
	assert_equal(count, rules.length)
	assert1(expression.alts == before)


int main():
	# Token aliases must not conceal duplicate operator spellings or lexer
	# behavior that changes token identity. Refusal leaves the source intact.
	expression_refused(c"grammar Bad; expr: expr PLUS expr | expr '+' expr | NUMBER; PLUS: '+'; NUMBER: [0-9]+;")
	expression_refused(c"grammar Bad; expr: expr PLUS expr | NUMBER; fragment PLUS: '+'; NUMBER: [0-9]+;")
	expression_refused(c"grammar Bad; expr: expr op expr | NUMBER; op: '+'; NUMBER: [0-9]+;")
	expression_refused(c"grammar Bad; expr: expr OP expr | NUMBER; OP: '+' | '-'; NUMBER: [0-9]+;")
	expression_refused(c"grammar Bad; expr: expr PLUS expr | NUMBER; PLUS: '+' -> skip; NUMBER: [0-9]+;")
	expression_refused(c"grammar Bad; expr: expr PLUS expr | NUMBER; PLUS: '+' -> type(OTHER); OTHER: '-'; NUMBER: [0-9]+;")
	expression_refused(c"grammar Bad; expr: expr '+' expr | PLUS expr | PLUS; PLUS: '+';")
	expression_refused(c"grammar Bad; expr: expr '+' expr | LEFT expr RIGHT | NUMBER; LEFT: '['; RIGHT: ']'; NUMBER: [0-9]+;")
	expression_refused(c"grammar Bad; expr: expr '+' expr | NUMBER?; NUMBER: [0-9]+;")
	expression_refused(c"grammar Bad; expr: expr '+' expr | '-'? indirect; indirect: expr;")
	expression_refused(c"grammar Bad; expr: expr '+' expr | NUMBER {act();}; NUMBER: [0-9]+;")
	expression_refused(c"grammar Bad; expr: expr '+' expr # Sum | NUMBER # Atom; NUMBER: [0-9]+;")
	expression_refused(c"grammar Bad; expr: expr '+' expr | LPAREN expr RPAREN; LPAREN: '('; RPAREN: ')';")
	# Ordered primary alternatives cannot backtrack after a shorter prefix
	# succeeds. Check literal, grouped, nullable-prefix and alias overlaps.
	expression_refused(c"grammar Bad; expr: expr '+' expr | '-' expr | '-' NUMBER 'x' | NUMBER; NUMBER: [0-9]+;")
	expression_refused(c"grammar Bad; expr: expr '+' expr | '-' expr | ('-' | '~') NUMBER 'x' | NUMBER; NUMBER: [0-9]+;")
	expression_refused(c"grammar Bad; expr: expr '+' expr | '-' expr | '~'? '-' NUMBER 'x' | NUMBER; NUMBER: [0-9]+;")
	expression_refused(c"grammar Bad; expr: expr '+' expr | '-' expr | marker NUMBER 'x' | NUMBER; marker: '-'; NUMBER: [0-9]+;")
	expression_refused(c"grammar Bad; expr: expr '+' expr | '(' expr ')' | '(' NUMBER ')' 'x' | NUMBER; NUMBER: [0-9]+;")
	expression_refused(c"grammar Bad; expr: expr '+' expr | 'x' | 'x' 'y';")
	expression_refused(c"grammar Bad; expr: expr '+' expr | 'x' 'y' | 'x';")
	expression_refused(c"grammar Bad; expr: expr '+' expr | NUMBER | NUMBER 'x'; NUMBER: [0-9]+;")
	list[at_rule*] mode_rules = expression_rules(c"grammar Bad; expr: expr PLUS expr | NUMBER; PLUS: '+'; NUMBER: [0-9]+;")
	mode_rules[1].mode = c"OTHER_MODE"
	at_audit_prepare_rules(mode_rules)
	assert_equal(0, at_normalize_expression(mode_rules[0], mode_rules))
	list[at_rule*] rules = expression_rules(c"grammar Good; expr: expr '+' expr | '-' expr | 'a';")
	assert_equal(1, at_normalize_parser_lists(rules))
	assert_equal(0, at_audit(rules))
	assert_equal(0, at_normalize_parser_lists(rules))
	println(c"antlr expression extension refusal atomicity passed")
	return 0
