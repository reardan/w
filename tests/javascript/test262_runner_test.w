# wbuild: tool=tools/test262_conformance.w tool=tools/test262_runtime_runner.w
import tools.test262_conformance_lib

char* tc_directory
int tc_mutation
int tc_changed

void tc_eq(char* expected, char* actual):
	ht_require(strcmp(expected, actual) == 0, strjoin(strjoin(strjoin(c"expected ", expected), c", got "), actual))

json_value* tc_execute(char* source, char* mode = 0, int budget = 10000):
	if (mode == 0): mode = c"sloppy"
	if (strcmp(mode, c"strict") == 0): source = strjoin(c"\"use strict\";\n", source)
	char* path = path_join(tc_directory, c"case.js")
	ht_write(path, source, strlen(source))
	return t262_execute(c"bin/test262_runtime_runner", path, mode, 5000, budget)

json_value* tc_override(char* binary, char* path, char* mode, int timeout, int budget):
	if (tc_mutation == 1 && !tc_changed):
		tc_changed = 1
		return json_parse(c"{\"phase\":\"lower\",\"outcome\":\"unsupported\"}")
	json_value* actual = t262_execute(binary, path, mode, timeout, budget)
	if (tc_mutation == 2 && !tc_changed && jc_is(jc_get(actual, c"outcome"), c"unsupported")):
		tc_changed = 1
		return json_parse(c"{\"phase\":\"execute\",\"outcome\":\"normal\",\"steps\":1,\"assertions\":1}")
	return actual

json_value* tc_run(int* status):
	return t262_run(c"tests/javascript/test262/manifest.json", c"bin/test262_runtime_runner", 10000, 100000, status, tc_override)

json_value* tc_meta(char* fields):
	return t262_metadata(strjoin(strjoin(c"/*---\ndescription: test\n", fields), c"\n---*/\n"))

int main():
	tc_directory = ht_temp()
	int status = 0
	json_value* report = tc_run(&status)
	ht_require(status == 0 && jc_equal(jc_get(report, c"counts"), json_parse(c"{\"PASS\":41,\"FAIL\":0,\"UNSUPPORTED\":12,\"ERROR\":0}")), c"upstream counts changed")
	ht_require(ht_number(report, c"execution_passes") == 32 && ht_number(report, c"assertions") == 194 && ht_number(report, c"variants") == 53 && jc_get(report, c"baseline_changes").array_values.length == 0, c"upstream execution evidence changed")
	for mutation in range(1, 3):
		tc_mutation = mutation
		tc_changed = 0
		json_value* changed = tc_run(&status)
		json_value* counts = jc_get(changed, c"counts")
		int passes = 40
		int unsupported = 13
		char* before = c"PASS"
		char* after = c"UNSUPPORTED"
		if (mutation == 2):
			passes = 42
			unsupported = 11
			before = c"UNSUPPORTED"
			after = c"PASS"
		ht_require(status == 1 && ht_number(counts, c"PASS") == passes && ht_number(counts, c"UNSUPPORTED") == unsupported && ht_number(counts, c"FAIL") == 0 && ht_number(counts, c"ERROR") == 0, c"baseline change did not fail gate")
		json_value* changes = jc_get(changed, c"baseline_changes")
		ht_require(changes.array_values.length == 1, c"wrong baseline change count")
		tc_eq(before, ht_text(changes.array_values[0], c"expected"))
		tc_eq(after, ht_text(changes.array_values[0], c"actual"))
	tc_mutation = 0
	json_value* manifest = t262_load(c"tests/javascript/test262/manifest.json")
	json_value* requirements = jc_get(manifest, c"builtins_required")
	ht_require(requirements.object_values.length == 3, c"built-in requirement inventory changed")
	for json_value* result in jc_get(report, c"results").array_values:
		char* name = split(ht_text(result, c"id"), '#')[0]
		json_value* required = jc_get(requirements, name)
		if (required == 0): continue
		tc_eq(c"UNSUPPORTED", ht_text(result, c"status"))
		tc_eq(c"metadata", ht_text(jc_get(result, c"actual"), c"phase"))
		list[char*] names = new list[char*]
		for json_value* item in required.array_values: names.push(item.string_value)
		tc_eq(strjoin(c"unsupported required built-ins: ", join(names, c", ")), ht_text(jc_get(result, c"actual"), c"message"))
	for char* source in ht_split(c"unknownUserVariable;|eval(\"1 + 1\");|isNaN(0);", '|'):
		json_value* actual = tc_execute(source)
		tc_eq(c"ReferenceError", ht_text(actual, c"error_type"))
		tc_eq(c"FAIL", t262_classify(json_object(), actual))
	tc_eq(c"normal", ht_text(tc_execute(c"assert.sameValue(Number.isFinite(1), true);"), c"outcome"))
	for char* name in split(c"eval Number isNaN"): t262_builtins.add(name)
	json_value* promoted = tc_run(&status)
	ht_require(status == 1 && ht_number(jc_get(promoted, c"counts"), c"FAIL") == 6 && jc_get(promoted, c"baseline_changes").array_values.length == 6, c"declared builtin support hid runtime failures")
	t262_builtins = new set[char*]
	for char* source in ht_split(c"assert(true);|assert.sameValue(NaN, NaN);|assert.notSameValue(0, -0);|assert.sameValue();", '|'):
		json_value* actual = tc_execute(source)
		tc_eq(c"normal", ht_text(actual, c"outcome"))
		ht_require(ht_number(actual, c"assertions") == 1, c"assertion did not execute")
	for char* source in ht_split(c"assert(false);|assert(1);|assert.sameValue(1, 2);|assert.sameValue(0, -0);|assert.notSameValue(NaN, NaN);", '|'):
		json_value* actual = tc_execute(source)
		tc_eq(c"throw", ht_text(actual, c"outcome"))
		tc_eq(c"Test262Error", ht_text(actual, c"error_type"))
		tc_eq(c"FAIL", t262_classify(json_object(), actual))
	json_value* negative = json_parse(c"{\"negative\":{\"phase\":\"runtime\",\"type\":\"ReferenceError\"}}")
	json_value* actual = tc_execute(c"missingVariable;")
	tc_eq(c"PASS", t262_classify(negative, actual))
	tc_eq(c"ReferenceError", ht_text(actual, c"error_type"))
	for char* source in ht_split(c"throw {name: \"ReferenceError\"};|throw \"ReferenceError\";|throw 3;|null.x;", '|'): tc_eq(c"FAIL", t262_classify(negative, tc_execute(source)))
	tc_eq(c"FAIL", t262_classify(json_parse(c"{\"negative\":{\"phase\":\"parse\",\"type\":\"ReferenceError\"}}"), actual))
	json_value* parse_negative = json_parse(c"{\"negative\":{\"phase\":\"parse\",\"type\":\"SyntaxError\"}}")
	actual = tc_execute(c"$DONOTEVALUATE(); var = ;")
	tc_eq(c"PASS", t262_classify(parse_negative, actual))
	tc_eq(c"parse", ht_text(actual, c"phase"))
	for char* source in ht_split(c"$DONOTEVALUATE();|throw {name: \"SyntaxError\"};", '|'): tc_eq(c"FAIL", t262_classify(parse_negative, tc_execute(source)))
	actual = tc_execute(c"let x; let x;")
	tc_eq(c"early", ht_text(actual, c"phase"))
	tc_eq(c"PASS", t262_classify(parse_negative, actual))
	tc_eq(c"early", ht_text(tc_execute(c"(eval) = 20;", c"strict"), c"phase"))
	for char* mode in split(c"sloppy strict"): tc_eq(c"normal", ht_text(tc_execute(c"assert.sameValue(typeof previous, \"undefined\"); var previous = 1;", mode), c"outcome"))
	tc_eq(c"ReferenceError", ht_text(tc_execute(c"assert.sameValue(typeof assert, \"undefined\");", c"raw"), c"error_type"))
	tc_eq(c"normal", ht_text(tc_execute(c"if (typeof assert !== \"undefined\") throw 1;", c"raw"), c"outcome"))
	for char* source in ht_split(c"assert.throws(1, function() {});|assert.compareArray([], []);|$262.createRealm();|$DONE();", '|'): tc_eq(c"UNSUPPORTED", t262_classify(json_object(), tc_execute(source)))
	tc_eq(c"ERROR", t262_classify(json_object(), tc_execute(c"while (true) {}", 0, 10)))
	list[char*] modes = t262_variants(tc_meta(c""))
	ht_require(modes.length == 2 && strcmp(modes[0], c"sloppy") == 0 && strcmp(modes[1], c"strict") == 0, c"default variants changed")
	list[char*] flags = split(c"onlyStrict noStrict raw module")
	list[char*] expected = split(c"strict sloppy raw module")
	for i in range(4):
		modes = t262_variants(tc_meta(strjoin(strjoin(c"flags: [", flags[i]), c"]")))
		ht_require(modes.length == 1 && strcmp(modes[0], expected[i]) == 0, c"flag variants changed")
	for char* fields in ht_split(c"flags: [module]|flags: [async]|flags: [unknownFlag]|includes:\n  - compareArray.js|features: [BigInt]", '|'): ht_require(t262_unsupported(tc_meta(fields)) != 0, c"unsupported metadata accepted")
	for char* fields in ht_split(c"flags: [onlyStrict, noStrict]|flags: [raw, onlyStrict]|negative:\n  phase: runtime|negative:\n  phase: unknown\n  type: Error|flags: []\nflags: []|unexpected: value|includes: &anchor []", '|'): ht_require(tc_meta(fields) == 0, c"invalid metadata accepted")
	ht_require(jc_equal(jc_get(tc_meta(c"flags:\n  - onlyStrict\nnegative:\n  phase: runtime\n  type: ReferenceError"), c"negative"), jc_get(negative, c"negative")), c"block metadata parsing changed")
	for char* text in ht_split(c"{\"phase\":\"parse\",\"outcome\":\"error\",\"error_type\":\"ReferenceError\"}|{\"phase\":\"execute\",\"outcome\":\"throw\",\"error_type\":\"TypeError\"}|{\"phase\":\"execute\",\"outcome\":\"normal\"}", '|'): tc_eq(c"FAIL", t262_classify(negative, json_parse(text)))
	for char* outcome in split(c"crash timeout harness_error limit"): tc_eq(c"ERROR", t262_classify(negative, jc_process_error(outcome)))
	char* runner = path_join(tc_directory, c"runner")
	list[char*] scripts = ht_split(c"#!/bin/sh\nprintf '%s\\n' '{\"protocol\":1,\"phase\":\"execute\",\"outcome\":\"normal\"}'\n|#!/bin/sh\nexec sleep 1\n|#!/bin/sh\nkill -KILL $$\n", '|')
	expected = split(c"harness_error timeout crash")
	for i in range(3):
		ht_write(runner, scripts[i], strlen(scripts[i]))
		ht_require(chmod(runner, 493) == 0, c"cannot chmod fake runner")
		int timeout = 5000
		if (i == 1): timeout = 10
		tc_eq(expected[i], ht_text(t262_execute(runner, runner, c"sloppy", timeout, 100), c"outcome"))
	ht_require(symlink(tempfile_abspath(c"tests/javascript/test262/upstream"), path_join(tc_directory, c"upstream")) == 0, c"cannot link pinned corpus")
	for mutation in range(14):
		json_value* value = json_clone(manifest)
		json_value* files = jc_get(value, c"files")
		json_value* cases = jc_get(value, c"cases")
		json_value* required = jc_get(value, c"builtins_required")
		json_value* baseline = jc_get(value, c"baseline")
		char* first = baseline.object_values.keys()[0]
		if (mutation == 0): json_object_set(files.array_values[0], c"sha256", json_string(ht_repeat('0', 64)))
		if (mutation == 1): json_object_set(required, c"unpinned", json_parse(c"[\"eval\"]"))
		if (mutation >= 2 && mutation <= 4):
			char* names = c"[]"
			if (mutation == 2): names = c"[\"unknownBuiltin\"]"
			if (mutation == 3): names = c"[\"eval\",\"eval\"]"
			json_object_set(required, cases.array_values[0].string_value, json_parse(names))
		if (mutation == 5):
			json_object_set(files.array_values[0], c"path", json_string(c"upstream/../escape"))
			json_object_set(files.array_values[0], c"upstream_path", json_string(c"../escape"))
		if (mutation == 6): json_array_push(cases, json_clone(cases.array_values[0]))
		if (mutation == 7): json_object_set(jc_get(value, c"upstream"), c"commit", json_string(c"main"))
		if (mutation == 8): files.array_values.remove(0)
		if (mutation == 9): baseline.object_values.remove(first)
		if (mutation == 10): json_object_set(baseline, c"extra", json_parse(c"{\"status\":\"PASS\"}"))
		if (mutation == 11): json_object_set(jc_get(baseline, first), c"status", json_string(c"FAIL"))
		if (mutation >= 12):
			for json_value* item in baseline.object_values.values():
				if (!jc_is(jc_get(item, c"status"), c"UNSUPPORTED")): continue
				if (mutation == 12): item.object_values.remove(c"reason")
				else: json_object_set(item, c"reason", json_string(c" "))
				break
		char* path = path_join(tc_directory, c"manifest.json")
		file_write_text(path, json_stringify(value))
		ht_require(t262_load(path) == 0, strjoin(c"invalid Test262 manifest accepted: ", itoa(mutation)))
	ht_cleanup()
	println(c"Test262 adapter contract checks OK")
	return 0
