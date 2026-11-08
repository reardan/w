# wbuild: binary=test262_runtime_runner arch=x64 dep=javascript_parser
# wbuild: target=javascript_test262 tag=tests dep=test262_runtime_runner dep=test262_conformance
# wbuild: step="bin/test262_conformance --json bin/test262-conformance.json"
# Bounded upstream Test262 profile. Fresh process and realm per variant.
import lib.args
import lib.file
import lib.path
import structures.json
import libs.extras.javascript.runtime
import libs.extras.javascript.modules


# Native harness overrides permitted by upstream INTERPRETING.md. These
# implement only the documented boolean/SameValue assertion profile.
int test262_assertions = 0

js_value* test262_failure(js_runtime* rt):
	js_value* error = js_runtime_alloc(rt, 5)
	error.intrinsic_error_name = c"Test262Error"
	js_runtime_throw(rt, error)
	return rt.undefined_value

js_value* test262_assert(void* context, list[js_value*] args):
	js_runtime* rt = cast(js_runtime*, context)
	test262_assertions = test262_assertions + 1
	if (args.length == 0): return test262_failure(rt)
	if (args[0].kind != 2 || args[0].number == 0.0): return test262_failure(rt)
	return rt.undefined_value

js_value* test262_same(void* context, list[js_value*] args):
	js_runtime* rt = cast(js_runtime*, context)
	test262_assertions = test262_assertions + 1
	js_value* a = rt.undefined_value
	js_value* b = rt.undefined_value
	if (args.length > 0): a = args[0]
	if (args.length > 1): b = args[1]
	if (js_runtime_same_value(a, b) == 0): return test262_failure(rt)
	return rt.undefined_value

js_value* test262_not_same(void* context, list[js_value*] args):
	js_runtime* rt = cast(js_runtime*, context)
	test262_assertions = test262_assertions + 1
	js_value* a = rt.undefined_value
	js_value* b = rt.undefined_value
	if (args.length > 0): a = args[0]
	if (args.length > 1): b = args[1]
	if (js_runtime_same_value(a, b)): return test262_failure(rt)
	return rt.undefined_value

js_value* test262_unsupported(void* context, list[js_value*] args):
	js_runtime* rt = cast(js_runtime*, context)
	js_runtime_fail(rt, 6, c"unsupported Test262 harness helper or host hook")
	return rt.undefined_value

js_value* test262_do_not_evaluate(void* context, list[js_value*] args):
	return test262_failure(cast(js_runtime*, context))

js_value* test262_missing_helper(void* runtime, void* context, js_value* object, js_text* key):
	if (js_runtime_property(object, key) != 0): return 0
	js_runtime* rt = cast(js_runtime*, runtime)
	js_runtime_fail(rt, 6, c"unsupported Test262 harness helper or host hook")
	return rt.undefined_value

js_value* test262_callable(js_runtime* rt, js_host_function* callback):
	js_value* value = js_runtime_alloc(rt, 9)
	value.host = cast(int, callback)
	return value

void test262_install(js_runtime* rt):
	js_runtime_bind(rt, c"assert", test262_assert)
	js_value* assertion = js_runtime_get(rt, rt.global, c"assert")
	js_runtime_set(rt, assertion, c"sameValue", test262_callable(rt, test262_same))
	js_runtime_set(rt, assertion, c"notSameValue", test262_callable(rt, test262_not_same))
	js_runtime_set(rt, assertion, c"throws", test262_callable(rt, test262_unsupported))
	js_runtime_set_host_hooks(rt, assertion, 0, test262_missing_helper, 0)
	js_runtime_bind(rt, c"$DONOTEVALUATE", test262_do_not_evaluate)
	js_runtime_bind(rt, c"$ERROR", test262_do_not_evaluate)
	js_runtime_bind(rt, c"$DONE", test262_unsupported)
	js_runtime_bind(rt, c"print", test262_unsupported)
	js_runtime_bind(rt, c"Test262Error", test262_unsupported)
	js_runtime_bind(rt, c"compareArray", test262_unsupported)
	js_runtime_bind(rt, c"formatIdentityFreeValue", test262_unsupported)
	js_runtime_bind(rt, c"formatSimpleValue", test262_unsupported)
	js_runtime_bind(rt, c"isNegativeZero", test262_unsupported)
	js_runtime_bind(rt, c"isPrimitive", test262_unsupported)
	js_value* host = js_runtime_alloc(rt, 5)
	js_runtime_set_host_hooks(rt, host, 0, test262_missing_helper, 0)
	js_runtime_set(rt, rt.global, c"$262", host)


json_value* test262_result(char* phase, char* outcome):
	json_value* result = json_object()
	json_object_set(result, c"protocol", json_int(1))
	json_object_set(result, c"phase", json_string(phase))
	json_object_set(result, c"outcome", json_string(outcome))
	return result


void test262_diagnostics(json_value* result, pg_parse_result* parsed):
	json_value* messages = json_array()
	for pg_diagnostic* item in parsed.diagnostics.items:
		json_value* diagnostic = json_object()
		json_object_set(diagnostic, c"message", json_string(item.message))
		json_object_set(diagnostic, c"line", json_int(item.line))
		json_object_set(diagnostic, c"column", json_int(item.column))
		json_array_push(messages, diagnostic)
	json_object_set(result, c"diagnostics", messages)


json_value* test262_value(js_value* value):
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


# Upstream-harness profile: the pinned harness scripts (sta.js, assert.js and
# declared includes) run unmodified in the test's realm before the test.
list[char*] test262_harness_files

char* test262_module_source_text
js_module_source* test262_module_result


# Resolves relative specifiers against the referrer's directory. Module tests
# are staged beside their pinned *_FIXTURE.js siblings by the supervisor.
js_module_source* test262_module_resolve(void* context, char* specifier, char* referrer):
	if (starts_with(specifier, c"./") == 0 && starts_with(specifier, c"../") == 0): return 0
	char* path = path_join(path_dirname(referrer), specifier)
	char* canonical = path_normalize(path)
	if (canonical == 0): return 0
	char* text = file_read_text(canonical)
	if (text == 0): return 0
	if (test262_module_result == 0): test262_module_result = new js_module_source()
	test262_module_result.identifier = canonical
	test262_module_result.source = text
	test262_module_result.length = strlen(text)
	return test262_module_result


# A thrown object created by the harness's own Test262Error constructor is
# identified by inheritance from Test262Error.prototype, not by properties
# that test code could forge.
char* test262_harness_error(js_runtime* rt, js_value* value):
	if (value.kind != 5): return 0
	js_value* expected = js_runtime_get(rt, rt.global, c"Test262Error")
	if (expected == 0 || expected.kind != 7): return 0
	js_text* key = js_runtime_key(c"prototype")
	js_value* property = js_runtime_property(expected, key)
	js_text_free(key)
	if (property == 0 || property.accessor != 0 || property.value.kind != 5): return 0
	js_value* current = value.prototype
	int depth = 0
	while (current != 0 && depth < 64):
		if (current == property.value): return c"Test262Error"
		current = current.prototype
		depth = depth + 1
	return 0


# Runs every harness file; returns 0 on success, otherwise the failed result.
json_value* test262_load_harness(js_runtime* rt, int budget):
	for char* path in test262_harness_files:
		char* text = file_read_text(path)
		if (text == 0): return test262_result(c"harness", c"error")
		js_completion* completion = js_runtime_eval(rt, text, strlen(text), budget)
		free(text)
		if (completion.status == 0): continue
		json_value* result = test262_result(c"harness", c"error")
		if (completion.status == 6): result = test262_result(c"harness", c"unsupported")
		if (completion.status == 5): result = test262_result(c"harness", c"limit")
		json_object_set(result, c"message", json_string(completion.message))
		json_object_set(result, c"file", json_string(path))
		return result
	return 0


json_value* test262_run(char* source, char* filename, int module, int budget, int raw):
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
		if (stream.resource_failed): result = test262_result(phase, c"limit")
		else:
			result = test262_result(phase, c"error")
			json_object_set(result, c"error_type", json_string(c"SyntaxError"))
		test262_diagnostics(result, parsed)
	else:
		js_node* tree = js_lower(parsed)
		if (tree == 0):
			result = test262_result(c"lower", c"unsupported")
			test262_diagnostics(result, parsed)
		else:
			# Module bodies are preflighted statement by statement by the loader.
			if (module && test262_harness_files == 0): result = test262_result(c"execute", c"unsupported")
			else if (module == 0 && js_runtime_supported(tree) == 0): result = test262_result(c"execute", c"unsupported")
			js_node_free(tree)
	pg_parse_result_free(parsed)
	if (result != 0): return result
	js_runtime* rt = js_runtime_new()
	if (raw == 0 && test262_harness_files == 0): test262_install(rt)
	if (raw == 0 && test262_harness_files != 0):
		result = test262_load_harness(rt, budget)
		if (result != 0):
			js_runtime_free(rt)
			return result
	js_completion* completion = 0
	js_modules* modules = 0
	if (module):
		modules = js_modules_new(rt, test262_module_resolve, 0)
		char* absolute = path_normalize(filename)
		if (absolute == 0): absolute = filename
		char* specifier = strjoin(c"./", path_basename(absolute))
		js_modules_evaluate(modules, specifier, absolute, budget)
		completion = rt.completion
	else: completion = js_runtime_eval(rt, source, strlen(source), budget)
	char* outcome = c"normal"
	if (completion.status == 2): outcome = c"throw"
	if (completion.status == 5): outcome = c"limit"
	if (completion.status == 6): outcome = c"unsupported"
	if (completion.status != 0 && completion.status != 2 && completion.status != 5 && completion.status != 6): outcome = c"invalid_completion"
	result = test262_result(c"execute", outcome)
	json_object_set(result, c"assertions", json_int(test262_assertions))
	if (completion.status == 2 && completion.value.intrinsic_error_name[0] != 0): json_object_set(result, c"error_type", json_string(completion.value.intrinsic_error_name))
	else if (completion.status == 2 && test262_harness_files != 0):
		char* harness_error = test262_harness_error(rt, completion.value)
		if (harness_error != 0): json_object_set(result, c"error_type", json_string(harness_error))
	json_object_set(result, c"steps", json_int(completion.steps))
	json_object_set(result, c"message", json_string(completion.message))
	json_object_set(result, c"value", test262_value(completion.value))
	if (modules != 0): js_modules_free(modules)
	js_runtime_free(rt)
	return result


int main(int argc, int argv):
	args_init(argc, argv)
	if (argc < 5):
		println(c"usage: test262_runtime_runner FILE script|module BUDGET harness|raw|upstream [HARNESS.js...]")
		return 2
	char* profile = args_get(4)
	if (strcmp(profile, c"raw") != 0 && strcmp(profile, c"harness") != 0 && strcmp(profile, c"upstream") != 0): return 2
	if (strcmp(profile, c"upstream") == 0):
		test262_harness_files = new list[char*]
		for i in range(5, argc): test262_harness_files.push(args_get(i))
	else if (argc != 5): return 2
	char* goal = args_get(2)
	if (strcmp(goal, c"script") != 0 && strcmp(goal, c"module") != 0): return 2
	int budget = 0
	char* raw_budget = args_get(3)
	for i in range(strlen(raw_budget)):
		if (raw_budget[i] < '0' || raw_budget[i] > '9' || budget > 10000000): return 2
		budget = budget * 10 + raw_budget[i] - '0'
	if (budget <= 0 || budget > 10000000): return 2
	char* source = file_read_text(args_get(1))
	if (source == 0): return 2
	json_value* result = test262_run(source, args_get(1), strcmp(goal, c"module") == 0, budget, strcmp(args_get(4), c"raw") == 0)
	char* output = json_stringify(result)
	println(output)
	free(output)
	json_free(result)
	free(source)
	return 0
