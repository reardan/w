# Bounded Test262 metadata, pin validation, execution and baseline policy.
import tools.javascript_conformance_lib
import libs.standard.text.re

map[char*, char*] t262_sources
set[char*] t262_builtins
type t262_executor = fn(char*, char*, char*, int, int) -> json_value*

re_result* t262_match(char* pattern, char* text, int flags = 0):
	return re_fullmatch(re_compile(pattern, flags), text)

int t262_has(json_value* array, char* value):
	if (!jc_type(array, json_type_array())): return 0
	for json_value* item in array.array_values:
		if (jc_is(item, value)): return 1
	return 0

char* t262_scalar(char* text):
	text = strip(text)
	if (!jc_require(text[0] != 0 && re_search_str(c"[{}&*!|>]", text) == 0, c"unsupported YAML scalar")): return 0
	if (text[0] == '"'):
		json_value* parsed = json_parse(text)
		if (!jc_require(jc_type(parsed, json_type_string()), c"invalid quoted YAML scalar")): return 0
		return parsed.string_value
	if (text[0] == 39):
		if (!jc_require(strlen(text) >= 2 && text[strlen(text) - 1] == 39, c"unterminated YAML scalar")): return 0
		return replace(substring(text, 1, strlen(text) - 1), c"''", c"'")
	if (!jc_require(re_search_str(c"[\\[\\]#]", text) == 0, c"unsupported YAML scalar")): return 0
	return text

int t262_doc(char* key):
	return jc_choice(json_string(key), c"description info esid es5id es6id author")

json_value* t262_metadata(char* source):
	jc_error = 0
	list[re_result*] blocks = re_finditer(re_compile(c"/\\*---(.*?)---\\*/", RE_DOTALL), source)
	if (!jc_require(blocks.length == 1, c"exactly one Test262 metadata block required")): return 0
	json_value* result = json_object()
	char* key = 0
	for char* line in split(re_group(blocks[0], 1), 10):
		char* trimmed = strip(line)
		if (trimmed[0] == 0 || trimmed[0] == '#'): continue
		re_result* match = t262_match(c"([A-Za-z][A-Za-z0-9]*):(?:\\s*(.*))?", line)
		if (match != 0):
			key = re_group(match, 1)
			char* value = re_group(match, 2)
			if (value == 0): value = c""
			if (!jc_require(jc_get(result, key) == 0, c"duplicate metadata key")): return 0
			if (t262_doc(key)): json_object_set(result, key, json_string(value))
			else if (strcmp(key, c"negative") == 0):
				if (!jc_require(strip(value)[0] == 0, c"negative requires a block mapping")): return 0
				json_object_set(result, key, json_object())
			else if (jc_choice(json_string(key), c"flags features includes")):
				json_value* values = json_array()
				value = strip(value)
				if (value[0] != 0):
					if (!jc_require(value[0] == '[' && ends_with(value, c"]"), c"unsupported YAML sequence")): return 0
					for char* item in split(substring(value, 1, strlen(value) - 1), ','):
						if (strip(item)[0] == 0): continue
						char* scalar = t262_scalar(item)
						if (scalar == 0): return 0
						json_array_push(values, json_string(scalar))
				json_object_set(result, key, values)
			else:
				jc_require(0, c"unsupported Test262 metadata key")
				return 0
		else:
			if (!jc_require(isspace(line[0]) && key != 0, c"invalid YAML continuation")): return 0
			if (t262_doc(key)): continue
			if (strcmp(key, c"negative") == 0):
				match = t262_match(c"\\s+(phase|type):\\s*(\\S+)\\s*", line)
				if (!jc_require(match != 0, c"invalid negative metadata")): return 0
				char* name = re_group(match, 1)
				if (!jc_require(jc_get(jc_get(result, key), name) == 0, c"duplicate negative metadata")): return 0
				char* scalar = t262_scalar(re_group(match, 2))
				if (scalar == 0): return 0
				json_object_set(jc_get(result, key), name, json_string(scalar))
			else:
				match = t262_match(c"\\s+-\\s+(.+)", line)
				if (!jc_require(match != 0, c"invalid YAML list item")): return 0
				char* scalar = t262_scalar(re_group(match, 1))
				if (scalar == 0): return 0
				json_array_push(jc_get(result, key), json_string(scalar))
	for char* name in split(c"flags features includes"):
		if (jc_get(result, name) == 0): json_object_set(result, name, json_array())
		set[char*] seen = new set[char*]
		for json_value* value in jc_get(result, name).array_values:
			if (!jc_require(!(value.string_value in seen), c"duplicate metadata sequence item")): return 0
			seen.add(value.string_value)
	json_value* flags = jc_get(result, c"flags")
	if (!jc_require(!(t262_has(flags, c"onlyStrict") && t262_has(flags, c"noStrict")), c"conflicting strict flags")): return 0
	if (t262_has(flags, c"raw")):
		for char* name in split(c"onlyStrict noStrict module async"):
			if (!jc_require(!t262_has(flags, name), c"conflicting raw flags")): return 0
	if (!jc_require(!(t262_has(flags, c"module") && t262_has(flags, c"noStrict")), c"conflicting module flags")): return 0
	json_value* negative = jc_get(result, c"negative")
	if (negative != 0):
		if (!jc_require(jc_fields(negative, c"phase type", c"phase type") && jc_choice(jc_get(negative, c"phase"), c"parse resolution runtime"), c"invalid negative phase/fields")): return 0
		if (!jc_require(t262_match(c"(?:Error|[A-Za-z][A-Za-z0-9]*Error)", jc_string(jc_get(negative, c"type"))) != 0, c"invalid negative type")): return 0
	return result

list[char*] t262_variants(json_value* meta):
	json_value* flags = jc_get(meta, c"flags")
	if (t262_has(flags, c"module")): return ht_argv(c"module")
	if (t262_has(flags, c"raw")): return ht_argv(c"raw")
	if (t262_has(flags, c"onlyStrict")): return ht_argv(c"strict")
	if (t262_has(flags, c"noStrict")): return ht_argv(c"sloppy")
	return ht_argv(c"sloppy", c"strict")

char* t262_unsupported(json_value* meta):
	list[char*] unknown = new list[char*]
	list[char*] blocked = new list[char*]
	for json_value* flag in jc_get(meta, c"flags").array_values:
		if (!jc_choice(flag, c"onlyStrict noStrict raw module async generated CanBlockIsFalse CanBlockIsTrue non-deterministic")): unknown.push(flag.string_value)
		if (jc_choice(flag, c"module async CanBlockIsFalse CanBlockIsTrue non-deterministic")): blocked.push(flag.string_value)
	ht_sort(unknown)
	ht_sort(blocked)
	if (unknown.length): return strjoin(c"unknown flags: ", join(unknown, c", "))
	if (blocked.length): return strjoin(c"unsupported flags: ", join(blocked, c", "))
	list[char*] includes = new list[char*]
	for json_value* item in jc_get(meta, c"includes").array_values: includes.push(item.string_value)
	if (includes.length): return strjoin(c"unsupported harness includes: ", join(includes, c", "))
	list[char*] features = new list[char*]
	for json_value* item in jc_get(meta, c"features").array_values:
		if (!jc_is(item, c"coalesce-expression")): features.push(item.string_value)
	ht_sort(features)
	if (features.length): return strjoin(c"unsupported features: ", join(features, c", "))
	if (jc_is(jc_get(jc_get(meta, c"negative"), c"phase"), c"resolution")): return c"module resolution is unsupported"
	return 0

json_value* t262_load(char* path):
	jc_error = 0
	char* text = file_read_text(path)
	if (!jc_require(text != 0, c"cannot read manifest")): return 0
	json_value* data = json_parse(text)
	if (!jc_require(jc_fields(data, c"version suite upstream files cases baseline builtins_required", c"version suite upstream files cases baseline builtins_required"), c"invalid manifest fields")): return 0
	if (!jc_require(jc_equal(jc_get(data, c"version"), json_int(2)) && jc_is(jc_get(data, c"suite"), c"test262-bounded-runtime"), c"invalid manifest version/suite")): return 0
	json_value* upstream = jc_get(data, c"upstream")
	if (!jc_require(jc_fields(upstream, c"repository commit", c"repository commit") && jc_is(jc_get(upstream, c"repository"), c"https://github.com/tc39/test262") && t262_match(c"[0-9a-f]{40}", jc_string(jc_get(upstream, c"commit"))) != 0, c"invalid pinned provenance")): return 0
	json_value* files = jc_get(data, c"files")
	json_value* cases = jc_get(data, c"cases")
	if (!jc_require(jc_type(files, json_type_array()) && jc_type(cases, json_type_array()) && cases.array_values.length > 0, c"invalid files/cases")): return 0
	t262_sources = new map[char*, char*]
	char* directory = path_dirname(tempfile_abspath(path))
	char* corpus = ht_resolve(path_join(directory, c"upstream"))
	if (!jc_require(corpus != 0, c"cannot resolve corpus")): return 0
	for json_value* item in files.array_values:
		if (!jc_require(jc_fields(item, c"path upstream_path sha256", c"path upstream_path sha256") && jc_type(jc_get(item, c"upstream_path"), json_type_string()), c"invalid source entry")): return 0
		char* name = jc_string(jc_get(item, c"path"))
		if (!jc_require(strcmp(name, strjoin(c"upstream/", jc_string(jc_get(item, c"upstream_path")))) == 0, c"invalid source mapping")): return 0
		char* file = ht_resolve(strjoin(strjoin(directory, c"/"), name))
		if (!jc_require(file != 0 && path_is_within(corpus, file) && !(name in t262_sources), c"duplicate source or path escapes corpus")): return 0
		wstream* input = stream_open_read(file)
		if (!jc_require(input != 0, c"cannot read pinned source")): return 0
		string_builder* contents = string_new()
		io_result result
		int status = stream_read_all_checked(input, contents, &result)
		stream_close(input)
		if (!jc_require(status == IO_OK && contents.length <= 1000000 && strlen(contents.data) == contents.length && utf8_validate_bytes(contents.data, contents.length), c"invalid source bytes")): return 0
		if (!jc_require(jc_is(jc_get(item, c"sha256"), ht_digest(contents.data, contents.length)), c"source pin mismatch")): return 0
		t262_sources[name] = contents.data
	for char* name in split(c"upstream/LICENSE upstream/INTERPRETING.md upstream/harness/assert.js upstream/harness/sta.js"):
		if (!jc_require(name in t262_sources, c"missing pinned license/harness contract")): return 0
	set[char*] seen = new set[char*]
	set[char*] ids = new set[char*]
	for json_value* item in cases.array_values:
		char* name = jc_string(item)
		if (!jc_require(name in t262_sources && !(name in seen) && starts_with(name, c"upstream/test/") && ends_with(name, c".js") && !contains(name, c"_FIXTURE"), c"invalid or duplicate test source")): return 0
		seen.add(name)
		json_value* meta = t262_metadata(t262_sources[name])
		if (meta == 0): return 0
		for char* mode in t262_variants(meta): ids.add(strjoin(strjoin(name, c"#"), mode))
	json_value* requirements = jc_get(data, c"builtins_required")
	if (!jc_require(jc_type(requirements, json_type_object()), c"invalid built-in requirements")): return 0
	for char* name in requirements.object_values.keys():
		json_value* names = jc_get(requirements, name)
		if (!jc_require(name in seen && jc_type(names, json_type_array()) && names.array_values.length > 0, c"invalid required built-ins")): return 0
		set[char*] unique = new set[char*]
		for json_value* builtin in names.array_values:
			if (!jc_require(jc_choice(builtin, c"eval Number isNaN") && !(builtin.string_value in unique), c"unknown or duplicate required built-ins")): return 0
			unique.add(builtin.string_value)
	json_value* baseline = jc_get(data, c"baseline")
	if (!jc_require(jc_type(baseline, json_type_object()) && baseline.object_values.length == ids.length, c"baseline must cover every variant exactly")): return 0
	for char* id in baseline.object_values.keys():
		json_value* expected = jc_get(baseline, id)
		if (!jc_require(id in ids && jc_choice(jc_get(expected, c"status"), c"PASS UNSUPPORTED"), c"invalid baseline status")): return 0
		char* fields = c"status"
		if (jc_is(jc_get(expected, c"status"), c"UNSUPPORTED")):
			fields = c"status reason"
			if (!jc_require(split(jc_string(jc_get(expected, c"reason"))).length > 0, c"unsupported baseline requires a reason")): return 0
		if (!jc_require(jc_fields(expected, fields, fields), c"invalid baseline fields")): return 0
	return data

json_value* t262_execute(char* binary, char* path, char* mode, int timeout, int budget):
	if (!path_exists(binary)): return jc_process_error(c"harness_error")
	char* goal = c"script"
	char* harness = c"harness"
	if (strcmp(mode, c"module") == 0): goal = c"module"
	if (strcmp(mode, c"raw") == 0): harness = c"raw"
	process_result* proc = ht_run(ht_argv(binary, path, goal, itoa(budget), harness), 0, 0, timeout)
	if (proc.status != 0): return jc_result(proc)
	jc_error = 0
	json_value* actual = json_parse(proc.stdout_text)
	int valid = jc_require(jc_equal(jc_get(actual, c"protocol"), json_int(1)), c"invalid runner protocol")
	if (valid): valid = jc_require(jc_choice(jc_get(actual, c"phase"), c"parse early lower execute") && jc_choice(jc_get(actual, c"outcome"), c"normal error throw unsupported limit"), c"invalid result")
	if (valid && jc_choice(jc_get(actual, c"outcome"), c"normal throw")):
		json_value* steps = jc_get(actual, c"steps")
		json_value* assertions = jc_get(actual, c"assertions")
		valid = jc_require(jc_is(jc_get(actual, c"phase"), c"execute") && jc_type(steps, json_type_int()) && steps.int_value > 0 && jc_type(assertions, json_type_int()) && assertions.int_value >= 0, c"missing execution evidence")
	if (valid && jc_is(jc_get(actual, c"outcome"), c"error")): valid = jc_require(jc_choice(jc_get(actual, c"phase"), c"parse early") && jc_is(jc_get(actual, c"error_type"), c"SyntaxError"), c"invalid parser error")
	if (valid && jc_get(actual, c"error_type") != 0): valid = jc_require(jc_type(jc_get(actual, c"error_type"), json_type_string()), c"invalid error identity")
	if (valid): return actual
	json_value* failed = jc_process_error(c"harness_error")
	json_object_set(failed, c"message", json_string(jc_error))
	json_object_set(failed, c"stdout", json_string(jc_tail(proc.stdout_text, proc.stdout_length)))
	return failed

char* t262_classify(json_value* meta, json_value* actual):
	json_value* outcome = jc_get(actual, c"outcome")
	if (jc_choice(outcome, c"crash timeout harness_error limit")): return c"ERROR"
	if (jc_is(outcome, c"unsupported")): return c"UNSUPPORTED"
	json_value* negative = jc_get(meta, c"negative")
	json_value* phase = jc_get(actual, c"phase")
	if (negative != 0):
		char* normalized = jc_string(phase)
		if (jc_choice(phase, c"parse early")): normalized = c"parse"
		if (jc_is(phase, c"execute")): normalized = c"runtime"
		if (jc_choice(outcome, c"error throw") && jc_is(jc_get(negative, c"phase"), normalized) && jc_equal(jc_get(actual, c"error_type"), jc_get(negative, c"type"))): return c"PASS"
	else if (jc_is(phase, c"execute") && jc_is(outcome, c"normal")): return c"PASS"
	return c"FAIL"

json_value* t262_run(char* manifest_path, char* binary, int timeout, int budget, int* status, t262_executor* execute):
	json_value* manifest = t262_load(manifest_path)
	json_value* report = json_object()
	json_object_set(report, c"protocol", json_int(1))
	json_object_set(report, c"suite", json_string(c"test262-bounded-runtime"))
	if (manifest == 0 || timeout <= 0 || timeout > 300000 || budget <= 0 || budget > 10000000):
		if (manifest != 0): jc_error = c"invalid time/step budget"
		json_object_set(report, c"harness_error", json_string(jc_error))
		*status = 2
		return report
	if (t262_builtins == 0): t262_builtins = new set[char*]
	char* directory = ht_temp()
	json_value* results = json_array()
	json_value* changes = json_array()
	json_value* counts = json_object()
	for char* name in split(c"PASS FAIL UNSUPPORTED ERROR"): json_object_set(counts, name, json_int(0))
	int passes = 0
	int assertions = 0
	for json_value* entry in jc_get(manifest, c"cases").array_values:
		char* name = entry.string_value
		char* source = t262_sources[name]
		json_value* meta = t262_metadata(source)
		char* reason = t262_unsupported(meta)
		json_value* requirements = jc_get(jc_get(manifest, c"builtins_required"), name)
		list[char*] missing = new list[char*]
		if (requirements != 0):
			for json_value* item in requirements.array_values:
				if (!(item.string_value in t262_builtins)): missing.push(item.string_value)
		ht_sort(missing)
		if (reason == 0 && missing.length): reason = strjoin(c"unsupported required built-ins: ", join(missing, c", "))
		for char* mode in t262_variants(meta):
			json_value* actual = 0
			if (reason != 0):
				actual = json_object()
				json_object_set(actual, c"phase", json_string(c"metadata"))
				json_object_set(actual, c"outcome", json_string(c"unsupported"))
				json_object_set(actual, c"message", json_string(reason))
			else:
				char* content = source
				if (strcmp(mode, c"strict") == 0): content = strjoin(c"\"use strict\";\n", source)
				char* path = path_join(directory, c"case.js")
				ht_write(path, content, strlen(content))
				actual = execute(binary, path, mode, timeout, budget)
			char* id = strjoin(strjoin(name, c"#"), mode)
			char* classification = t262_classify(meta, actual)
			json_value* result = json_object()
			json_object_set(result, c"id", json_string(id))
			json_object_set(result, c"status", json_string(classification))
			json_object_set(result, c"mode", json_string(mode))
			json_value* negative = jc_get(meta, c"negative")
			if (negative == 0): negative = json_null()
			json_object_set(result, c"negative", json_clone(negative))
			json_object_set(result, c"actual", actual)
			json_value* expected = jc_get(jc_get(manifest, c"baseline"), id)
			json_object_set(result, c"baseline", json_clone(expected))
			if (!jc_is(jc_get(expected, c"status"), classification)):
				json_value* change = json_object()
				json_object_set(change, c"id", json_string(id))
				json_object_set(change, c"expected", json_clone(jc_get(expected, c"status")))
				json_object_set(change, c"actual", json_string(classification))
				json_array_push(changes, change)
			json_array_push(results, result)
			jc_count(counts, classification)
			if (strcmp(classification, c"PASS") == 0 && jc_is(jc_get(actual, c"phase"), c"execute")): passes = passes + 1
			if (jc_get(actual, c"assertions") != 0): assertions = assertions + jc_get(actual, c"assertions").int_value
	shutil_rmtree(directory)
	json_object_set(report, c"upstream", json_clone(jc_get(manifest, c"upstream")))
	json_object_set(report, c"profile", json_string(c"native-boolean-samevalue-v1"))
	json_object_set(report, c"files", json_int(jc_get(manifest, c"cases").array_values.length))
	json_object_set(report, c"variants", json_int(results.array_values.length))
	json_object_set(report, c"counts", counts)
	json_object_set(report, c"baseline_changes", changes)
	json_object_set(report, c"execution_passes", json_int(passes))
	json_object_set(report, c"assertions", json_int(assertions))
	json_object_set(report, c"results", results)
	*status = ht_number(counts, c"FAIL") != 0 || ht_number(counts, c"ERROR") != 0 || changes.array_values.length != 0
	return report
