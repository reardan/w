# wbuild: tool=tools/javascript_conformance.w tool=tools/javascript_runtime_runner.w
import tools.javascript_conformance_lib

json_value* jct_manifest(char* directory):
	char* source = c"let x=42; x;\n"
	ht_write(path_join(directory, c"case.js"), source, strlen(source))
	json_value* manifest = json_parse(c"{\"version\":1,\"kind\":\"native-ecmascript\",\"cases\":[{\"id\":\"case\",\"path\":\"case.js\",\"goal\":\"script\",\"spec\":\"https://tc39.es/ecma262/multipage/\",\"expected\":{\"phase\":\"execute\",\"outcome\":\"normal\",\"value\":{\"type\":\"number\",\"value\":\"42.0\"}}}]}")
	json_object_set(jc_get(manifest, c"cases").array_values[0], c"sha256", json_string(ht_digest(source, strlen(source))))
	return manifest

int main():
	char* directory = ht_temp()
	char* source = path_join(directory, c"case.js")
	char* path = path_join(directory, c"manifest.json")
	char* binary = c"bin/javascript_runtime_runner"
	json_value* original = jct_manifest(directory)
	json_value* entry = jc_get(original, c"cases").array_values[0]
	for i in range(2): ht_require(strcmp(jc_classify(entry, jc_execute(binary, source, entry, 10000)), c"PASS") == 0, c"fresh realm execution failed")
	ht_require(file_write_text(path, json_stringify(original)), c"cannot write test manifest")
	int status = 0
	json_value* report = jc_run(path, binary, 10000, &status)
	ht_require(status == 0 && ht_number(report, c"execution_passes") == 1, c"execution pass count regression")
	list[char*] sources = ht_split(c"let = ;|let x; let x;|class C {}|while(true) {}", '|')
	list[char*] phases = split(c"parse early lower execute")
	list[char*] outcomes = split(c"error error unsupported limit")
	json_value* bounded = json_clone(entry)
	json_object_set(bounded, c"budget", json_int(20))
	for i in range(4):
		ht_write(source, sources[i], strlen(sources[i]))
		json_value* actual = jc_execute(binary, source, bounded, 10000)
		ht_require(jc_is(jc_get(actual, c"phase"), phases[i]) && jc_is(jc_get(actual, c"outcome"), outcomes[i]), c"execution phase boundary regression")
	jct_manifest(directory)
	json_value* wrong = json_parse(c"{\"phase\":\"execute\",\"outcome\":\"normal\",\"value\":{\"type\":\"undefined\"}}")
	json_value* xfail = json_parse(c"{\"bug\":\"JS-TEST\",\"reason\":\"test\"}")
	json_object_set(xfail, c"observed", json_clone(wrong))
	json_value* xf = json_clone(original)
	json_value* xf_entry = jc_get(xf, c"cases").array_values[0]
	json_object_set(xf_entry, c"xfail", xfail)
	ht_require(strcmp(jc_classify(xf_entry, wrong), c"XFAIL") == 0, c"exact xfail mismatch")
	ht_require(strcmp(jc_classify(xf_entry, jc_get(entry, c"expected")), c"XPASS") == 0, c"unexpected fix was hidden")
	json_value* changed = json_clone(wrong)
	json_object_set(changed, c"outcome", json_string(c"throw"))
	ht_require(strcmp(jc_classify(xf_entry, changed), c"FAIL") == 0, c"inexact xfail accepted")
	file_write_text(path, json_stringify(xf))
	report = jc_run(path, binary, 10000, &status)
	ht_require(status == 1 && ht_number(jc_get(report, c"counts"), c"XPASS") == 1, c"XPASS exit status regression")
	json_value* failed = json_clone(original)
	json_object_set(jc_get(failed, c"cases").array_values[0], c"expected", json_clone(wrong))
	file_write_text(path, json_stringify(failed))
	report = jc_run(path, binary, 10000, &status)
	ht_require(status == 1 && ht_number(jc_get(report, c"counts"), c"FAIL") == 1, c"FAIL exit status regression")
	for mutation in range(8):
		json_value* data = json_clone(original)
		json_value* cases = jc_get(data, c"cases")
		json_value* item = cases.array_values[0]
		if (mutation == 0): json_object_set(data, c"kind", json_string(c"test262"))
		if (mutation == 1): json_object_set(item, c"flags", json_parse(c"[\"async\"]"))
		if (mutation == 2): json_object_set(item, c"budget", json_bool(1))
		if (mutation == 3): json_object_set(item, c"sha256", json_string(c"bad"))
		if (mutation == 4): json_object_set(item, c"expected", json_parse(c"{\"phase\":\"parse\",\"outcome\":\"normal\"}"))
		if (mutation == 5):
			json_value* invalid = json_clone(xfail)
			json_object_set(invalid, c"bug", json_string(c""))
			json_object_set(item, c"xfail", invalid)
		if (mutation == 6): json_object_set(item, c"path", json_string(c"../escape.js"))
		if (mutation == 7): json_array_push(cases, json_clone(item))
		file_write_text(path, json_stringify(data))
		ht_require(jc_load(path) == 0, strjoin(c"invalid metadata accepted: ", itoa(mutation)))
	for char* outcome in split(c"crash timeout harness_error"):
		json_value* actual = jc_process_error(outcome)
		json_object_set(xfail, c"observed", json_clone(actual))
		ht_require(strcmp(jc_classify(xf_entry, actual), c"ERROR") == 0, c"process failure classified as expected failure")
	for mutation in range(6):
		process_result proc
		proc.status = 0
		proc.stdout_text = c""
		proc.stderr_text = c""
		proc.stderr_length = 0
		char* outcome = c"harness_error"
		if (mutation == 0):
			proc.status = 139
			outcome = c"crash"
		if (mutation == 1): proc.status = 2
		if (mutation == 2): proc.stdout_text = c"{}"
		if (mutation == 3): proc.stdout_text = c"not json"
		if (mutation == 4): proc.stdout_text = c"{\"protocol\":1,\"phase\":\"parse\",\"outcome\":\"normal\"}"
		if (mutation == 5):
			proc.status = process_status_timeout
			outcome = c"timeout"
		proc.stdout_length = strlen(proc.stdout_text)
		ht_require(jc_is(jc_get(jc_result(&proc), c"outcome"), outcome), c"invalid process evidence accepted")
	file_write_text(path, c"{broken")
	list[char*] command = ht_command(c"bin/javascript_conformance --manifest")
	command.push(path)
	process_result* cli = ht_run(command, 0, 0, 10000)
	ht_require(cli.status == 2 && jc_get(json_parse(cli.stdout_text), c"harness_error") != 0, c"invalid manifest is not reported as JSON")
	ht_cleanup()
	println(c"JavaScript conformance harness checks OK")
	return 0
