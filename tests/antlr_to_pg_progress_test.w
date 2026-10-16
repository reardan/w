# wbuild: target=antlr_to_pg_progress_test tag=tests dep=antlr_to_pg
# wbuild: step="bin/wv2 --strict tests/antlr_to_pg_progress_test.w -o bin/antlr_to_pg_progress_test"
# wbuild: step="bin/antlr_to_pg_progress_test"
# wbuild: step="bin/wv2 x64 --strict tests/antlr_to_pg_progress_test.w -o bin/antlr_to_pg_progress_x64_test"
# wbuild: step="bin/antlr_to_pg_progress_x64_test"
import lib.assert
import libs.extras.grammars.antlr_to_pg.ast
import libs.extras.grammars.antlr_to_pg.normalize
import libs.extras.grammars.antlr_to_pg.parser_progress
import libs.extras.grammars.antlr_to_pg.classify
import libs.extras.grammars.antlr_to_pg.matchers_emit

list[at_rule*] progress_rules(char* source):
	g_at_source = source
	g_seen_rule_names = new map[char*, int]
	g_at_dependencies = new list[at_site*]
	g_at_declared_modes = new list[char*]
	g_at_token_identities = new list[char*]
	g_report_lines = new list[char*]
	pg_diagnostics* diagnostics = pg_diagnostics_new()
	pg_ast_node* root = antlr4_parse(source, c"progress.g4", diagnostics)
	assert1(root != 0)
	assert_equal(0, diagnostics.items.length)
	return at_collect_rules(root)

at_progress_result* progress_analyze(char* source):
	return at_progress_analyze(progress_rules(source), at_progress_default_limits())

int progress_has_issue(at_progress_result* result, char* code):
	for at_progress_issue* issue in result.issues:
		if (strcmp(issue.code, code) == 0): return 1
	return 0

void progress_cycle_tests():
	at_progress_result* result = progress_analyze(c"grammar G; a: a 'x' | b | 'y'; b: a | 'z';")
	assert1(result.complete)
	assert1(result.facts[c"a"].self_cycle != 0)
	assert1(result.facts[c"a"].mutual_cycle != 0)
	assert1(result.facts[c"b"].mutual_cycle != 0)
	assert_equal(3, result.facts[c"a"].mutual_cycle.path.length)
	assert_equal(0, strcmp(result.facts[c"a"].mutual_cycle.path[1], c"b"))
	assert_equal(0, at_progress_candidate_valid(result))
	result = progress_analyze(c"grammar G; a: guard b | 'x'; guard: ; b: (a) | 'y';")
	assert1(result.facts[c"a"].mutual_cycle != 0)
	assert1(result.facts[c"guard"].nullable)
	result = progress_analyze(c"grammar G; a: 'x' b | ; b: a;")
	assert1(at_progress_candidate_valid(result))
	assert_equal(0, result.cycles.length)
	assert1(result.facts[c"a"].nullable)
	assert1(result.facts[c"b"].nullable)

void progress_derivation_tests():
	at_progress_result* result = progress_analyze(c"grammar G; a: b; b: c; c: ;")
	at_progress_result* reverse = progress_analyze(c"grammar G; c: ; b: c; a: b;")
	for at_progress_fact* fact in result.order:
		assert_equal(fact.nullable, reverse.facts[fact.rule.name].nullable)
		assert_equal(fact.productive, reverse.facts[fact.rule.name].productive)
		assert_equal(fact.edges.length, reverse.facts[fact.rule.name].edges.length)
	assert1(at_progress_candidate_valid(result))
	result = progress_analyze(c"grammar G; a: 'x' b; b: a;")
	assert1(progress_has_issue(result, c"nonproductive_rule"))
	assert_equal(0, result.cycles.length)
	assert_equal(0, at_progress_candidate_valid(result))
	result = progress_analyze(c"grammar G; a: missing?;")
	assert1(progress_has_issue(result, c"unresolved_reference"))
	assert_equal(0, at_progress_candidate_valid(result))
	result = progress_analyze(c"grammar G; a: ('x'?)*;")
	assert1(progress_has_issue(result, c"nullable_repetition"))
	result = progress_analyze(c"grammar G; a: empty+; empty: ;")
	assert1(progress_has_issue(result, c"nullable_repetition"))
	# A separator may be optional when the operand independently consumes.
	result = progress_analyze(c"grammar G; a: (','? operand)*; operand: 'x';")
	assert1(at_progress_candidate_valid(result))
	assert1(at_progress_rule_consumes(result, c"operand"))
	result = progress_analyze(c"grammar G; a: (','? operand)*; operand: 'x'?;")
	assert1(progress_has_issue(result, c"nullable_repetition"))
	assert_equal(0, at_progress_rule_consumes(result, c"operand"))
	# Named EOF-produced tokens advance a cursor even with a zero-byte span.
	result = progress_analyze(c"grammar G; a: END* EOF; END: EOF;")
	assert1(at_progress_candidate_valid(result))
	result = progress_analyze(c"grammar G; a: EOF*;")
	assert1(progress_has_issue(result, c"nullable_repetition"))
	result = progress_analyze(c"grammar G; a: EOF a | 'x';")
	assert1(result.facts[c"a"].self_cycle != 0)

void progress_token_cursor_test():
	pg_token_stream* stream = pg_token_stream_new()
	# Provider-backed stream pins terminal EOF, unlike a finite token list.
	stream.provider = new pg_lexer_state()
	stream.exhausted = 1
	pg_token_stream_add(stream, pg_token_new(1, c"", c"empty", 1, 1))
	pg_token_stream_add(stream, pg_token_eof(0, c"empty", 1, 1))
	assert_equal(0, stream.index)
	pg_token* named = pg_token_stream_consume(stream)
	assert_equal(0, named.length)
	assert_equal(1, stream.index)
	pg_token_stream_consume(stream)
	assert_equal(1, stream.index)
	pg_token_stream_consume(stream)
	assert_equal(1, stream.index)

void progress_limit_tests():
	list[at_rule*] rules = progress_rules(c"grammar G; a: b; b: 'x';")
	list[at_alt*] original = rules[0].alts
	at_progress_limits* limits = at_progress_default_limits()
	limits.max_rules = 1
	at_progress_result* result = at_progress_analyze(rules, limits)
	assert1(result.exhausted)
	assert_equal(0, strcmp(result.reason, c"rule_limit"))
	assert_equal(0, at_progress_candidate_valid(result))
	assert1(rules[0].alts == original)
	assert_equal(2, rules.length)
	limits = at_progress_default_limits()
	limits.max_work = 3
	result = at_progress_analyze(rules, limits)
	assert1(result.exhausted)
	assert_equal(3, result.work)
	assert_equal(0, strcmp(result.reason, c"work_limit"))
	assert_equal(0, at_progress_rule_consumes(result, c"b"))
	limits = at_progress_default_limits()
	limits.max_depth = 1
	result = at_progress_analyze(progress_rules(c"grammar G; a: (('x'));"), limits)
	assert1(result.exhausted)
	assert_equal(0, strcmp(result.reason, c"depth_limit"))
	# Exhaustion during graph search is explicit too, after fixed-point success.
	rules = progress_rules(c"grammar G; a: b | 'x'; b: a | 'y';")
	at_progress_result* complete = at_progress_analyze(rules, at_progress_default_limits())
	limits = at_progress_default_limits()
	limits.max_work = complete.work - 1
	result = at_progress_analyze(rules, limits)
	assert1(result.exhausted)
	assert_equal(0, result.complete)
	assert_equal(0, at_progress_candidate_valid(result))

int main():
	progress_cycle_tests()
	progress_derivation_tests()
	progress_limit_tests()
	progress_token_cursor_test()
	println(c"antlr parser token progress analysis passed")
	return 0
