/*
Actions ({ code }) and predicates (&{ expr }), issue #329 milestone 4 --
the last ParserGenerator streaming-mode milestone. actions_sample.pg is a
small "emit-as-you-parse" demonstration: a left-to-right sum/difference
chain whose { action } terms call actions_support.w to record stack-machine
instructions as each term commits (no AST, no buffering -- the instruction
list *is* the parse's output), plus a predicate (&{ actions_prefer_call() })
that picks between two alternatives sharing the same IDENT first token, the
same way the hand-written compiler resolves a context-sensitive choice.

$n/text(n) bindings: `number`'s action reads text(1) (the NUMBER token just
matched); `primary`'s two actions read text(2) (after the predicate term)
and text(1) respectively -- see docs/projects/parser_generator.md for the
binding surface and its "earlier plain token term only" restriction.
*/
import lib.testing
import libs.extras.parser_generator.runtime
import libs.extras.parser_generator.grammar_reader
import libs.extras.parser_generator.generator
import tests.parser_generator.actions_support
import bin.generated_actions_parser


actions_sample_listener* make_actions_listener():
	return actions_sample_listener_new()


# Actions alone: no predicate involved. The instruction sequence is the
# exact left-to-right commit order the parse ran in -- proof each action
# fired exactly once, not zero or twice under any backtracking.
void test_actions_emit_stack_code():
	actions_reset()
	pg_diagnostics* diagnostics = pg_diagnostics_new()
	actions_sample_listener* listener = make_actions_listener()
	char* input = c"12 + 7 - 3;\n"
	int ok = actions_sample_parse_streaming(input, c"actions_sample.txt", diagnostics, listener)
	assert_equal(0, pg_diagnostics_count(diagnostics))
	assert1(ok != 0)
	assert_equal(5, actions_emitted.length)
	assert_strings_equal(c"PUSH 12", actions_emitted[0])
	assert_strings_equal(c"PUSH 7", actions_emitted[1])
	assert_strings_equal(c"ADD", actions_emitted[2])
	assert_strings_equal(c"PUSH 3", actions_emitted[3])
	assert_strings_equal(c"SUB", actions_emitted[4])


# The predicate picks between primary's two IDENT-headed alternatives --
# same first-set, resolved by &{ actions_prefer_call() } instead of a
# first-set test, exactly like the hand-written compiler's own
# type-lookup-gated decisions.
void test_predicate_selects_call_alternative():
	actions_reset()
	actions_prefer_call_flag = 1
	pg_diagnostics* diagnostics = pg_diagnostics_new()
	actions_sample_listener* listener = make_actions_listener()
	int ok = actions_sample_parse_streaming(c"foo;\n", c"actions_sample.txt", diagnostics, listener)
	assert_equal(0, pg_diagnostics_count(diagnostics))
	assert1(ok != 0)
	assert_equal(1, actions_emitted.length)
	assert_strings_equal(c"CALL foo", actions_emitted[0])


void test_predicate_selects_push_name_alternative():
	actions_reset()
	actions_prefer_call_flag = 0
	pg_diagnostics* diagnostics = pg_diagnostics_new()
	actions_sample_listener* listener = make_actions_listener()
	int ok = actions_sample_parse_streaming(c"foo;\n", c"actions_sample.txt", diagnostics, listener)
	assert_equal(0, pg_diagnostics_count(diagnostics))
	assert1(ok != 0)
	assert_equal(1, actions_emitted.length)
	assert_strings_equal(c"PUSHN foo", actions_emitted[0])


# Multiple statements, mixing the sum and primary rules: exactly-once
# commit order holds across the whole input, not just one rule activation.
void test_actions_multiple_statements_preserve_order():
	actions_reset()
	actions_prefer_call_flag = 0
	pg_diagnostics* diagnostics = pg_diagnostics_new()
	actions_sample_listener* listener = make_actions_listener()
	char* input = c"1 + 2;\nfoo;\n3 - 1;\n"
	int ok = actions_sample_parse_streaming(input, c"actions_sample.txt", diagnostics, listener)
	assert_equal(0, pg_diagnostics_count(diagnostics))
	assert1(ok != 0)
	assert_equal(7, actions_emitted.length)
	assert_strings_equal(c"PUSH 1", actions_emitted[0])
	assert_strings_equal(c"PUSH 2", actions_emitted[1])
	assert_strings_equal(c"ADD", actions_emitted[2])
	assert_strings_equal(c"PUSHN foo", actions_emitted[3])
	assert_strings_equal(c"PUSH 3", actions_emitted[4])
	assert_strings_equal(c"PUSH 1", actions_emitted[5])
	assert_strings_equal(c"SUB", actions_emitted[6])


# A genuine syntax error still aborts cleanly with an action-bearing
# grammar -- the failing term's action never ran (there is nothing to run
# yet when a mandatory term itself fails).
void test_actions_syntax_error_runs_no_partial_action():
	actions_reset()
	pg_diagnostics* diagnostics = pg_diagnostics_new()
	actions_sample_listener* listener = make_actions_listener()
	int ok = actions_sample_parse_streaming(c"1 +;\n", c"actions_sample.txt", diagnostics, listener)
	assert_equal(0, ok)
	assert1(pg_diagnostics_count(diagnostics) > 0)
	assert_equal(1, actions_emitted.length)
	assert_strings_equal(c"PUSH 1", actions_emitted[0])


# --- rejection tests: the action-safety analysis (analysis.w's
# pg_action_safety_check) and $n/text(n) binding validation
# (generator.w's pg_validate_action_bindings), both new generation-time
# checks for this milestone. ---------------------------------------------


# Actions/predicates are streaming-mode only: AST mode has no commit point
# to run them at exactly once, so pg_action_safety_check rejects it by
# rule name before generation even reaches the AST emitter.
void test_action_rejected_in_ast_mode():
	pg_diagnostics* diagnostics = pg_diagnostics_new()
	char* source = c"parser bad_ast_action\ntoken IDENT letters\nstart value\nrule value = IDENT { do_thing() }\n"
	pg_grammar* grammar = pg_grammar_read(source, c"bad_ast_action.pg", diagnostics)
	assert1(grammar != 0)
	assert_equal(0, pg_diagnostics_count(diagnostics))
	assert_equal(0, grammar.mode)
	assert1(pg_action_safety_check(grammar) > 0)
	char* generated = pg_generate_parser(grammar)
	assert1(generated == 0)


# A predicate only resolves the alternative it heads; two *unpredicated*
# overlapping alternatives (here, two different rule-reference terms that
# both happen to start with IDENT) are still a genuine, unresolved
# ambiguity and still rejected by pg_streaming_check exactly as before
# this milestone -- the predicate exemption in analysis.w must not paper
# over real conflicts, action or no action.
void test_streaming_mode_still_rejects_genuine_conflict_with_action():
	pg_diagnostics* diagnostics = pg_diagnostics_new()
	char* source = c"parser bad_conflict\nmode streaming\ntoken IDENT letters\nstart value\nrule a_ident = IDENT { do_thing() }\nrule b_ident = IDENT\nrule value = a_ident | b_ident\n"
	pg_grammar* grammar = pg_grammar_read(source, c"bad_conflict.pg", diagnostics)
	assert1(grammar != 0)
	assert_equal(0, pg_diagnostics_count(diagnostics))
	char* generated = pg_generate_parser(grammar)
	assert1(generated == 0)


# An out-of-range/forward $n reference is a generation-time error naming
# the rule, not a miscompiled generated file.
void test_action_binding_out_of_range_rejected():
	pg_diagnostics* diagnostics = pg_diagnostics_new()
	char* source = c"parser bad_binding\nmode streaming\ntoken IDENT letters\nstart value\nrule value = IDENT { do_thing(text(5)) }\n"
	pg_grammar* grammar = pg_grammar_read(source, c"bad_binding.pg", diagnostics)
	assert1(grammar != 0)
	assert_equal(0, pg_diagnostics_count(diagnostics))
	assert1(pg_validate_action_bindings(grammar) > 0)
	char* generated = pg_generate_parser(grammar)
	assert1(generated == 0)


# $n may only name an earlier plain token/literal term -- referencing a
# rule term is rejected too (the design's "token terms only" restriction).
void test_action_binding_rule_reference_rejected():
	pg_diagnostics* diagnostics = pg_diagnostics_new()
	char* source = c"parser bad_binding_rule\nmode streaming\ntoken IDENT letters\nstart value\nrule inner = IDENT\nrule value = inner { do_thing(text(1)) }\n"
	pg_grammar* grammar = pg_grammar_read(source, c"bad_binding_rule.pg", diagnostics)
	assert1(grammar != 0)
	assert_equal(0, pg_diagnostics_count(diagnostics))
	assert1(pg_validate_action_bindings(grammar) > 0)
	char* generated = pg_generate_parser(grammar)
	assert1(generated == 0)


# A binding inside an alternative that shares a leading term with a
# sibling is rejected rather than silently resolving against the wrong
# (left-factored) variable -- see pg_alt_shares_leading_term in
# generator.w.
void test_action_binding_shared_prefix_rejected():
	pg_diagnostics* diagnostics = pg_diagnostics_new()
	char* source = c"parser bad_prefix\nmode streaming\ntoken IDENT letters\ntoken NUMBER digits\nstart value\nrule value = IDENT NUMBER { do_thing(text(2)) } | IDENT\n"
	pg_grammar* grammar = pg_grammar_read(source, c"bad_prefix.pg", diagnostics)
	assert1(grammar != 0)
	assert_equal(0, pg_diagnostics_count(diagnostics))
	assert1(pg_validate_action_bindings(grammar) > 0)
	char* generated = pg_generate_parser(grammar)
	assert1(generated == 0)


# A predicate must lead its alternative -- the grammar reader rejects one
# appearing mid-alternative at grammar-parse time (not generation time).
void test_predicate_must_be_first_term():
	pg_diagnostics* diagnostics = pg_diagnostics_new()
	char* source = c"parser bad_predicate_position\nmode streaming\ntoken IDENT letters\nstart value\nrule value = IDENT &{ 1 }\n"
	pg_grammar* grammar = pg_grammar_read(source, c"bad_predicate_position.pg", diagnostics)
	assert1(grammar == 0)
	assert1(pg_diagnostics_count(diagnostics) > 0)
