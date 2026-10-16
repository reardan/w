# wbuild: target=antlr_parser_progress_inventory dep=antlr_to_pg
# wbuild: step="bin/wv2 --strict tools/antlr_parser_progress_inventory.w -o bin/antlr_parser_progress_inventory"
# Read original grammar roots and print bounded, read-only graph evidence as JSON.
# Usage: bin/antlr_parser_progress_inventory ROOT.g4 [DEPENDENCY.g4 ...]
import libs.extras.grammars.antlr_to_pg.ast
import libs.extras.grammars.antlr_to_pg.dependencies
import libs.extras.grammars.antlr_to_pg.normalize
import libs.extras.grammars.antlr_to_pg.classify
import libs.extras.grammars.antlr_to_pg.matchers_emit
import libs.extras.grammars.antlr_to_pg.parser_progress

json_value* progress_inventory_path(at_progress_cycle* cycle):
	json_value* path = json_array()
	if (cycle != 0):
		for char* name in cycle.path: json_array_push(path, json_string(name))
	return path

int main(int argc, int argv):
	args_init(argc, argv)
	if (args_positional_count() == 0):
		println2(c"usage: antlr_parser_progress_inventory ROOT.g4 [DEPENDENCY.g4 ...]")
		return 1
	g_seen_rule_names = new map[char*, int]
	g_at_dependencies = new list[at_site*]
	g_at_declared_modes = new list[char*]
	g_at_token_identities = new list[char*]
	g_report_lines = new list[char*]
	g_at_exact_lexer = 1
	list[char*] inputs = new list[char*]
	for i in range(args_positional_count()): inputs.push(args_positional(i))
	list[at_rule*] rules = at_load_grammar_inputs(inputs)
	if (rules == 0): return 1
	at_progress_result* result = at_progress_analyze(rules, at_progress_default_limits())
	json_value* document = json_object()
	json_object_set(document, c"schema_version", json_int(1))
	json_object_set(document, c"complete", json_bool(result.complete))
	json_object_set(document, c"exhausted", json_bool(result.exhausted))
	char* reason = result.reason
	if (reason == 0): reason = c""
	json_object_set(document, c"reason", json_string(reason))
	json_object_set(document, c"work", json_int(result.work))
	json_object_set(document, c"edge_count", json_int(result.edge_count))
	json_value* entries = json_array()
	for at_progress_fact* fact in result.order:
		json_value* entry = json_object()
		json_object_set(entry, c"rule", json_string(fact.rule.name))
		json_object_set(entry, c"nullable", json_bool(fact.nullable))
		json_object_set(entry, c"productive", json_bool(fact.productive))
		json_object_set(entry, c"self_cycle", progress_inventory_path(fact.self_cycle))
		json_object_set(entry, c"mutual_cycle", progress_inventory_path(fact.mutual_cycle))
		json_value* edges = json_array()
		for at_progress_edge* edge in fact.edges:
			json_value* item = json_object()
			json_object_set(item, c"target", json_string(edge.target))
			if (edge.source.first != 0):
				json_object_set(item, c"line", json_int(edge.source.first.line))
				json_object_set(item, c"column", json_int(edge.source.first.column))
			json_array_push(edges, item)
		json_object_set(entry, c"edges", edges)
		json_array_push(entries, entry)
	json_object_set(document, c"rules", entries)
	json_value* issues = json_array()
	for at_progress_issue* issue in result.issues:
		json_value* item = json_object()
		json_object_set(item, c"rule", json_string(issue.rule))
		json_object_set(item, c"code", json_string(issue.code))
		json_array_push(issues, item)
	json_object_set(document, c"issues", issues)
	println(json_stringify(document))
	if (result.complete == 0): return 2
	return 0
