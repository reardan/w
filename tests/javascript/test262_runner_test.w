# wbuild: tool=tools/test262_conformance.w tool=tools/test262_runtime_runner.w timeout=900000
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

# The runner is deterministic, so repeated full-manifest runs reuse each
# variant's first result (keyed by profile, mode and source text).
map[char*, json_value*] tc_cache

json_value* tc_override(char* binary, char* path, char* mode, int timeout, int budget):
	if (tc_mutation == 1 && !tc_changed):
		tc_changed = 1
		return json_parse(c"{\"phase\":\"lower\",\"outcome\":\"unsupported\"}")
	if (tc_cache == 0): tc_cache = new map[char*, json_value*]
	char* key = strjoin(strjoin(strjoin(itoa(t262_upstream), mode), c"\n"), file_read_text(path))
	json_value* actual = 0
	if (key in tc_cache): actual = json_clone(tc_cache[key])
	else:
		actual = t262_execute(binary, path, mode, timeout, budget)
		tc_cache[key] = json_clone(actual)
	if (tc_mutation == 2 && !tc_changed && jc_is(jc_get(actual, c"outcome"), c"unsupported")):
		tc_changed = 1
		return json_parse(c"{\"phase\":\"execute\",\"outcome\":\"normal\",\"steps\":1,\"assertions\":1}")
	return actual

char* tc_manifest

json_value* tc_run(int* status):
	return t262_run(tc_manifest, c"bin/test262_runtime_runner", 10000, 100000, status, tc_override)

# The full-corpus counts and evidence are pinned on the gate targets
# (test262_conformance --expect); this test checks the adapter's contract
# on a deterministic sample instead of rerunning both profiles: every
# stride-th case plus, when keep_required, every builtins_required case.
char* tc_sample(json_value* manifest, int stride, int keep_required, char* name):
	json_value* value = json_clone(manifest)
	json_value* required = jc_get(value, c"builtins_required")
	set[char*] kept = new set[char*]
	json_value* cases = json_array()
	int index = 0
	for json_value* item in jc_get(value, c"cases").array_values:
		if (index % stride == 0 || (keep_required && jc_get(required, item.string_value) != 0)):
			kept.add(item.string_value)
			json_array_push(cases, json_clone(item))
		index = index + 1
	json_object_set(value, c"cases", cases)
	json_value* baseline = json_object()
	json_value* pinned = jc_get(value, c"baseline")
	for char* id in pinned.object_values.keys():
		if (split(id, '#')[0] in kept): json_object_set(baseline, id, json_clone(jc_get(pinned, id)))
	json_object_set(value, c"baseline", baseline)
	json_value* needs = json_object()
	for char* case_name in required.object_values.keys():
		if (case_name in kept): json_object_set(needs, case_name, json_clone(jc_get(required, case_name)))
	json_object_set(value, c"builtins_required", needs)
	char* path = path_join(tc_directory, name)
	file_write_text(path, json_stringify(value))
	ht_require(t262_load(path) != 0, c"sampled manifest rejected")
	return path

# A passing run's counts are exactly the tally of its pinned baseline.
void tc_baseline_counts(json_value* report, char* path):
	json_value* baseline = jc_get(t262_load(path), c"baseline")
	int passes = 0
	for json_value* item in baseline.object_values.values():
		if (jc_is(jc_get(item, c"status"), c"PASS")): passes = passes + 1
	json_value* counts = jc_get(report, c"counts")
	ht_require(ht_number(counts, c"PASS") == passes && ht_number(counts, c"UNSUPPORTED") == baseline.object_values.length - passes && ht_number(counts, c"FAIL") == 0 && ht_number(counts, c"ERROR") == 0, c"sampled counts differ from the baseline")
	ht_require(ht_number(report, c"variants") == baseline.object_values.length && jc_get(report, c"baseline_changes").array_values.length == 0, c"sampled baseline changed")

# The upstream-harness profile evaluates the pinned sta.js/assert.js in the
# realm. It reports a pass rate and is not gated by the native baseline.
void tc_upstream(json_value* manifest):
	t262_upstream = 1
	tc_manifest = tc_sample(manifest, 25, 0, c"upstream_sample.json")
	int status = 0
	json_value* report = tc_run(&status)
	json_value* counts = jc_get(report, c"counts")
	ht_require(status == 0 && ht_number(counts, c"FAIL") == 0 && ht_number(counts, c"ERROR") == 0 && ht_number(counts, c"PASS") > 0 && ht_number(report, c"execution_passes") > 0, c"upstream-harness sample failed")
	tc_eq(c"upstream-harness-v1", ht_text(report, c"profile"))
	ht_require(jc_get(report, c"baseline_changes").array_values.length == 0, c"upstream-harness evidence changed")
	ht_require(t262_expect(report, strjoin(c"PASS=", itoa(ht_number(counts, c"PASS")))) == 0 && t262_expect(report, c"PASS=0") != 0, c"upstream expectation check broken")
	t262_harness = new list[char*]
	for char* file in split(c"sta.js assert.js"): t262_harness.push(tempfile_abspath(path_join(c"tests/javascript/test262/upstream/harness", file)))
	for char* source in ht_split(c"assert(true);|assert.sameValue(NaN, NaN);|assert.throws(TypeError, function() { null.x; });|assert.compareArray([1, 2], [1, 2]);|function F() {} assert(new F() instanceof F);|switch (1) { case 1: break; default: throw 1; }", '|'): tc_eq(c"normal", ht_text(tc_execute(source), c"outcome"))
	json_value* negative = json_parse(c"{\"negative\":{\"phase\":\"runtime\",\"type\":\"Test262Error\"}}")
	for char* source in ht_split(c"assert(false);|assert.sameValue(0, -0);|assert.throws(ReferenceError, function() { null.x; });|throw new Test262Error('x');|$DONOTEVALUATE();", '|'):
		json_value* actual = tc_execute(source)
		tc_eq(c"throw", ht_text(actual, c"outcome"))
		tc_eq(c"FAIL", t262_classify(json_object(), actual))
	tc_eq(c"PASS", t262_classify(negative, tc_execute(c"throw new Test262Error('x');")))
	for char* source in ht_split(c"throw {constructor: Test262Error};|throw Test262Error;|throw 'Test262Error';", '|'): tc_eq(c"FAIL", t262_classify(negative, tc_execute(source)))
	t262_upstream = 0

json_value* tc_meta(char* fields):
	return t262_metadata(strjoin(strjoin(c"/*---\ndescription: test\n", fields), c"\n---*/\n"))

int main():
	tc_directory = ht_temp()
	ht_require(symlink(tempfile_abspath(c"tests/javascript/test262/upstream"), path_join(tc_directory, c"upstream")) == 0, c"cannot link pinned corpus")
	json_value* manifest = t262_load(c"tests/javascript/test262/manifest.json")
	json_value* requirements = jc_get(manifest, c"builtins_required")
	ht_require(requirements.object_values.length == 514, c"built-in requirement inventory changed")
	tc_manifest = tc_sample(manifest, 25, 1, c"native_sample.json")
	int status = 0
	json_value* report = tc_run(&status)
	ht_require(status == 0, c"sampled native gate failed")
	tc_baseline_counts(report, tc_manifest)
	json_value* sampled = jc_get(report, c"counts")
	for mutation in range(1, 3):
		tc_mutation = mutation
		tc_changed = 0
		json_value* changed = tc_run(&status)
		json_value* counts = jc_get(changed, c"counts")
		int passes = ht_number(sampled, c"PASS") - 1
		int unsupported = ht_number(sampled, c"UNSUPPORTED") + 1
		char* before = c"PASS"
		char* after = c"UNSUPPORTED"
		if (mutation == 2):
			passes = passes + 2
			unsupported = unsupported - 2
			before = c"UNSUPPORTED"
			after = c"PASS"
		ht_require(status == 1 && ht_number(counts, c"PASS") == passes && ht_number(counts, c"UNSUPPORTED") == unsupported && ht_number(counts, c"FAIL") == 0 && ht_number(counts, c"ERROR") == 0, c"baseline change did not fail gate")
		json_value* changes = jc_get(changed, c"baseline_changes")
		ht_require(changes.array_values.length == 1, c"wrong baseline change count")
		tc_eq(before, ht_text(changes.array_values[0], c"expected"))
		tc_eq(after, ht_text(changes.array_values[0], c"actual"))
	tc_mutation = 0
	ht_require(t262_expect(report, strjoin(strjoin(c"PASS=", itoa(ht_number(sampled, c"PASS"))), c",FAIL=0,ERROR=0")) == 0, c"matching expectation rejected")
	for char* spec in ht_split(c"PASS=0|FAIL=1|execution_passes=-1|pass_rate=0.00%|unknown=1|PASS|=1", '|'): ht_require(t262_expect(report, spec) != 0, strjoin(c"wrong expectation accepted: ", spec))
	for json_value* result in jc_get(report, c"results").array_values:
		char* name = split(ht_text(result, c"id"), '#')[0]
		json_value* required = jc_get(requirements, name)
		if (required == 0): continue
		tc_eq(c"PASS", ht_text(result, c"status"))
		tc_eq(c"execute", ht_text(jc_get(result, c"actual"), c"phase"))
	json_value* missing = tc_execute(c"unknownUserVariable;")
	tc_eq(c"ReferenceError", ht_text(missing, c"error_type"))
	tc_eq(c"FAIL", t262_classify(json_object(), missing))
	for char* source in ht_split(c"assert.sameValue(eval(\"1 + 1\"), 2);|assert.sameValue(isNaN(\"x\"), true);|assert.sameValue(Number(\"2\"), 2);|assert.sameValue(Number.isFinite(1), true);", '|'): tc_eq(c"normal", ht_text(tc_execute(source), c"outcome"))
	# A withheld capability is a metadata UNSUPPORTED reason, never a skip
	# that hides an executable case: the baseline change fails the gate.
	t262_builtins = new set[char*]
	json_value* withheld = tc_run(&status)
	ht_require(status == 1 && jc_get(withheld, c"baseline_changes").array_values.length == 721, c"withheld builtin support did not change the baseline")
	for json_value* result in jc_get(withheld, c"results").array_values:
		char* name = split(ht_text(result, c"id"), '#')[0]
		json_value* required = jc_get(requirements, name)
		if (required == 0): continue
		tc_eq(c"UNSUPPORTED", ht_text(result, c"status"))
		tc_eq(c"metadata", ht_text(jc_get(result, c"actual"), c"phase"))
		list[char*] names = new list[char*]
		for json_value* item in required.array_values: names.push(item.string_value)
		tc_eq(strjoin(c"unsupported required built-ins: ", join(names, c", ")), ht_text(jc_get(result, c"actual"), c"message"))
	t262_builtins = 0
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
	# Native regExpUtils.js helpers (#901): every symbol must match; the
	# upstream profile needs the include pinned, and it is not.
	json_value* utils = tc_meta(c"includes: [regExpUtils.js]")
	ht_require(t262_unsupported(utils) == 0, c"native regExpUtils.js helpers rejected")
	t262_upstream = 1
	ht_require(t262_unsupported(utils) != 0, c"unpinned regExpUtils.js accepted upstream")
	t262_upstream = 0
	json_value* escapes = tc_execute(c"testPropertyEscapes(/^\\p{Lu}+$/u, buildString({loneCodePoints: [0x41], ranges: [[0x42, 0x5A], [0x10400, 0x10427]]}), 'Lu'); testPropertyEscapes(/^\\P{Lu}+$/u, buildString({loneCodePoints: [], ranges: [[0x61, 0x7A]]}), 'not Lu');")
	tc_eq(c"normal", ht_text(escapes, c"outcome"))
	ht_require(ht_number(escapes, c"assertions") == 2, c"property-escape helper did not assert")
	for char* source in ht_split(c"testPropertyEscapes(/^\\p{Lu}+$/u, buildString({loneCodePoints: [0x41, 0x61], ranges: []}), 'Lu');|testPropertyEscapes(/^\\p{Lu}+$/u, 'A', 'Lu');|buildString({loneCodePoints: [-1], ranges: []});|buildString({loneCodePoints: [], ranges: [[0, 0x110000]]});|testPropertyEscapes(/a/g, buildString({loneCodePoints: [0x61], ranges: []}), 'a');", '|'):
		json_value* failed = tc_execute(source)
		tc_eq(c"throw", ht_text(failed, c"outcome"))
		tc_eq(c"Test262Error", ht_text(failed, c"error_type"))
	tc_eq(c"UNSUPPORTED", t262_classify(json_object(), tc_execute(c"matchValidator([], 0, '');")))
	# Negative module tests run through parsing and static module linking (#840).
	char* module_resolution = c"flags: [module]\nnegative:\n  phase: resolution\n  type: SyntaxError"
	for char* fields in ht_split(strjoin(c"flags: [module]\nnegative:\n  phase: parse\n  type: SyntaxError|", module_resolution), '|'): ht_require(t262_unsupported(tc_meta(fields)) == 0, c"negative module metadata rejected")
	ht_require(t262_unsupported(tc_meta(c"negative:\n  phase: resolution\n  type: SyntaxError")) != 0, c"script resolution metadata accepted")
	json_value* resolved = json_parse(c"{\"phase\":\"resolution\",\"outcome\":\"error\",\"error_type\":\"SyntaxError\"}")
	tc_eq(c"PASS", t262_classify(tc_meta(module_resolution), resolved))
	tc_eq(c"FAIL", t262_classify(tc_meta(c"flags: [module]\nnegative:\n  phase: parse\n  type: SyntaxError"), resolved))
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
	tc_upstream(manifest)
	ht_cleanup()
	println(c"Test262 adapter contract checks OK")
	return 0
