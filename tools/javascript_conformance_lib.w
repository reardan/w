# Native ECMAScript harness contracts shared by the CLI and its regression tests.
import tools.host_tools
import lib.str
import lib.utf8

char* jc_error

int jc_require(int condition, char* message):
	if (!condition && jc_error == 0): jc_error = message
	return condition

json_value* jc_get(json_value* value, char* key):
	if (value == 0 || value.type != json_type_object()): return 0
	return json_object_get(value, key)

int jc_type(json_value* value, int kind):
	return value != 0 && value.type == kind

char* jc_string(json_value* value):
	if (!jc_type(value, json_type_string())): return c""
	return value.string_value

int jc_is(json_value* value, char* text):
	return jc_type(value, json_type_string()) && strcmp(value.string_value, text) == 0

int jc_choice(json_value* value, char* choices):
	for char* choice in split(choices):
		if (jc_is(value, choice)): return 1
	return 0

int jc_fields(json_value* value, char* allowed, char* required):
	if (!jc_type(value, json_type_object())): return 0
	list[char*] allowed_names = split(allowed)
	for char* key in value.object_values.keys():
		int found = 0
		for char* name in allowed_names:
			if (strcmp(key, name) == 0): found = 1
		if (!found): return 0
	for char* name in split(required):
		if (!json_object_has(value, name)): return 0
	return 1

int jc_equal(json_value* a, json_value* b):
	if (a == 0 || b == 0): return a == b
	if (a.type != b.type): return 0
	if (a.type == json_type_string()): return strcmp(a.string_value, b.string_value) == 0
	if (a.type == json_type_object()):
		if (a.object_values.length != b.object_values.length): return 0
		for char* key in a.object_values.keys():
			if (!jc_equal(a.object_values[key], jc_get(b, key))): return 0
		return 1
	if (a.type == json_type_array()):
		if (a.array_values.length != b.array_values.length): return 0
		for i in range(a.array_values.length):
			if (!jc_equal(a.array_values[i], b.array_values[i])): return 0
		return 1
	return strcmp(json_stringify(a), json_stringify(b)) == 0

int jc_expectation(json_value* value):
	if (!jc_require(jc_fields(value, c"phase outcome value error_type message", c"phase outcome"), c"invalid expectation fields")): return 0
	json_value* phase = jc_get(value, c"phase")
	json_value* outcome = jc_get(value, c"outcome")
	if (!jc_require(jc_choice(phase, c"parse early lower execute") && jc_choice(outcome, c"normal error throw unsupported limit"), c"invalid expectation phase/outcome")): return 0
	if (!jc_require(!jc_is(outcome, c"normal") || jc_is(phase, c"execute"), c"syntax-only acceptance is not execution success")): return 0
	for char* key in split(c"error_type message"):
		json_value* field = jc_get(value, key)
		if (field != 0 && !jc_require(jc_type(field, json_type_string()), c"invalid expectation string")): return 0
	json_value* item = jc_get(value, c"value")
	if (item == 0): return 1
	json_value* kind = jc_get(item, c"type")
	if (!jc_require(jc_choice(kind, c"undefined null boolean number string object"), c"invalid value type")): return 0
	char* fields = c"type"
	if (jc_choice(kind, c"number boolean")):
		fields = c"type value"
		int expected = json_type_bool()
		if (jc_is(kind, c"number")): expected = json_type_string()
		if (!jc_require(jc_type(jc_get(item, c"value"), expected), c"invalid primitive value")): return 0
	if (jc_is(kind, c"string")):
		fields = c"type units"
		json_value* units = jc_get(item, c"units")
		if (!jc_require(jc_type(units, json_type_array()), c"invalid UTF-16 units")): return 0
		for json_value* unit in units.array_values:
			if (!jc_require(jc_type(unit, json_type_int()) && unit.int_value >= 0 && unit.int_value <= 65535, c"invalid UTF-16 units")): return 0
	return jc_require(jc_fields(item, fields, fields), c"invalid value fields")

int jc_budget(json_value* entry):
	json_value* budget = jc_get(entry, c"budget")
	if (budget == 0): return 10000
	if (!jc_type(budget, json_type_int())): return -1
	return budget.int_value

json_value* jc_load(char* path):
	jc_error = 0
	char* text = file_read_text(path)
	if (!jc_require(text != 0, c"cannot read manifest")): return 0
	json_value* manifest = json_parse(text)
	if (!jc_require(jc_fields(manifest, c"version kind cases", c"version kind cases"), c"invalid manifest fields")): return 0
	json_value* version = jc_get(manifest, c"version")
	if (!jc_require(jc_type(version, json_type_int()) && version.int_value == 1, c"unsupported manifest version")): return 0
	if (!jc_require(jc_is(jc_get(manifest, c"kind"), c"native-ecmascript"), c"unsupported harness metadata")): return 0
	json_value* cases = jc_get(manifest, c"cases")
	if (!jc_require(jc_type(cases, json_type_array()) && cases.array_values.length > 0, c"empty or invalid cases")): return 0
	set[char*] seen = new set[char*]
	char* directory = ht_resolve(path_dirname(path))
	if (!jc_require(directory != 0, c"cannot resolve fixture directory")): return 0
	for json_value* entry in cases.array_values:
		if (!jc_require(jc_fields(entry, c"id path sha256 goal budget expected xfail spec", c"id path sha256 goal expected spec"), c"unknown or missing case metadata")): return 0
		char* id = jc_string(jc_get(entry, c"id"))
		if (!jc_require(id[0] != 0 && !(id in seen), c"invalid or duplicate case id")): return 0
		seen.add(id)
		if (!jc_require(jc_choice(jc_get(entry, c"goal"), c"script module"), c"unsupported goal")): return 0
		if (!jc_require(jc_budget(entry) > 0 && jc_budget(entry) <= 10000000, c"invalid budget")): return 0
		if (!jc_require(starts_with(jc_string(jc_get(entry, c"spec")), c"https://tc39.es/ecma262/"), c"missing normative reference")): return 0
		json_value* source_name = jc_get(entry, c"path")
		if (!jc_require(jc_type(source_name, json_type_string()), c"invalid source path")): return 0
		char* source_path = source_name.string_value
		if (!path_is_absolute(source_path)): source_path = strjoin(strjoin(directory, c"/"), source_path)
		char* source = ht_resolve(source_path)
		if (!jc_require(source != 0 && path_is_within(directory, source), c"source escapes fixture directory")): return 0
		wstream* input = stream_open_read(source)
		if (!jc_require(input != 0, c"cannot read fixture")): return 0
		string_builder* data = string_new()
		io_result read_result
		int status = stream_read_all_checked(input, data, &read_result)
		stream_close(input)
		if (!jc_require(status == IO_OK && data.length > 0 && data.length <= 1000000 && strlen(data.data) == data.length && utf8_validate_bytes(data.data, data.length), c"invalid source size, UTF-8 or embedded NUL")): return 0
		if (!jc_require(jc_is(jc_get(entry, c"sha256"), ht_digest(data.data, data.length)), c"source pin mismatch")): return 0
		json_value* expected = jc_get(entry, c"expected")
		if (!jc_expectation(expected)): return 0
		if (!jc_require(!jc_is(jc_get(expected, c"outcome"), c"unsupported"), c"unsupported cannot be a normative success")): return 0
		json_value* xfail = jc_get(entry, c"xfail")
		if (xfail != 0):
			if (!jc_require(jc_fields(xfail, c"bug reason observed", c"bug reason observed"), c"invalid xfail metadata")): return 0
			if (!jc_require(split(jc_string(jc_get(xfail, c"bug"))).length > 0 && split(jc_string(jc_get(xfail, c"reason"))).length > 0, c"xfail needs bug and reason")): return 0
			if (!jc_expectation(jc_get(xfail, c"observed"))): return 0
			if (!jc_require(!jc_equal(jc_get(xfail, c"observed"), expected), c"xfail must differ from normative expectation")): return 0
	return manifest

int jc_matches(json_value* actual, json_value* expected):
	if (!jc_type(actual, json_type_object()) || !jc_type(expected, json_type_object())): return 0
	for char* key in expected.object_values.keys():
		if (!jc_equal(jc_get(actual, key), expected.object_values[key])): return 0
	return 1

char* jc_classify(json_value* entry, json_value* actual):
	if (jc_choice(jc_get(actual, c"outcome"), c"crash timeout harness_error")): return c"ERROR"
	json_value* xfail = jc_get(entry, c"xfail")
	if (jc_matches(actual, jc_get(entry, c"expected"))):
		if (xfail != 0): return c"XPASS"
		return c"PASS"
	if (xfail != 0 && jc_matches(actual, jc_get(xfail, c"observed"))): return c"XFAIL"
	return c"FAIL"

json_value* jc_process_error(char* outcome):
	json_value* value = json_object()
	json_object_set(value, c"phase", json_string(c"process"))
	json_object_set(value, c"outcome", json_string(outcome))
	return value

char* jc_tail(char* text, int length):
	int start = length - 2000
	if (start < 0): start = 0
	return substring(text, start, length)

json_value* jc_result(process_result* proc):
	if (proc == 0): return jc_process_error(c"harness_error")
	if (proc.status == process_status_timeout): return jc_process_error(c"timeout")
	if (proc.status != 0):
		char* outcome = c"harness_error"
		int code = proc.status
		if (code >= 128 && code <= 192):
			outcome = c"crash"
			code = 128 - code
		json_value* failed = jc_process_error(outcome)
		json_object_set(failed, c"exit_code", json_int(code))
		json_object_set(failed, c"stderr", json_string(jc_tail(proc.stderr_text, proc.stderr_length)))
		return failed
	jc_error = 0
	json_value* actual = json_parse(proc.stdout_text)
	json_value* protocol = jc_get(actual, c"protocol")
	int valid = jc_require(jc_type(protocol, json_type_int()) && protocol.int_value == 1, c"invalid runner protocol")
	if (valid): valid = jc_require(jc_choice(jc_get(actual, c"phase"), c"parse early lower execute") && jc_choice(jc_get(actual, c"outcome"), c"normal error throw unsupported limit"), c"invalid runner result")
	if (valid && jc_choice(jc_get(actual, c"outcome"), c"normal throw")):
		valid = jc_require(jc_is(jc_get(actual, c"phase"), c"execute") && jc_get(actual, c"value") != 0, c"missing execution evidence")
		if (valid):
			json_value* evidence = json_object()
			for char* key in split(c"phase outcome value"): json_object_set(evidence, key, json_clone(jc_get(actual, key)))
			valid = jc_expectation(evidence)
	if (valid): return actual
	json_value* failed = jc_process_error(c"harness_error")
	json_object_set(failed, c"message", json_string(jc_error))
	json_object_set(failed, c"stdout", json_string(jc_tail(proc.stdout_text, proc.stdout_length)))
	return failed

json_value* jc_execute(char* binary, char* path, json_value* entry, int timeout):
	if (!path_exists(binary)): return jc_process_error(c"harness_error")
	list[char*] command = new list[char*]
	command.push(binary)
	command.push(path)
	command.push(jc_string(jc_get(entry, c"goal")))
	command.push(itoa(jc_budget(entry)))
	return jc_result(ht_run(command, 0, 0, timeout))

void jc_count(json_value* counts, char* key):
	json_value* previous = jc_get(counts, key)
	int n = 0
	if (previous != 0): n = previous.int_value
	json_object_set(counts, key, json_int(n + 1))

json_value* jc_run(char* manifest_path, char* binary, int timeout, int* status):
	json_value* manifest = jc_load(manifest_path)
	json_value* report = json_object()
	json_object_set(report, c"protocol", json_int(1))
	json_object_set(report, c"suite", json_string(c"native-ecmascript"))
	if (manifest == 0 || timeout <= 0):
		if (timeout <= 0): jc_error = c"timeout must be positive"
		json_object_set(report, c"harness_error", json_string(jc_error))
		*status = 2
		return report
	json_value* results = json_array()
	json_value* counts = json_object()
	json_value* outcomes = json_object()
	int passes = 0
	*status = 0
	for json_value* entry in jc_get(manifest, c"cases").array_values:
		json_value* actual = jc_execute(binary, path_join(path_dirname(manifest_path), ht_text(entry, c"path")), entry, timeout)
		char* classification = jc_classify(entry, actual)
		json_value* result = json_object()
		json_object_set(result, c"id", json_clone(jc_get(entry, c"id")))
		json_object_set(result, c"status", json_string(classification))
		json_object_set(result, c"actual", actual)
		json_object_set(result, c"expected", json_clone(jc_get(entry, c"expected")))
		if (jc_get(entry, c"xfail") != 0): json_object_set(result, c"xfail", json_clone(jc_get(entry, c"xfail")))
		json_array_push(results, result)
		jc_count(counts, classification)
		jc_count(outcomes, strjoin(strjoin(ht_text(actual, c"phase"), c":"), ht_text(actual, c"outcome")))
		if (strcmp(classification, c"PASS") == 0 && jc_is(jc_get(actual, c"phase"), c"execute")): passes = passes + 1
		if (strcmp(classification, c"FAIL") == 0 || strcmp(classification, c"XPASS") == 0 || strcmp(classification, c"ERROR") == 0): *status = 1
	json_object_set(report, c"results", results)
	json_object_set(report, c"counts", counts)
	json_object_set(report, c"outcomes", outcomes)
	json_object_set(report, c"execution_passes", json_int(passes))
	return report
