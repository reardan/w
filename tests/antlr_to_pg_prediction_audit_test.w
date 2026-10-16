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


void prediction_proof_budget_test():
	list[at_rule*] rules = new list[at_rule*]
	at_abs_reset(rules)
	assert_equal(750000000, g_at_abs_grammar_remaining)
	# Charge inner epsilon-edge scans, not merely outer DFA iterations.
	at_abs_nfa* nfa = at_abs_new()
	at_abs_edge_add(nfa, 0, nfa.accept, 0)
	list[int] seeds = new list[int]
	seeds.push(0)
	g_at_abs_grammar_remaining = 6
	list[int] partial = at_abs_closure(nfa, seeds)
	assert1(nfa.failed)
	assert_equal(0, g_at_abs_grammar_remaining)
	assert_equal(0, at_abs_subset(nfa, partial, &g_at_abs_remaining))
	assert_equal(0, g_at_abs_grammar_remaining)
	__w_list_free(cast(__w_list*, partial))
	__w_list_free(cast(__w_list*, seeds))
	at_abs_free_nfa(nfa)
	# A new grammar gets a new aggregate budget; individual decisions do not.
	at_abs_reset(rules)
	assert1(at_abs_charge(7))
	assert_equal(749999993, g_at_abs_grammar_remaining)
	assert1(at_abs_charge(9))
	assert_equal(749999984, g_at_abs_grammar_remaining)
	# Eligibility limits apply to structure, never grammar names.
	at_rule* rule = new at_rule()
	rule.is_lexer = 0
	rule.alts = new list[at_alt*]
	for int ignored in range(129): rules.push(rule)
	at_abs_reset(rules)
	assert_equal(0, g_at_abs_grammar_remaining)
	assert_equal(0, g_at_abs_operations)
	rules = new list[at_rule*]
	rules.push(rule)
	at_alt* alt = new at_alt()
	alt.elements = new list[at_element*]
	for int ignored in range(4097): alt.elements.push(new at_element())
	rule.alts.push(alt)
	at_abs_reset(rules)
	assert_equal(0, g_at_abs_grammar_remaining)
	assert_equal(0, g_at_abs_operations)


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
	# Delimiter termination proves prefix freedom even with different body
	# lengths. A delimiter admitted by the body must keep the risk visible.
	assert_equal(0, prediction_losses(c"grammar G; start: item EOF; item: 'a'+ 'b'* ';' | 'a'* 'b'+ ';';", 0))
	assert1(prediction_losses(c"grammar G; start: item EOF; item: 'a' ';' | 'a' (';' 'a')+ ';';", 0) > 0)
	# Nullable continuation is not enough: a token stolen from an optional
	# compound body can still prevent complete-input acceptance.
	assert1(prediction_losses(c"grammar G; start: 'a'* ('a' 'b')? EOF;", 0) > 0)
	assert1(prediction_losses(c"grammar G; start: inner ('a' 'b')? EOF; inner: 'a'+;", 0) > 0)
	assert1(prediction_losses(c"grammar G; start: inner 'a'+ EOF; inner: ('a'|'b')+;", 0) > 0)
	# Repeated pure runs can absorb optional caller runs without stealing a
	# required token; proof follows aliases and nested caller continuations.
	assert_equal(0, prediction_losses(c"grammar G; start: item+ EOF; item: 'x' run*; run: ('a'|'b')+;", 0))
	assert_equal(0, prediction_losses(c"grammar G; start: 's' run? flag* (':' run? flag*)* flag* EOF; run: ('a'|'b')+; flag: '?'|'!';", 0))
	# A complete delimiter-terminated line can absorb a following item only
	# when its remaining continuation still accepts the same suffix.
	assert_equal(0, prediction_losses(c"grammar G; start: item+ 'z' EOF; item: ':' 'v'+ ':' line+; line: 'v'+ ';' | 'v'+ ':' ('v'|':')* ';' | ':' ':'+ ('v'|':')* ';' | ':'+ 'v'+ ':'* ';';", 0))
	# A mandatory final run must not be mistaken for optional absorption.
	assert1(prediction_losses(c"grammar G; start: item+ 'a' EOF; item: 'x' run*; run: ('a'|'b')+;", 0) > 0)
	prediction_proof_budget_test()
	println(c"parser continuation audit tracks alternatives and caller FOLLOW sets")
	return 0
