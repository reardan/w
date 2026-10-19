# wbuild: target=antlr_audit_json_test tag=tests dep=antlr_to_pg dep=antlr_audit_driver
# wbuild: step="bin/wv2 tests/antlr_audit_json_test.w -o bin/antlr_audit_json_test"
# wbuild: step="bin/antlr_audit_json_test"
# wbuild: step="bin/antlr_audit_driver"
import lib.testing
import libs.extras.grammars.antlr_to_pg.audit_json
import libs.extras.grammars.antlr_to_pg.recursion_diagnostics

void test_structured_finding_escapes_and_location():
	at_finding(c"AT_TEST", c"translate", c"test", c"unproven", c"quoted\"file.g4", 12, 7, c"root", c"reason\nline")
	json_value* finding = json_array_get(g_at_audit_findings, 0)
	assert_equal(12, json_object_get(finding, c"line").int_value)
	assert_strings_equal(c"AT_TEST", json_object_get(finding, c"code").string_value)
	char* encoded = json_stringify(finding)
	json_value* decoded = json_parse(encoded)
	assert1(decoded != 0)
	assert_strings_equal(c"reason\nline", json_object_get(decoded, c"reason").string_value)
	json_free(decoded)
	free(encoded)

void test_normalization_guard_is_separate_from_cycle_reason():
	g_at_audit_findings = json_array()
	g_at_normalization_guards = new map[char*, json_value*]
	at_rule* rule = new at_rule()
	rule.name = c"expr"
	assert_equal(0, at_normalization_guard(rule, c"prediction_expression", 2, c"operator_prefix_not_proven"))
	at_finding(c"AT_LEFT_RECURSION", c"translate", c"left_recursion", c"unsupported", c"test.g4", 1, 1, rule.name, c"unchanged human reason")
	json_value* finding = json_array_get(g_at_audit_findings, 0)
	json_value* details = json_object_get(finding, c"details")
	assert_strings_equal(c"remaining_nullable_prefix_cycle", json_object_get(details, c"reason_code").string_value)
	json_value* guard = json_array_get(json_object_get(details, c"normalization_guards"), 0)
	assert_strings_equal(c"operator_prefix_not_proven", json_object_get(guard, c"reason_code").string_value)
	assert_equal(2, json_object_get(guard, c"source_alternative").int_value)
	at_finding(c"AT_HOST_SITE", c"translate", c"host", c"unsupported", c"test.g4", 1, 1, rule.name, c"host")
	assert1(json_object_get(json_array_get(g_at_audit_findings, 1), c"details") == 0)

void test_partial_graph_reports_exhaustion_for_uncollected_rule():
	list[at_rule*] rules = new list[at_rule*]
	at_rule* first = new at_rule()
	first.name = c"first"
	first.alts = new list[at_alt*]
	rules.push(first)
	at_rule* late = new at_rule()
	late.name = c"late"
	late.alts = new list[at_alt*]
	rules.push(late)
	at_progress_limits* limits = at_progress_default_limits()
	limits.max_rules = 1
	at_progress_result* result = at_progress_analyze(rules, limits)
	assert1(result.exhausted)
	assert1((late.name in result.facts) == 0)
	g_at_audit_findings = json_array()
	g_at_lr_remaining_details = new map[char*, json_value*]
	g_at_lr_remaining_details[c""] = at_lr_diagnostic_graph(result, c"")
	at_finding(c"AT_LEFT_RECURSION", c"translate", c"left_recursion", c"unsupported", c"test.g4", 1, 1, late.name, c"cycle")
	json_value* details = json_object_get(json_array_get(g_at_audit_findings, 0), c"details")
	json_value* graph = json_object_get(details, c"remaining_graph")
	assert_equal(0, json_object_get(graph, c"complete").int_value)
	assert_strings_equal(c"parser_tokens", json_object_get(graph, c"scope").string_value)
	assert_strings_equal(c"rule_limit", json_object_get(graph, c"reason_code").string_value)
	assert1(json_object_get(graph, c"nullable") == 0)
	assert_equal(0, json_array_length(json_object_get(graph, c"cycles")))
	# An unrelated library audit must not inherit a previous grammar's source.
	at_lr_diagnostics_source(rules)
	at_normalization_guard(late, c"prediction_expression", 1, c"old_guard")
	list[at_rule*] other = new list[at_rule*]
	other.push(late)
	at_lr_diagnostics_remaining(other)
	assert1((late.name in g_at_lr_source_details) == 0)
	assert1((late.name in g_at_normalization_guards) == 0)
	# An incomplete plan cannot claim that recursion is absent.
	at_alt* alt = new at_alt()
	alt.elements = new list[at_element*]
	late.alts.push(alt)
	at_lr_plan* plan = at_lr_plan_build(late, 0)
	json_value* partial = at_lr_diagnostic_plan(plan)
	assert_equal(0, json_object_get(partial, c"complete").int_value)
	assert1(json_object_get(partial, c"direct_recursive") == 0)
	assert_equal(0, json_array_length(json_object_get(partial, c"alternatives")))
	at_lr_plan_free(plan)
