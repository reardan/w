# wbuild: target=antlr_to_pg_precedence_lowering_test tag=tests dep=antlr_to_pg
# wbuild: step="bin/wv2 --strict tests/antlr_to_pg_precedence_lowering_test.w -o bin/antlr_to_pg_precedence_lowering_test"
# wbuild: step="bin/antlr_to_pg_precedence_lowering_test"
# wbuild: step="bin/wv2 x64 --strict tests/antlr_to_pg_precedence_lowering_test.w -o bin/antlr_to_pg_precedence_lowering_test_x64"
# wbuild: step="bin/antlr_to_pg_precedence_lowering_test_x64"
# wbuild: target=antlr_tree_differential_test tag=tests dep=antlr_to_pg
# wbuild: step="python3 tests/antlr_tree_differential.py"
# Plan-driven left-recursion lowering (normalize_precedence.w): accepted
# shapes publish the documented helper layout; every refusal is atomic and
# records a stable guard reason.
import lib.assert
import bin.generated_antlr4_parser
import libs.extras.grammars.antlr_to_pg.ast
import libs.extras.grammars.antlr_to_pg.normalize
import libs.extras.grammars.antlr_to_pg.classify
import libs.extras.grammars.antlr_to_pg.matchers_emit
import libs.extras.grammars.antlr_to_pg.emit


list[at_rule*] lowering_rules(char* source):
	g_at_source = source
	g_seen_rule_names = new map[char*, int]
	g_at_dependencies = new list[at_site*]
	g_at_declared_modes = new list[char*]
	g_at_token_identities = new list[char*]
	g_at_normalization_guards = new map[char*, json_value*]
	g_at_prediction = 1
	pg_diagnostics* diagnostics = pg_diagnostics_new()
	pg_ast_node* root = antlr4_parse(source, c"lowering.g4", diagnostics)
	assert1(root != 0)
	assert_equal(0, diagnostics.items.length)
	list[at_rule*] rules = at_collect_rules(root)
	at_source_prepare(rules)
	at_audit_prepare_rules(rules)
	return rules


# The last recorded guard for the first rule.
char* lowering_guard(at_rule* rule):
	json_value* guards = g_at_normalization_guards.get(rule.name, 0)
	assert1(guards != 0)
	json_value* last = guards.array_values[guards.array_values.length - 1]
	assert_strings_equal(c"prediction_plan", json_object_get(last, c"normalizer").string_value)
	return json_object_get(last, c"reason_code").string_value


void lowering_refuse(char* source, char* reason):
	list[at_rule*] rules = lowering_rules(source)
	list[at_alt*] before = rules[0].alts
	int count = rules.length
	assert_equal(0, at_normalize_prediction_plan(rules[0], rules))
	assert_equal(count, rules.length)
	assert1(before == rules[0].alts)
	assert_strings_equal(reason, lowering_guard(rules[0]))


# Returns the rendered alternatives of a helper, e.g. "e_primary 'x' | ...".
char* lowering_render(at_rule* rule):
	string_builder* out = string_new()
	string_append(out, rule.name)
	for i, alt in rule.alts:
		if (i > 0): string_append(out, c" |")
		for at_element* element in alt.elements:
			string_append_char(out, ' ')
			if (element.kind == 3):
				string_append(out, c"(")
				for j, nested in element.group_alts:
					if (j > 0): string_append(out, c" |")
					if (nested.tree_role == 2): string_append(out, c" fold:")
					for at_element* part in nested.elements:
						string_append_char(out, ' ')
						string_append(out, part.text)
						if (part.suffix != 0): string_append_char(out, part.suffix)
				string_append(out, c" )")
			else: string_append(out, element.text)
			if (element.suffix != 0): string_append_char(out, element.suffix)
	return out.data


void lowering_predicates_into(string_builder* out, char* rule, list[at_alt*] alts):
	for i, alt in alts:
		if (alt.sites != 0):
			for at_site* site in alt.sites:
				if (strcmp(site.kind, c"predicate") != 0): continue
				if (out.length > 0): string_append_char(out, ' ')
				string_append(out, cstr(f"{rule}:{i}:{site.position}:{site.raw}"))
		for at_element* element in alt.elements:
			if (element.kind == 3): lowering_predicates_into(out, rule, element.group_alts)


# Every predicate site left on the rules, as rule:alternative:position:text.
char* lowering_predicates(list[at_rule*] rules):
	string_builder* out = string_new()
	for at_rule* rule in rules: lowering_predicates_into(out, rule.name, rule.alts)
	return out.data


void lowering_accept(char* source, list[char*] expected):
	list[at_rule*] rules = lowering_rules(source)
	int count = rules.length
	assert_equal(1, at_normalize_prediction_plan(rules[0], rules))
	assert_equal(count + expected.length - 1, rules.length)
	assert_strings_equal(expected[0], lowering_render(rules[0]))
	for i in range(1, expected.length): assert_strings_equal(expected[i], lowering_render(rules[count + i - 1]))


int main():
	# Adjacent operands and an optional separator: the operand consumes.
	list[char*] adjacent = new list[char*]
	adjacent.push(c"e e_bp1")
	adjacent.push(c"e_primary ID")
	adjacent.push(c"e_bp0 e_primary ( fold: e_primary )*")
	adjacent.push(c"e_bp1 e_primary ( fold: e_primary | fold: ,? e_bp0 )*")
	lowering_accept(c"grammar G; e: e e | e ','? e | ID; ID: [a-z]+;", adjacent)
	# Binary tails precede suffix tails (ANTLR's decision order); a right
	# associative operand calls its own tier; a prefix binds at its level;
	# undelimited ordinary owner calls remain full-precedence calls to e.
	list[char*] mixed = new list[char*]
	mixed.push(c"e e_bp2")
	mixed.push(c"e_primary - e_bp0 | return e? | ID")
	mixed.push(c"e_bp0 e_primary ( fold: . ID )*")
	mixed.push(c"e_bp1 e_primary ( fold: ^ e_bp1 | fold: . ID )*")
	mixed.push(c"e_bp2 e_primary ( fold: ^ e_bp1 | fold: e_bp1 | fold: . ID )*")
	lowering_accept(c"grammar G; e: e '.' ID | '-' e | <assoc=right> e '^' e | e e | 'return' e? | ID; ID: [a-z]+;", mixed)
	# A nullable primary is accepted when every tail consumes on its own.
	list[char*] nullable = new list[char*]
	nullable.push(c"e e_bp1")
	nullable.push(c"e_primary")
	nullable.push(c"e_bp0 e_primary ( fold: , ID )*")
	nullable.push(c"e_bp1 e_primary ( fold: , ID | fold: ;? ID )*")
	lowering_accept(c"grammar G; e: e ',' ID | e ';'? ID | ; ID: [a-z]+;", nullable)
	# Host predicates (Z's `expression`) lower as if they held. Each one stays
	# on exactly one lowered alternative, shifted past the dropped left
	# operand, so the audit still reports it once as an ignored host site.
	list[char*] predicated = new list[char*]
	predicated.push(c"e e_bp1")
	predicated.push(c"e_primary ID")
	predicated.push(c"e_bp0 e_primary ( fold: I e_primary )*")
	predicated.push(c"e_bp1 e_primary ( fold: I e_primary | fold: I e_bp1 )*")
	char* z_shape = c"grammar G; e: e {left(_input)}? I e | <assoc=right> e I e | {p()}? ID; I: '~'; ID: [a-z]+;"
	lowering_accept(z_shape, predicated)
	list[at_rule*] rules = lowering_rules(z_shape)
	assert_equal(1, at_normalize_prediction_plan(rules[0], rules))
	assert_strings_equal(c"e_primary:0:0:{p()}? e_bp0:0:0:{left(_input)}?", lowering_predicates(rules))
	# Refusals keep the original graph.
	lowering_refuse(c"grammar G; e: '(' e ')' | ID; ID: [a-z]+;", c"not_direct_recursive")
	lowering_refuse(c"grammar G; e: e {host();} '+' e | ID; ID: [a-z]+;", c"element_semantics")
	lowering_refuse(c"grammar G; e: e '+'*? e | ID; ID: [a-z]+;", c"element_semantics")
	lowering_refuse(c"grammar G; e: <assoc=middle> e '+' e | ID; ID: [a-z]+;", c"alternative_options")
	lowering_refuse(c"grammar G; e: e '!'? | ID; ID: [a-z]+;", c"nullable_operator_tail")
	lowering_refuse(c"grammar G; e: e ','? e | ; ID: [a-z]+;", c"nullable_operator_tail")
	lowering_refuse(c"grammar G; e: e x '!' | ; x: e?; ID: [a-z]+;", c"tail_nullable_prefix_cycle")
	lowering_refuse(c"grammar G; e: e '+' e | alias; alias: e; ID: [a-z]+;", c"primary_nullable_prefix_cycle")
	lowering_refuse(c"grammar G; e: e '+' e | '-'? e | ID; ID: [a-z]+;", c"primary_prefix_not_proven")
	lowering_refuse(c"grammar G; e: e '+' e | x e | ID; x: e '!'; ID: [a-z]+;", c"primary_nullable_prefix_cycle")
	lowering_refuse(c"grammar G; e: e '+' e | e '-' e; ID: [a-z]+;", c"missing_operator_or_primary")
	lowering_refuse(c"grammar G; e: e '+' e | '(' e ')'; ID: [a-z]+;", c"base_not_proven_productive")
	lowering_refuse(c"grammar G; e options { k = 1; }: e '+' e | ID; ID: [a-z]+;", c"rule_options")
	println(c"plan-driven precedence lowering: accepted shapes and atomic refusals")
	return 0
