# Additive evidence for existing recursion refusals. These analyses do not
# relax or replace the normalizer, final audit, or downstream safety checks.
import libs.extras.grammars.antlr_to_pg.audit_json
import libs.extras.grammars.antlr_to_pg.parser_progress
import libs.extras.grammars.antlr_to_pg.precedence_plan

list[at_rule*] g_at_lr_source_input

void at_lr_diagnostic_location(json_value* item, pg_token* location):
	if (location == 0): return
	json_object_set(item, c"file", json_string(location.filename))
	json_object_set(item, c"line", json_int(location.line))
	json_object_set(item, c"column", json_int(location.column))

json_value* at_lr_diagnostic_plan(at_lr_plan* plan):
	json_value* value = json_object()
	json_object_set(value, c"scope", json_string(c"antlr_4_13_2_candidate_analysis"))
	json_object_set(value, c"complete", json_bool(plan.complete))
	json_object_set(value, c"reason_code", json_string(plan.reason))
	json_object_set(value, c"work", json_int(plan.work))
	json_object_set(value, c"work_limit", json_int(plan.work_limit))
	if (plan.complete): json_object_set(value, c"direct_recursive", json_bool(plan.direct_recursive))
	json_value* alternatives = json_array()
	# Incomplete descriptors are never presented as semantic conclusions.
	if (plan.complete):
		for at_lr_alternative* alt in plan.alternatives:
			json_value* item = json_object()
			json_object_set(item, c"source_alternative", json_int(alt.source_index))
			json_object_set(item, c"kind", json_string(at_lr_kind_name(alt.kind)))
			json_object_set(item, c"precedence", json_int(alt.precedence))
			json_object_set(item, c"primary_binding", json_int(alt.primary_binding))
			json_object_set(item, c"right_associative", json_bool(alt.right_associative))
			json_object_set(item, c"invalid_associativity", json_bool(alt.invalid_associativity))
			json_object_set(item, c"ignored_associativity", json_int(alt.ignored_associativity))
			json_object_set(item, c"decision_index", json_int(alt.decision_index))
			if (alt.source.label != 0): json_object_set(item, c"label", json_string(alt.source.label))
			pg_token* location = alt.source.source_first
			if ((location == 0) && (alt.source.elements.length > 0)): location = alt.source.elements[0].first
			if (location == 0): location = plan.owner.first
			at_lr_diagnostic_location(item, location)
			json_value* occurrences = json_array()
			for at_lr_occurrence* occurrence in alt.occurrences:
				json_value* entry = json_object()
				json_value* path = json_array()
				for int component in occurrence.path: json_array_push(path, json_int(component))
				json_object_set(entry, c"path", path)
				json_value* suffixes = json_array()
				for int suffix in occurrence.suffixes: json_array_push(suffixes, json_int(suffix))
				json_object_set(entry, c"suffixes", suffixes)
				char* role = c"ordinary"
				if (occurrence.role == 1): role = c"left_operand"
				if (occurrence.role == 2): role = c"constrained"
				json_object_set(entry, c"role", json_string(role))
				json_object_set(entry, c"binding", json_int(occurrence.binding))
				if (occurrence.source.label != 0): json_object_set(entry, c"label", json_string(occurrence.source.label))
				at_lr_diagnostic_location(entry, occurrence.source.first)
				json_array_push(occurrences, entry)
			json_object_set(item, c"occurrences", occurrences)
			json_array_push(alternatives, item)
	json_object_set(value, c"alternatives", alternatives)
	return value

void at_lr_diagnostic_cycle(json_value* cycles, at_progress_cycle* cycle):
	if (cycle == 0): return
	json_value* item = json_object()
	json_object_set(item, c"mutual", json_bool(cycle.mutual))
	json_value* path = json_array()
	for char* name in cycle.path: json_array_push(path, json_string(name))
	json_object_set(item, c"path", path)
	json_array_push(cycles, item)

json_value* at_lr_diagnostic_graph(at_progress_result* result, char* name):
	json_value* graph = json_object()
	json_object_set(graph, c"scope", json_string(c"parser_tokens"))
	json_object_set(graph, c"complete", json_bool(result.complete))
	json_object_set(graph, c"exhausted", json_bool(result.exhausted))
	char* reason = result.reason
	if (reason == 0): reason = c""
	json_object_set(graph, c"reason_code", json_string(reason))
	json_object_set(graph, c"work", json_int(result.work))
	json_object_set(graph, c"work_limit", json_int(result.limits.max_work))
	json_object_set(graph, c"rule_count", json_int(result.order.length))
	json_object_set(graph, c"edge_count", json_int(result.edge_count))
	json_value* cycles = json_array()
	at_progress_fact* fact = result.facts.get(name, 0)
	if ((fact != 0) && result.complete):
		json_object_set(graph, c"nullable", json_bool(fact.nullable))
		json_object_set(graph, c"productive", json_bool(fact.productive))
		at_lr_diagnostic_cycle(cycles, fact.self_cycle)
		at_lr_diagnostic_cycle(cycles, fact.mutual_cycle)
	json_object_set(graph, c"cycles", cycles)
	return graph

# Snapshot original facts before any legacy or prediction lowering mutates the
# rule graph. A budget refusal is diagnostic evidence, never an acceptance gate.
void at_lr_diagnostics_source(list[at_rule*] rules):
	g_at_lr_source_input = rules
	g_at_lr_source_details = new map[char*, json_value*]
	g_at_lr_remaining_details = new map[char*, json_value*]
	at_progress_result* result = at_progress_analyze(rules, at_progress_default_limits())
	if (result.complete == 0):
		json_value* fallback = json_object()
		json_object_set(fallback, c"graph", at_lr_diagnostic_graph(result, c""))
		g_at_lr_source_details[c""] = fallback
	int remaining_work = 1000000
	for at_progress_fact* fact in result.order:
		json_value* source = json_object()
		json_object_set(source, c"graph", at_lr_diagnostic_graph(result, fact.rule.name))
		at_lr_plan* plan = at_lr_plan_build(fact.rule, remaining_work)
		remaining_work = remaining_work - plan.work
		json_object_set(source, c"plan", at_lr_diagnostic_plan(plan))
		at_lr_plan_free(plan)
		g_at_lr_source_details[fact.rule.name] = source

void at_lr_diagnostics_remaining(list[at_rule*] rules):
	# Library callers may audit directly, without invoking normalization.
	if (rules != g_at_lr_source_input):
		g_at_lr_source_details = new map[char*, json_value*]
		g_at_normalization_guards = new map[char*, json_value*]
	g_at_lr_remaining_details = new map[char*, json_value*]
	at_progress_result* result = at_progress_analyze(rules, at_progress_default_limits())
	if (result.complete == 0): g_at_lr_remaining_details[c""] = at_lr_diagnostic_graph(result, c"")
	for at_progress_fact* fact in result.order:
		if ((result.complete == 0) || (fact.self_cycle != 0) || (fact.mutual_cycle != 0)):
			g_at_lr_remaining_details[fact.rule.name] = at_lr_diagnostic_graph(result, fact.rule.name)
