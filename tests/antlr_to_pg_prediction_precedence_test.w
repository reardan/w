# wbuild: target=antlr_to_pg_prediction_precedence_test tag=tests dep=antlr_to_pg
# wbuild: step="bin/antlr_to_pg --strict --stateful --prediction tests/grammars/antlr_prediction/Precedence.g4 -o bin/prediction_precedence.pg --parser-name precedence --matchers bin/prediction_precedence_matchers.w"
# wbuild: step="bin/parser_generator_grammars bin/prediction_precedence.pg -o bin/prediction_precedence_parser.w"
# wbuild: step="bin/wv2 --strict tests/grammars/antlr_prediction/precedence_runtime.w -o bin/prediction_precedence_runtime"
# wbuild: step="bin/prediction_precedence_runtime"
# wbuild: step="bin/wv2 x64 --strict tests/grammars/antlr_prediction/precedence_runtime.w -o bin/prediction_precedence_runtime_x64"
# wbuild: step="bin/prediction_precedence_runtime_x64"
# wbuild: step="bin/antlr_to_pg --strict --stateful --prediction tests/grammars/antlr_prediction/Labels.g4 -o bin/prediction_labels.pg --parser-name labels --matchers bin/prediction_labels_matchers.w"
# wbuild: step="bin/parser_generator_grammars bin/prediction_labels.pg -o bin/prediction_labels_parser.w"
# wbuild: step="bin/wv2 --strict tests/grammars/antlr_prediction/labels_runtime.w -o bin/prediction_labels_runtime"
# wbuild: step="bin/prediction_labels_runtime"
# wbuild: step="bin/wv2 x64 --strict tests/grammars/antlr_prediction/labels_runtime.w -o bin/prediction_labels_runtime_x64"
# wbuild: step="bin/prediction_labels_runtime_x64"
# wbuild: step="bin/wv2 --strict tests/antlr_to_pg_prediction_precedence_test.w -o bin/prediction_precedence_safety_test"
# wbuild: step="bin/prediction_precedence_safety_test"
# wbuild: step="bin/antlr_to_pg --strict --stateful --prediction tests/grammars/antlr_prediction/Lists.g4 -o bin/prediction_lists.pg --parser-name lists --matchers bin/prediction_lists_matchers.w"
# wbuild: step="bin/parser_generator_grammars bin/prediction_lists.pg -o bin/prediction_lists_parser.w"
# wbuild: step="bin/wv2 --strict tests/grammars/antlr_prediction/lists_runtime.w -o bin/prediction_lists_runtime"
# wbuild: step="bin/prediction_lists_runtime"
import lib.assert
import bin.generated_antlr4_parser
import libs.extras.grammars.antlr_to_pg.ast
import libs.extras.grammars.antlr_to_pg.normalize
import libs.extras.grammars.antlr_to_pg.classify
import libs.extras.grammars.antlr_to_pg.matchers_emit
import libs.extras.grammars.antlr_to_pg.emit


void prediction_precedence_refuse(char* source):
	g_at_source = source
	g_seen_rule_names = new map[char*, int]
	g_at_dependencies = new list[at_site*]
	g_at_declared_modes = new list[char*]
	g_at_token_identities = new list[char*]
	g_at_prediction = 1
	pg_diagnostics* diagnostics = pg_diagnostics_new()
	pg_ast_node* root = antlr4_parse(source, c"refusal.g4", diagnostics)
	assert1(root != 0)
	assert_equal(0, diagnostics.items.length)
	list[at_rule*] rules = at_collect_rules(root)
	at_source_prepare(rules)
	at_audit_prepare_rules(rules)
	list[at_alt*] before = rules[0].alts
	int count = rules.length
	assert_equal(0, at_normalize_prediction_expression(rules[0], rules))
	assert_equal(count, rules.length)
	assert1(before == rules[0].alts)


int main():
	prediction_precedence_refuse(c"grammar G; e: e '+' {host();} e | '1';")
	prediction_precedence_refuse(c"grammar G; e: e '+' e | {predicate()}? '1';")
	prediction_precedence_refuse(c"grammar G; e: e '+' e | '(' e ')';")
	prediction_precedence_refuse(c"grammar G; e: e '!'? | '1';")
	prediction_precedence_refuse(c"grammar G; e: e e | '1';")
	prediction_precedence_refuse(c"grammar G; e: e '+' e | alias; alias: e;")
	println(c"prediction precedence refusals remain atomic")
	return 0
