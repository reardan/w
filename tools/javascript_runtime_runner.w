# wbuild: binary=javascript_runtime_runner arch=x64 dep=javascript_parser
# wbuild: target=javascript_conformance tag=tests dep=javascript_runtime_runner
# wbuild: step="python3 tools/javascript_conformance.py"
# wbuild: step="python3 tests/javascript/conformance_runner_test.py"
# One process, one realm. JSON protocol v1; semantic failures are data, CLI
# misuse/I/O failures exit nonzero. This is a native fixture driver, not Test262.
import lib.args
import lib.file
import structures.json
import libs.extras.javascript.runtime


json_value* runner_result(char* phase, char* outcome):
	json_value* result = json_object()
	json_object_set(result, c"protocol", json_int(1))
	json_object_set(result, c"phase", json_string(phase))
	json_object_set(result, c"outcome", json_string(outcome))
	return result


void runner_diagnostics(json_value* result, pg_parse_result* parsed):
	json_value* messages = json_array()
	for pg_diagnostic* item in parsed.diagnostics.items:
		json_value* diagnostic = json_object()
		json_object_set(diagnostic, c"message", json_string(item.message))
		json_object_set(diagnostic, c"line", json_int(item.line))
		json_object_set(diagnostic, c"column", json_int(item.column))
		json_array_push(messages, diagnostic)
	json_object_set(result, c"diagnostics", messages)


json_value* runner_value(js_value* value):
	json_value* result = json_object()
	char* kind = c"object"
	if (value.kind == 0): kind = c"undefined"
	if (value.kind == 1): kind = c"null"
	if (value.kind == 2): kind = c"boolean"
	if (value.kind == 3): kind = c"number"
	if (value.kind == 4): kind = c"string"
	json_object_set(result, c"type", json_string(kind))
	if (value.kind == 2): json_object_set(result, c"value", json_bool(value.number != 0.0))
	if (value.kind == 3):
		char* number = f64toa(value.number)
		json_object_set(result, c"value", json_string(number))
		free(number)
	if (value.kind == 4):
		json_value* units = json_array()
		for int unit in value.text.units: json_array_push(units, json_int(unit))
		json_object_set(result, c"units", units)
	return result


json_value* runner_run(char* source, char* filename, int module, int budget):
	# Use the same generated grammar and validator sequence as js_parse, with
	# an observation boundary before early-error validation. No syntax is
	# reimplemented here. Runtime evaluation still goes through the public API.
	pg_diagnostics* diagnostics = pg_diagnostics_new()
	pg_token_stream* stream = pg_token_stream_from_provider(javascript_provider_new(source, strlen(source), filename), javascript_next, diagnostics)
	pg_parse_result* parsed = pg_parse_result_new(stream, diagnostics)
	parsed.root = javascript_parse_program(stream, diagnostics)
	if (parsed.root == 0 || pg_token_stream_done(stream) == 0): pg_syntax_error(diagnostics, pg_token_stream_furthest(stream), c"program")
	pg_token_stream_report_resource(stream)
	parsed.success = parsed.root != 0 && diagnostics.items.length == 0 && stream.resource_failed == 0
	char* phase = c"parse"
	if (parsed.success):
		phase = c"early"
		js_validate(parsed, module)
		js_validate_bindings(parsed, module)
		js_validate_restrictions(parsed, module)
	json_value* result = 0
	if (parsed.success == 0):
		if (stream.resource_failed): result = runner_result(phase, c"limit")
		else:
			result = runner_result(phase, c"error")
			json_object_set(result, c"error_type", json_string(c"SyntaxError"))
		runner_diagnostics(result, parsed)
	else:
		js_node* tree = js_lower(parsed)
		if (tree == 0):
			result = runner_result(c"lower", c"unsupported")
			runner_diagnostics(result, parsed)
		else:
			if (module || js_runtime_supported(tree) == 0): result = runner_result(c"execute", c"unsupported")
			js_node_free(tree)
	pg_parse_result_free(parsed)
	if (result != 0): return result
	js_runtime* rt = js_runtime_new()
	js_completion* completion = js_runtime_eval(rt, source, strlen(source), budget)
	char* outcome = c"normal"
	if (completion.status == 2): outcome = c"throw"
	if (completion.status == 5): outcome = c"limit"
	if (completion.status == 6): outcome = c"unsupported"
	if (completion.status != 0 && completion.status != 2 && completion.status != 5 && completion.status != 6): outcome = c"invalid_completion"
	result = runner_result(c"execute", outcome)
	json_object_set(result, c"steps", json_int(completion.steps))
	json_object_set(result, c"message", json_string(completion.message))
	json_object_set(result, c"value", runner_value(completion.value))
	js_runtime_free(rt)
	return result


int main(int argc, int argv):
	args_init(argc, argv)
	if (argc != 4):
		println(c"usage: javascript_runtime_runner FILE script|module BUDGET")
		return 2
	char* goal = args_get(2)
	if (strcmp(goal, c"script") != 0 && strcmp(goal, c"module") != 0): return 2
	int budget = 0
	char* raw_budget = args_get(3)
	for i in range(strlen(raw_budget)):
		if (raw_budget[i] < '0' || raw_budget[i] > '9' || budget > 10000000): return 2
		budget = budget * 10 + raw_budget[i] - '0'
	if (budget <= 0): return 2
	char* source = file_read_text(args_get(1))
	if (source == 0): return 2
	json_value* result = runner_run(source, args_get(1), strcmp(goal, c"module") == 0, budget)
	char* output = json_stringify(result)
	println(output)
	free(output)
	json_free(result)
	free(source)
	return 0
