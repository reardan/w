# wbuild: target=antlr_to_pg_prediction_audit_test tag=tests dep=antlr_to_pg
# wbuild: step="bin/wv2 --strict tests/antlr_to_pg_prediction_audit_test.w -o bin/antlr_to_pg_prediction_audit_test"
# wbuild: step="bin/antlr_to_pg_prediction_audit_test"
import lib.assert
import bin.generated_antlr4_parser
import libs.extras.grammars.antlr_to_pg.ast
import libs.extras.grammars.antlr_to_pg.prediction_audit
import libs.extras.grammars.antlr_to_pg.classify
import libs.extras.grammars.antlr_to_pg.matchers_emit


int prediction_losses(char* source, int enabled):
	g_at_source = source
	g_seen_rule_names = new map[char*, int]
	g_at_dependencies = new list[at_site*]
	g_at_declared_modes = new list[char*]
	g_at_token_identities = new list[char*]
	g_at_loss_lines = new list[char*]
	g_at_semantic_losses = 0
	g_at_prediction = enabled
	pg_diagnostics* diagnostics = pg_diagnostics_new()
	pg_ast_node* root = antlr4_parse(source, c"audit.g4", diagnostics)
	assert1(root != 0)
	assert_equal(0, diagnostics.items.length)
	list[at_rule*] rules = at_collect_rules(root)
	at_audit_prepare_rules(rules)
	at_audit_prediction(rules)
	return g_at_semantic_losses


int main():
	assert1(prediction_losses(c"grammar G; start: item EOF; item: 'a' | 'a' 'b';", 0) > 0)
	assert_equal(0, prediction_losses(c"grammar G; start: item EOF; item: 'a' | 'a' 'b';", 1))
	assert1(prediction_losses(c"grammar G; start: item 'a' EOF; item: 'a'?;", 0) > 0)
	assert1(prediction_losses(c"grammar G; start: item 'a' EOF; item: 'a'*;", 0) > 0)
	assert1(prediction_losses(c"grammar G; start: item 'a' EOF; item: other; other: 'a'+;", 0) > 0)
	assert1(prediction_losses(c"grammar G; start: item EOF; item: | 'a';", 0) > 0)
	assert_equal(0, prediction_losses(c"grammar G; start: item EOF; item: 'a' | 'b';", 0))
	assert_equal(0, prediction_losses(c"grammar G; start: item 'b' EOF; item: 'a'*;", 0))
	# EOF-producing lexer rules still produce tokens in parser FIRST/FOLLOW.
	assert_equal(0, prediction_losses(c"grammar G; start: END 'a' EOF; END: EOF;", 0))
	# Sharing a prefix is safe when mandatory suffix tokens distinguish it.
	assert_equal(0, prediction_losses(c"grammar G; start: item EOF; item: short | long; short: 'a' 'b'; long: 'a' 'c';", 0))
	assert_equal(0, prediction_losses(c"grammar G; start: item EOF; item: number | variable; number: 's'* '0'; variable: 's'* ('a'|'b') 'q'*;", 0))
	assert_equal(0, prediction_losses(c"grammar G; start: 'a' EOF?;", 0))
	# Prefix cancellation must not assume a greedy common prefix leaves its
	# suffix intact, nor discharge a shorter/longer accepting alternative.
	assert1(prediction_losses(c"grammar G; start: item EOF; item: 'a'? 'a' 'b' | 'a'? 'a' 'c';", 0) > 0)
	assert1(prediction_losses(c"grammar G; start: item EOF; item: 'a' | 'a' 'b';", 0) > 0)
	println(c"parser continuation audit tracks alternatives and caller FOLLOW sets")
	return 0
