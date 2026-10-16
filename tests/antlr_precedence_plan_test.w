# wbuild: target=antlr_precedence_plan_test tag=tests dep=antlr_to_pg
# wbuild: step="bin/wv2 --strict tests/antlr_precedence_plan_test.w -o bin/antlr_precedence_plan_test"
# wbuild: step="bin/antlr_precedence_plan_test"
# wbuild: step="bin/wv2 x64 --strict tests/antlr_precedence_plan_test.w -o bin/antlr_precedence_plan_test_x64"
# wbuild: step="bin/antlr_precedence_plan_test_x64"
import lib.assert
import bin.generated_antlr4_parser
import libs.extras.grammars.antlr_to_pg.ast
import libs.extras.grammars.antlr_to_pg.audit
import libs.extras.grammars.antlr_to_pg.precedence_plan
import libs.extras.grammars.antlr_to_pg.source_metadata
import libs.extras.grammars.antlr_to_pg.classify
import libs.extras.grammars.antlr_to_pg.matchers_emit


list[at_rule*] precedence_rules(char* source):
	g_at_source = source
	g_seen_rule_names = new map[char*, int]
	g_at_dependencies = new list[at_site*]
	g_at_declared_modes = new list[char*]
	g_at_token_identities = new list[char*]
	g_at_prediction = 1
	pg_diagnostics* diagnostics = pg_diagnostics_new()
	pg_ast_node* root = antlr4_parse(source, c"precedence.g4", diagnostics)
	assert1(root != 0)
	assert_equal(0, diagnostics.items.length)
	list[at_rule*] rules = at_collect_rules(root)
	at_source_prepare(rules)
	return rules


at_lr_plan* precedence_plan(char* source):
	list[at_rule*] rules = precedence_rules(source)
	list[at_alt*] before = rules[0].alts
	int count = rules.length
	at_lr_plan* result = at_lr_plan_build(rules[0], 100000)
	assert_equal(1, result.complete)
	assert_equal(0, result.reason[0])
	assert1(before == rules[0].alts)
	assert_equal(count, rules.length)
	for i, alt in before: assert1(result.alternatives[i].source == alt)
	return result


void precedence_classification():
	# Original alt 1 is a suffix, but binary alt 3 is the first transformed
	# operator decision. Prefix and other primaries retain their source order.
	at_lr_plan* plan = precedence_plan(c"grammar G; e: e '!' | '-' e | e '+' e | '(' e ')' | ID;")
	assert_equal(1, plan.direct_recursive)
	assert_equal(5, plan.alternatives.length)
	assert_equal(3, plan.alternatives[0].kind)
	assert_equal(2, plan.alternatives[0].decision_index)
	assert_equal(5, plan.alternatives[0].precedence)
	assert1(plan.alternatives[0].constrained == 0)
	assert_equal(2, plan.alternatives[1].kind)
	assert_equal(4, plan.alternatives[1].primary_binding)
	assert_equal(4, plan.alternatives[1].constrained.binding)
	assert_equal(1, plan.alternatives[1].decision_index)
	assert_equal(1, plan.alternatives[2].kind)
	assert_equal(1, plan.alternatives[2].decision_index)
	assert_equal(3, plan.alternatives[2].precedence)
	assert_equal(4, plan.alternatives[2].constrained.binding)
	assert_equal(-1, plan.alternatives[2].primary_binding)
	assert_equal(-1, plan.alternatives[2].left_operand.binding)
	assert_equal(0, plan.alternatives[3].kind)
	assert_equal(0, plan.alternatives[3].primary_binding)
	assert_equal(0, plan.alternatives[3].occurrences[0].binding)
	assert_equal(2, plan.alternatives[3].decision_index)
	assert_equal(0, plan.alternatives[4].kind)
	assert_equal(3, plan.alternatives[4].decision_index)


void precedence_nested():
	at_lr_plan* plan = precedence_plan(c"grammar G; e: e '?' (e | ID e?) ':' e | e ('[' e ']')? | 'guard' (e)* | ID;")
	at_lr_alternative* binary = plan.alternatives[0]
	assert_equal(1, binary.kind)
	assert_equal(4, binary.occurrences.length)
	assert1(binary.left_operand == binary.occurrences[0])
	assert1(binary.constrained == binary.occurrences[3])
	assert_equal(5, binary.constrained.binding)
	at_lr_occurrence* nested = binary.occurrences[2]
	assert_equal(3, nested.path.length)
	assert_equal(2, nested.path[0])
	assert_equal(1, nested.path[1])
	assert_equal(1, nested.path[2])
	assert_equal(2, nested.suffixes.length)
	assert_equal('?', nested.suffixes[1])
	assert_equal(0, nested.binding)
	at_lr_alternative* suffix = plan.alternatives[1]
	assert_equal(3, suffix.kind)
	assert_equal(2, suffix.occurrences.length)
	assert1(suffix.constrained == 0)
	assert_equal('?', suffix.occurrences[1].suffixes[0])
	assert_equal(0, suffix.occurrences[1].binding)
	assert_equal(0, plan.alternatives[2].kind)
	assert_equal('*', plan.alternatives[2].occurrences[0].suffixes[0])
	assert_equal(0, plan.alternatives[2].occurrences[0].binding)


void precedence_associativity_metadata():
	at_lr_plan* plan = precedence_plan(c"grammar G; e: <assoc /* keep */ = right> lhs=e '^' rhs=e # Power | e ( <assoc=right> 'or' e ) # Nested | ID # Atom;")
	at_lr_alternative* power = plan.alternatives[0]
	assert_equal(1, power.right_associative)
	assert_equal(3, power.constrained.binding)
	assert_equal(0, power.associativity_site.resolved)
	assert_equal(0, strcmp(c"Power", power.source.label))
	assert_equal(0, strcmp(c"lhs=", power.left_operand.source.label))
	assert_equal(0, strcmp(c"rhs=", power.constrained.source.label))
	assert_equal(1, power.source.source_alternative)
	assert1(power.source.source_first != 0)
	at_lr_alternative* nested = plan.alternatives[1]
	assert_equal(3, nested.kind)
	assert_equal(0, nested.right_associative)
	assert_equal(1, nested.ignored_associativity)
	assert1(nested.associativity_site == 0)
	assert_equal(0, nested.occurrences[1].binding)
	plan = precedence_plan(c"grammar G; e: <assoc=invalid> e '+' e | ID;")
	assert_equal(1, plan.alternatives[0].invalid_associativity)
	assert_equal(0, plan.alternatives[0].right_associative)


void precedence_epsilon_sites_and_shapes():
	at_lr_plan* plan = precedence_plan(c"grammar G; e: e e | e '.'? e | e (e) | e e? | 'if' e 'fi' | ;")
	assert_equal(1, plan.alternatives[0].kind)
	assert_equal(1, plan.alternatives[1].kind)
	assert_equal(3, plan.alternatives[2].kind)
	assert_equal(0, plan.alternatives[2].occurrences[1].binding)
	assert_equal(3, plan.alternatives[3].kind)
	assert_equal(0, plan.alternatives[4].kind)
	assert_equal(0, plan.alternatives[5].kind)
	plan = precedence_plan(c"grammar G; e: {before();} e | e {after();} | e '+' e {after();} | ID;")
	assert_equal(2, plan.alternatives[0].kind)
	assert1(plan.alternatives[0].left_operand == 0)
	assert_equal(3, plan.alternatives[1].kind)
	assert_equal(1, plan.alternatives[2].kind)
	assert_equal(0, plan.alternatives[2].source.sites[0].resolved)


void precedence_action_options():
	# Options on epsilon ACTION/SEMPRED nodes do not change the adjacent
	# RULE_REF into an opted reference, even though their atom position agrees.
	at_lr_plan* plan = precedence_plan(c"grammar G; e: e '+' e {x();}<foo=bar> | e {x();}<foo=bar> '+' e | ID;")
	assert_equal(1, plan.alternatives[0].kind)
	assert_equal(1, plan.alternatives[1].kind)
	assert_equal(4, plan.alternatives[0].constrained.binding)
	assert_equal(3, plan.alternatives[1].constrained.binding)
	plan = precedence_plan(c"grammar G; e: {x();}<assoc=right> e | e '+' e | ID;")
	assert_equal(2, plan.alternatives[0].kind)
	assert_equal(0, plan.alternatives[0].right_associative)
	assert_equal(1, plan.alternatives[0].ignored_associativity)


void precedence_option_limits():
	at_lr_plan* original = precedence_plan(c"grammar G; e: <assoc=right> e '+' e | ID;")
	at_site* site = original.alternatives[0].associativity_site
	char* before = site.raw
	site.raw = c"<foreign=value,assoc=right>"
	at_lr_plan* limited = at_lr_plan_build(original.owner, 100000)
	assert_equal(0, limited.complete)
	assert_equal(0, strcmp(c"analysis_option_shape", limited.reason))
	at_lr_plan_free(limited)
	site.raw = c"<assoc=right,foreign=value>"
	limited = at_lr_plan_build(original.owner, 100000)
	assert_equal(0, limited.complete)
	assert_equal(0, strcmp(c"analysis_option_shape", limited.reason))
	at_lr_plan_free(limited)
	site.raw = before
	# Element options alter the ANTLR RULE_REF tree, while this importer's
	# matching atom is unchanged. Explicitly refuse to infer its binding.
	site.position = 1
	limited = at_lr_plan_build(original.owner, 100000)
	assert_equal(0, limited.complete)
	assert_equal(0, strcmp(c"analysis_reference_options", limited.reason))
	assert_equal(0, site.resolved)
	at_lr_plan_free(limited)
	site.position = 0
	at_lr_plan_free(original)
	list[at_rule*] rules = precedence_rules(c"grammar G; e[int x]: e[1] '+' e | ID;")
	limited = at_lr_plan_build(rules[0], 100000)
	assert_equal(0, limited.complete)
	assert_equal(0, strcmp(c"analysis_reference_arguments", limited.reason))
	at_lr_plan_free(limited)


void precedence_depth():
	list[at_rule*] rules = precedence_rules(c"grammar G; e: ID;")
	at_alt* outer = rules[0].alts[0]
	for i in range(130):
		at_element* group = new at_element()
		group.kind = 3
		group.group_alts = new list[at_alt*]
		at_alt* nested = new at_alt()
		nested.elements = outer.elements
		group.group_alts.push(nested)
		outer.elements = new list[at_element*]
		outer.elements.push(group)
	at_lr_plan* limited = at_lr_plan_build(rules[0], 100000)
	assert_equal(0, limited.complete)
	assert_equal(0, strcmp(c"analysis_depth", limited.reason))
	at_lr_plan_free(limited)


void precedence_budget():
	at_lr_plan* plan = precedence_plan(c"grammar G; e: e '+' e | '-' e | ID;")
	at_rule* source = plan.owner
	list[at_alt*] before = source.alts
	at_lr_plan* exact = at_lr_plan_build(source, plan.work)
	assert_equal(1, exact.complete)
	at_lr_plan* short_plan = at_lr_plan_build(source, plan.work - 1)
	assert_equal(0, short_plan.complete)
	assert_equal(0, strcmp(c"analysis_budget", short_plan.reason))
	assert1(source.alts == before)
	short_plan = at_lr_plan_build(source, 0)
	assert_equal(0, short_plan.complete)
	assert_equal(0, strcmp(c"analysis_budget", short_plan.reason))
	assert_equal(0, short_plan.alternatives.length)


# Machine-readable test probe for independent oracle inventory comparison.
# Usage: bin/antlr_precedence_plan_test --inspect grammar.g4 rule
int precedence_inspect(char* path, char* name):
	char* source = file_read_text(path)
	assert1(source != 0)
	list[at_rule*] rules = precedence_rules(source)
	for at_rule* rule in rules:
		if (strcmp(rule.name, name) != 0): continue
		at_lr_plan* plan = at_lr_plan_build(rule, 1000000)
		string_builder* out = string_new()
		string_append(out, cstr(f"{{\"complete\":{plan.complete},\"reason\":"))
		at_source_append_string(out, plan.reason)
		string_append(out, c",\"alternatives\":[")
		for a, alt in plan.alternatives:
			if (a > 0): string_append_char(out, ',')
			string_append(out, cstr(f"{{\"source_alt\":{alt.source_index},\"class\":"))
			at_source_append_string(out, at_lr_kind_name(alt.kind))
			string_append(out, cstr(f",\"precedence\":{alt.precedence},\"decision_index\":{alt.decision_index},\"right_associative\":{alt.right_associative},\"bindings\":["))
			for o, occurrence in alt.occurrences:
				if (o > 0): string_append_char(out, ',')
				string_append(out, cstr(f"{occurrence.binding}"))
			string_append(out, c"]}")
		string_append(out, c"]}")
		println(out.data)
		string_free(out)
		at_lr_plan_free(plan)
		return 0
	return 1


int main(int argc, int argv):
	args_init(argc, argv)
	if (argc == 4):
		assert_equal(0, strcmp(args_get(1), c"--inspect"))
		return precedence_inspect(args_get(2), args_get(3))
	precedence_classification()
	precedence_nested()
	precedence_associativity_metadata()
	precedence_epsilon_sites_and_shapes()
	precedence_action_options()
	precedence_option_limits()
	precedence_depth()
	precedence_budget()
	println(c"read-only ANTLR precedence plans passed")
	return 0
