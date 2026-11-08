# wbuild: binary=test262_runtime_runner arch=x64 dep=javascript_parser
# wbuild: target=javascript_test262 tag=tests dep=test262_runtime_runner dep=test262_conformance data=tests/javascript/test262/
# wbuild: step="bin/test262_conformance --native-only --json bin/test262-conformance.json" timeout=1800000
# wbuild: target=javascript_test262_upstream tag=tests dep=test262_runtime_runner dep=test262_conformance data=tests/javascript/test262/
# wbuild: step="bin/test262_conformance --upstream-only --json bin/test262-upstream.json" timeout=1800000
# Bounded upstream Test262 profile. Fresh process and realm per variant.
import lib.args
import lib.file
import lib.path
import structures.json
import libs.extras.javascript.runtime
import libs.extras.javascript.modules
import libs.extras.javascript.module_graph


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

# Native regExpUtils.js overrides (reardan/w#901; INTERPRETING.md lets hosts
# override harness functions). Property-escape tests build strings of up to
# 1.1M code points, beyond the runtime's string length cap, so buildString
# returns an opaque object whose UTF-16 units stay host-side.
# testPropertyEscapes then follows upstream: the RegExp's matcher runs on the
# whole string (as RegExp.prototype.test would, without lastIndex since the
# generated patterns have no g or y flag) and, if that fails, on each symbol,
# asserting that every symbol matches. The matching runs on its own step
# budget, restored afterwards.
list[js_value*] test262_built_objects
list[list[int]] test262_built_units
int test262_helper_budget = 200000000

int test262_array_length(js_runtime* rt, js_value* array):
	js_value* length = js_runtime_get(rt, array, c"length")
	if (length.kind != 3): return -1
	return cast(int, length.number)

int test262_code_point(js_value* value):
	if (value.kind != 3 || value.number < 0.0 || value.number > 1114111.0): return -1
	int cp = cast(int, value.number)
	if (cast(float64, cp) != value.number): return -1
	return cp

void test262_push_scalar(list[int] units, int cp):
	if (cp <= 65535): units.push(cp)
	else:
		units.push(55296 + ((cp - 65536) >> 10))
		units.push(56320 + ((cp - 65536) & 1023))

js_value* test262_build_string(void* context, list[js_value*] args):
	js_runtime* rt = cast(js_runtime*, context)
	if (args.length == 0 || (args[0].kind != 5 && args[0].kind != 6)): return test262_failure(rt)
	js_value* lone = js_runtime_get(rt, args[0], c"loneCodePoints")
	js_value* ranges = js_runtime_get(rt, args[0], c"ranges")
	int lone_count = test262_array_length(rt, lone)
	int range_count = test262_array_length(rt, ranges)
	if (lone_count < 0 || range_count < 0): return test262_failure(rt)
	list[int] units = new list[int]
	for i in range(lone_count):
		int cp = test262_code_point(js_runtime_index_get(rt, lone, i))
		if (cp < 0): return test262_failure(rt)
		test262_push_scalar(units, cp)
	for i in range(range_count):
		js_value* range = js_runtime_index_get(rt, ranges, i)
		int first = test262_code_point(js_runtime_index_get(rt, range, 0))
		int last = test262_code_point(js_runtime_index_get(rt, range, 1))
		if (first < 0 || last < 0): return test262_failure(rt)
		for cp in range(first, last + 1): test262_push_scalar(units, cp)
	js_value* result = js_runtime_alloc(rt, 5)
	if (test262_built_objects == 0):
		test262_built_objects = new list[js_value*]
		test262_built_units = new list[list[int]]
	test262_built_objects.push(result)
	test262_built_units.push(units)
	return result

# RegExpBuiltinExec's search loop (no lastIndex) over input; 1 on a match,
# 0 on none, -1 when the step budget ran out.
int test262_regexp_search(js_runtime* rt, js_regexp_program* program, list[int] input):
	js_regexp_vm* vm = js_regexp_vm_new(rt, program, input)
	int found = 0
	int index = 0
	while (found == 0 && vm.aborted == 0 && index <= input.length):
		if (js_regexp_match_at(vm, index) >= 0): found = 1
		int width = 1
		if (vm.unicode): js_regexp_read(vm, index, 1, &width)
		index = index + width
	if (vm.aborted): found = -1
	js_regexp_vm_free(vm)
	return found

js_value* test262_test_property_escapes(void* context, list[js_value*] args):
	js_runtime* rt = cast(js_runtime*, context)
	test262_assertions = test262_assertions + 1
	if (args.length < 2 || args[0].regexp == 0): return test262_failure(rt)
	js_regexp_program* program = cast(js_regexp_program*, args[0].regexp)
	if (program.flags & (JS_RX_GLOBAL | JS_RX_STICKY)): return test262_failure(rt)
	list[int] units = 0
	if (test262_built_objects == 0): return test262_failure(rt)
	for i in range(test262_built_objects.length):
		if (test262_built_objects[i] == args[1]): units = test262_built_units[i]
	if (units == 0): return test262_failure(rt)
	int remaining = rt.remaining
	rt.remaining = test262_helper_budget
	int ok = test262_regexp_search(rt, program, units)
	if (ok == 0):
		ok = 1
		list[int] symbol = new list[int]
		int i = 0
		while (ok == 1 && i < units.length):
			symbol.clear()
			symbol.push(units[i])
			if (i + 1 < units.length && units[i] >= 55296 && units[i] <= 56319 && units[i + 1] >= 56320 && units[i + 1] <= 57343):
				i = i + 1
				symbol.push(units[i])
			ok = test262_regexp_search(rt, program, symbol)
			i = i + 1
		__w_list_free(cast(__w_list*, symbol))
	rt.remaining = remaining
	if (rt.completion.status != 0): return rt.undefined_value
	if (ok != 1): return test262_failure(rt)
	return rt.undefined_value

# Asynchronous tests (flags: [async], reardan/w#906). The test signals its
# outcome through $DONE: natively in the harness profile, and through the
# pinned doneprintHandle.js, whose print calls the runner observes, in the
# upstream profile. After the script, the runner drains the microtask queue
# within the remaining step budget; the test passes when $DONE was called
# exactly once without an error.
int test262_async = 0
int test262_done_calls = 0
int test262_done_failed = 0
js_value* test262_done_error = 0

js_value* test262_done(void* context, list[js_value*] args):
	js_runtime* rt = cast(js_runtime*, context)
	test262_done_calls = test262_done_calls + 1
	if (args.length > 0 && js_runtime_truth(args[0])):
		test262_done_failed = 1
		test262_done_error = args[0]
	return rt.undefined_value

int test262_text_starts(js_text* text, char* prefix):
	if (text.units.length < strlen(prefix)): return 0
	for i in range(strlen(prefix)):
		if (text.units[i] != prefix[i]): return 0
	return 1

# doneprintHandle.js reports through print('Test262:AsyncTest...').
js_value* test262_print(void* context, list[js_value*] args):
	js_runtime* rt = cast(js_runtime*, context)
	if (args.length > 0 && args[0].kind == 4):
		if (test262_text_starts(args[0].text, c"Test262:AsyncTestComplete")): test262_done_calls = test262_done_calls + 1
		else if (test262_text_starts(args[0].text, c"Test262:AsyncTestFailure:")):
			test262_done_calls = test262_done_calls + 1
			test262_done_failed = 1
	return rt.undefined_value

js_value* test262_error_object(js_runtime* rt):
	js_value* error = js_runtime_alloc(rt, 5)
	error.intrinsic_error_name = c"Test262Error"
	return error

js_value* test262_argument(js_runtime* rt, list[js_value*] args, int index):
	if (index < args.length): return args[index]
	return rt.undefined_value

js_value* test262_then(js_runtime* rt, js_value* value, js_value* fulfilled, js_value* rejected):
	js_value* then = js_runtime_get(rt, value, c"then")
	if (rt.completion.status != 0): return rt.undefined_value
	if (js_runtime_callable(then) == 0):
		js_runtime_fail(rt, 2, c"value is not a thenable")
		return rt.undefined_value
	list[js_value*] args = new list[js_value*]
	args.push(fulfilled)
	args.push(rejected)
	js_value* result = js_runtime_call_receiver(rt, then, value, args)
	__w_list_free(cast(__w_list*, args))
	return result

# Native asyncHelpers.js overrides: asyncTest and assert.throwsAsync.
js_value* test262_async_settled(void* runtime, void* context, js_value* receiver, list[js_value*] args):
	js_runtime* rt = cast(js_runtime*, runtime)
	list[js_value*] done = new list[js_value*]
	if (context != 0): done.push(test262_argument(rt, args, 0))
	test262_done(rt, done)
	__w_list_free(cast(__w_list*, done))
	return rt.undefined_value

js_value* test262_async_test(void* context, list[js_value*] args):
	js_runtime* rt = cast(js_runtime*, context)
	js_value* callback = test262_argument(rt, args, 0)
	list[js_value*] failure = new list[js_value*]
	failure.push(test262_error_object(rt))
	if (js_runtime_callable(callback) == 0):
		test262_done(rt, failure)
		return rt.undefined_value
	list[js_value*] none = new list[js_value*]
	js_value* result = js_runtime_call(rt, callback, none)
	if (rt.completion.status == 0):
		js_value* fulfilled = js_runtime_host_callable(rt, 0, test262_async_settled)
		js_value* rejected = js_runtime_host_callable(rt, cast(void*, 1), test262_async_settled)
		test262_then(rt, result, fulfilled, rejected)
	if (rt.completion.status == 2):
		failure[0] = rt.completion.value
		rt.completion.status = 0
		rt.completion.message = c""
		rt.completion.value = rt.undefined_value
		test262_done(rt, failure)
	return rt.undefined_value

# throwsAsync reactions: context is the reaction itself; parent is the
# result promise and home_object the expected constructor.
js_value* test262_throws_settled(void* runtime, void* context, js_value* receiver, list[js_value*] args):
	js_runtime* rt = cast(js_runtime*, runtime)
	js_value* self = cast(js_value*, context)
	int ok = 0
	js_value* thrown = test262_argument(rt, args, 0)
	if (self.coroutine_state && js_runtime_object(thrown)):
		js_value* constructor = js_runtime_get(rt, thrown, c"constructor")
		if (rt.completion.status != 0): return rt.undefined_value
		ok = constructor == self.home_object
	if (ok): js_runtime_promise_settle(rt, self.parent, rt.undefined_value, 0)
	else: js_runtime_promise_settle(rt, self.parent, test262_error_object(rt), 1)
	return rt.undefined_value

js_value* test262_throws_reaction(js_runtime* rt, js_value* promise, js_value* expected, int rejected):
	js_value* reaction = js_runtime_host_callable(rt, 0, test262_throws_settled)
	reaction.host_context = reaction
	reaction.parent = promise
	reaction.home_object = expected
	reaction.coroutine_state = rejected
	return reaction

js_value* test262_throws_async(void* context, list[js_value*] args):
	js_runtime* rt = cast(js_runtime*, context)
	test262_assertions = test262_assertions + 1
	js_value* expected = test262_argument(rt, args, 0)
	js_value* callback = test262_argument(rt, args, 1)
	js_value* promise = js_runtime_promise_new(rt)
	if (js_runtime_callable(expected) == 0 || js_runtime_callable(callback) == 0):
		js_runtime_promise_settle(rt, promise, test262_error_object(rt), 1)
		return promise
	list[js_value*] none = new list[js_value*]
	js_value* result = js_runtime_call(rt, callback, none)
	if (rt.completion.status == 0 && js_runtime_object(result)): test262_then(rt, result, test262_throws_reaction(rt, promise, expected, 0), test262_throws_reaction(rt, promise, expected, 1))
	else if (rt.completion.status == 0): js_runtime_fail(rt, 2, c"result is not a thenable")
	if (rt.completion.status == 2):
		rt.completion.status = 0
		rt.completion.message = c""
		rt.completion.value = rt.undefined_value
		js_runtime_promise_settle(rt, promise, test262_error_object(rt), 1)
	return promise

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
	if (test262_async): js_runtime_set(rt, assertion, c"throwsAsync", test262_callable(rt, test262_throws_async))
	js_runtime_set_host_hooks(rt, assertion, 0, test262_missing_helper, 0)
	js_runtime_bind(rt, c"$DONOTEVALUATE", test262_do_not_evaluate)
	js_runtime_bind(rt, c"$ERROR", test262_do_not_evaluate)
	if (test262_async):
		js_runtime_bind(rt, c"$DONE", test262_done)
		js_runtime_bind(rt, c"asyncTest", test262_async_test)
	else: js_runtime_bind(rt, c"$DONE", test262_unsupported)
	js_runtime_bind(rt, c"print", test262_unsupported)
	js_runtime_bind(rt, c"Test262Error", test262_unsupported)
	js_runtime_bind(rt, c"compareArray", test262_unsupported)
	js_runtime_bind(rt, c"formatIdentityFreeValue", test262_unsupported)
	js_runtime_bind(rt, c"formatSimpleValue", test262_unsupported)
	js_runtime_bind(rt, c"isNegativeZero", test262_unsupported)
	js_runtime_bind(rt, c"isPrimitive", test262_unsupported)
	js_runtime_bind(rt, c"buildString", test262_build_string)
	js_runtime_bind(rt, c"testPropertyEscapes", test262_test_property_escapes)
	js_runtime_bind(rt, c"printCodePoint", test262_unsupported)
	js_runtime_bind(rt, c"printStringCodePoints", test262_unsupported)
	js_runtime_bind(rt, c"testPropertyOfStrings", test262_unsupported)
	js_runtime_bind(rt, c"testExtendedCharacterClass", test262_unsupported)
	js_runtime_bind(rt, c"matchValidator", test262_unsupported)
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
# Static module-graph linking (reardan/w#840): load "./" fixtures beside the
# test and resolve every import and indirect export. Null when it links.
json_value* test262_resolve_module(char* source, char* filename):
	char* directory = path_dirname(filename)
	js_module_file_loader* loader = js_module_file_loader_new(directory)
	js_module_graph* graph = js_module_graph_new(js_module_file_load, loader)
	json_value* result = 0
	if (js_module_graph_link(graph, filename, source, strlen(source)) == 0):
		result = test262_result(c"resolution", c"error")
		json_object_set(result, c"error_type", json_string(graph.error_type))
		json_object_set(result, c"message", json_string(graph.error_message))
	js_module_graph_free(graph)
	js_module_file_loader_free(loader)
	free(directory)
	return result


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
	if (parsed.success && module): result = test262_resolve_module(source, filename)
	if (result == 0 && parsed.success == 0):
		if (stream.resource_failed): result = test262_result(phase, c"limit")
		else:
			result = test262_result(phase, c"error")
			json_object_set(result, c"error_type", json_string(c"SyntaxError"))
		test262_diagnostics(result, parsed)
	else if (result == 0):
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
		if (test262_async): js_runtime_bind(rt, c"print", test262_print)
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
	int async_failed = 0
	if (test262_async && completion.status == 0):
		int steps = completion.steps
		int remaining = budget - steps
		if (remaining < 1): remaining = 1
		completion = js_runtime_drain_microtasks(rt, remaining)
		completion.steps = completion.steps + steps
		if (completion.status == 0 && (test262_done_calls != 1 || test262_done_failed)):
			async_failed = 1
			completion.status = 2
			completion.message = c"asynchronous test did not report completion through $DONE"
			if (test262_done_failed && test262_done_error != 0): completion.value = test262_done_error
			else: completion.value = rt.undefined_value
	char* outcome = c"normal"
	if (completion.status == 2): outcome = c"throw"
	if (completion.status == 5): outcome = c"limit"
	if (completion.status == 6): outcome = c"unsupported"
	if (completion.status != 0 && completion.status != 2 && completion.status != 5 && completion.status != 6): outcome = c"invalid_completion"
	result = test262_result(c"execute", outcome)
	json_object_set(result, c"assertions", json_int(test262_assertions))
	if (async_failed): json_object_set(result, c"async", json_string(c"failed"))
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
		println(c"usage: test262_runtime_runner FILE script|module|async BUDGET harness|raw|upstream [HARNESS.js...]")
		return 2
	char* profile = args_get(4)
	if (strcmp(profile, c"raw") != 0 && strcmp(profile, c"harness") != 0 && strcmp(profile, c"upstream") != 0): return 2
	if (strcmp(profile, c"upstream") == 0):
		test262_harness_files = new list[char*]
		for i in range(5, argc): test262_harness_files.push(args_get(i))
	else if (argc != 5): return 2
	char* goal = args_get(2)
	if (strcmp(goal, c"async") == 0):
		test262_async = 1
		goal = c"script"
	if (strcmp(goal, c"script") != 0 && strcmp(goal, c"module") != 0): return 2
	int budget = 0
	char* raw_budget = args_get(3)
	for i in range(strlen(raw_budget)):
		if (raw_budget[i] < '0' || raw_budget[i] > '9' || budget > 10000000): return 2
		budget = budget * 10 + raw_budget[i] - '0'
	if (budget <= 0 || budget > 10000000): return 2
	char* source = file_read_text(args_get(1))
	if (source == 0): return 2
	json_value* result = test262_run(source, args_get(1), strcmp(goal, c"module") == 0, budget, strcmp(profile, c"raw") == 0)
	char* output = json_stringify(result)
	println(output)
	free(output)
	json_free(result)
	free(source)
	return 0
