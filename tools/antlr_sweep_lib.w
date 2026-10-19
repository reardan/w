# Staged grammars-v4 sweep: each configuration has independent artifacts,
# dependency closure evidence, semantic outcomes and infrastructure failures.
import tools.host_report
import tools.javascript_conformance_lib
import libs.standard.fs.glob
import libs.standard.text.re

char* sw_error
list[char*] sw_stages(): return ht_command(c"translate generate compile strict")
list[char*] sw_build_stages(): return ht_command(c"translate generate compile compiler_strict")
json_value* sw_configurations(int extended = 0):
	json_value* configurations = json_parse(c"{\"default_permissive\":[],\"default_strict\":[\"--strict\"],\"stateful_permissive\":[\"--stateful\"],\"stateful_strict\":[\"--strict\",\"--stateful\"]}")
	if (extended):
		json_object_set(configurations, c"exact_permissive", vj_strings(ht_command(c"--exact-lexer --prediction")))
		json_object_set(configurations, c"exact_strict", vj_strings(ht_command(c"--strict --exact-lexer --prediction")))
	return configurations
int sw_check(int condition, char* message):
	if (!condition): sw_error = message
	return condition
char* sw_digest(char* path):
	string_builder* data = ht_read(path)
	char* digest = ht_digest(data.data, data.length)
	string_free(data)
	return digest
int sw_has(json_value* array, char* value):
	if (!jc_type(array, json_type_array())): return 0
	for json_value* item in array.array_values:
		if (jc_is(item, value)): return 1
	return 0
char* sw_git(char* root, list[char*] arguments):
	list[char*] command = ht_argv(c"git", c"-C", root)
	for char* arg in arguments: command.push(arg)
	return strip(ht_checked(command).stdout_text)
json_value* sw_empty(list[char*] names, char* status):
	json_value* result = json_object()
	for char* name in names: json_object_set(result, name, vj_one(c"status", status))
	return result
json_value* sw_empty_configs(json_value* configurations, char* status):
	json_value* result = json_object()
	for char* name in configurations.object_values.keys():
		json_value* current = json_object()
		json_object_set(current, c"stages", sw_empty(sw_build_stages(), status))
		json_object_set(current, c"dependency_inputs", json_array())
		json_object_set(result, name, current)
	return result

json_value* sw_load(char* path, char* corpus):
	json_value* manifest = ht_json(path)
	int schema = ht_number(manifest, c"schema")
	if (!sw_check(schema == 1 || schema == 2, c"unsupported sweep manifest schema")): return 0
	if (!sw_check(strcmp(sw_git(corpus, ht_command(c"rev-parse HEAD")), ht_text(manifest, c"corpus_commit")) == 0, c"corpus revision mismatch")): return 0
	set[char*] names = new set[char*]
	json_value* all_configs = sw_configurations(1)
	corpus = ht_resolve(corpus)
	for json_value* entry in ht_field(manifest, c"cases").array_values:
		char* name = ht_text(entry, c"name")
		if (!sw_check(!(name in names) && re_fullmatch(re_compile(c"[A-Za-z0-9_-]+", 0), name) != 0, c"invalid or duplicate case name")): return 0
		names.add(name)
		if (!sw_check(ht_field(entry, c"inputs").array_values.length > 0, c"no pinned inputs")): return 0
		for json_value* stage in ht_field(entry, c"expected_pass").array_values:
			if (!sw_check(stage.string_value in sw_stages(), c"invalid baseline stage")): return 0
		json_value* configs = jc_get(entry, c"expected_configurations")
		if (configs != 0):
			for char* configuration in configs.object_values.keys():
				if (!sw_check(json_object_has(all_configs, configuration), c"invalid configuration baseline")): return 0
				for json_value* stage in ht_field(configs, configuration).array_values:
					if (!sw_check(stage.string_value in sw_build_stages(), c"invalid configuration baseline stage")): return 0
		json_value* recorded = jc_get(entry, c"recorded_pass")
		if (recorded != 0):
			for json_value* stage in recorded.array_values:
				if (sw_has(ht_field(entry, c"expected_pass"), stage.string_value)): continue
				json_value* reason = jc_get(jc_get(entry, c"reclassified"), stage.string_value)
				if (!sw_check(jc_type(reason, json_type_string()) && strip(reason.string_value)[0] != 0, c"removing recorded pass requires a reclassified reason")): return 0
		for json_value* input in ht_field(entry, c"inputs").array_values:
			char* resolved = ht_resolve(strjoin(strjoin(corpus, c"/"), ht_text(input, c"path")))
			if (!sw_check(resolved != 0 && starts_with(resolved, strjoin(corpus, c"/")) && path_exists(resolved) && strcmp(sw_digest(resolved), ht_text(input, c"sha256")) == 0, c"corpus input hash/path mismatch")): return 0
	if (!sw_check(sw_git(corpus, ht_command(c"status --porcelain --untracked-files=all -- *.g4"))[0] == 0, c"corpus grammar files must be clean (including untracked siblings)")): return 0
	return manifest

json_value* sw_run_stage(list[char*] command, char* log, int timeout, char* cwd):
	json_value* result = vj_one(c"status", c"error")
	json_object_set(result, c"argv", vj_strings(command))
	vj_s(result, c"log", log)
	int start = vm_ns()
	char* executable = process_which(command[0])
	if (executable == 0 || !process_path_readable(executable)):
		vj_s(result, c"error", c"executable unavailable")
		ht_write(log, c"executable unavailable\n", 23)
	else:
		hm_sample* process = hm_start(command, cwd)
		hm_finish(process, timeout)
		char* output = strjoin(ht_read(process.stdout_path).data, ht_read(process.stderr_path).data)
		char* status = c"fail"
		int code = process.status
		if (process.status == 0): status = c"pass"
		if ((process.child.status & 127) != 0):
			status = c"crash"
			code = 0 - (process.child.status & 127)
		if (process.timed_out):
			status = c"timeout"
			code = 124
			output = strjoin(output, c"\nSWEEP: stage timeout\n")
		vj_s(result, c"status", status)
		vj_i(result, c"exit_code", code)
		ht_write(log, output, strlen(output))
	vj_f(result, c"seconds", cast(float, vm_ns() - start) / 1000000000.0)
	return result
int sw_pass(json_value* stage): return jc_is(jc_get(stage, c"status"), c"pass")
int sw_is_file(char* path):
	file_stat st
	return file_stat_path(path, &st) == 0 && (st.mode & FILE_S_IFMT) == FILE_S_IFREG
void sw_outputs(json_value* stage, list[char*] paths):
	if (!sw_pass(stage)): return
	for char* path in paths:
		if (!sw_is_file(path)):
			vj_s(stage, c"status", c"error")
			vj_s(stage, c"error", strjoin(c"missing output: ", path))
json_value* sw_findings(char* path):
	if (!sw_check(path_exists(path), c"structured audit file missing")): return 0
	json_value* document = json_parse(ht_read(path).data)
	json_value* version = jc_get(document, c"schema_version")
	json_value* findings = jc_get(document, c"findings")
	if (!sw_check(jc_type(version, json_type_int()) && version.int_value == 1 && jc_type(findings, json_type_array()), c"unsupported structured audit schema")): return 0
	for json_value* finding in findings.array_values:
		if (!sw_check(jc_type(finding, json_type_object()), c"structured audit finding must be an object")): return 0
		for char* field in ht_command(c"code stage feature classification file rule reason"):
			json_value* value = jc_get(finding, field)
			if (!sw_check(jc_type(value, json_type_string()) && value.string_value[0] != 0, strjoin(c"structured audit missing string field: ", field))): return 0
		for char* field in ht_command(c"line column"):
			json_value* value = jc_get(finding, field)
			if (!sw_check(jc_type(value, json_type_int()) && value.int_value >= 1, strjoin(c"structured audit invalid source location: ", field))): return 0
	return findings

json_value* sw_case(json_value* entry, char* corpus, char* work, json_value* tools, int timeout, char* repo, json_value* configurations):
	char* name = ht_text(entry, c"name")
	char* directory = path_join(work, name)
	ht_require(mkdir(directory, 493) == 0, c"case artifact directory already exists")
	char* parser_name = strjoin(c"sweep_", replace(name, c"-", c"_"))
	json_value* result = vj_one(c"name", name)
	json_object_set(result, c"inputs", ht_field(entry, c"inputs"))
	vj_b(result, c"historical_288", jc_get(entry, c"historical_288") != 0 && ht_field(entry, c"historical_288").int_value)
	vj_s(result, c"runtime_smoke", c"not_configured")
	json_value* currents = sw_empty_configs(configurations, c"not_run")
	json_object_set(result, c"configurations", currents)
	for char* configuration in configurations.object_values.keys():
		json_value* current = ht_field(currents, configuration)
		json_value* stages = ht_field(current, c"stages")
		char* output = directory
		if (strcmp(configuration, c"default_permissive") != 0): output = path_join(directory, configuration)
		ht_mkdir(output)
		char* pg = path_join(output, c"grammar.pg")
		char* matchers = path_join(output, c"matchers.w")
		char* generated = path_join(output, c"parser.w")
		char* loaded = path_join(output, c"translate.inputs")
		char* audit = path_join(output, c"translate.audit.json")
		list[char*] command = ht_argv(ht_text(tools, c"translator"))
		for json_value* input in ht_field(entry, c"inputs").array_values: command.push(path_join(corpus, ht_text(input, c"path")))
		for char* arg in ht_argv(c"-o", pg, c"--parser-name", parser_name, c"--matchers", matchers, c"--report", path_join(output, c"translate.report"), c"--audit", path_join(output, c"translate.audit")): command.push(arg)
		for char* arg in ht_argv(c"--dependencies", loaded, c"--audit-json", audit): command.push(arg)
		for json_value* flag in ht_field(configurations, configuration).array_values: command.push(flag.string_value)
		json_value* translated = sw_run_stage(command, path_join(output, c"translate.log"), timeout, repo)
		json_object_set(stages, c"translate", translated)
		sw_outputs(translated, ht_argv(pg, matchers, loaded))
		json_value* findings = sw_findings(audit)
		if (findings != 0): json_object_set(current, c"findings", findings)
		elif (sw_pass(translated) || jc_is(jc_get(translated, c"status"), c"fail")):
			vj_s(translated, c"status", c"error")
			vj_s(translated, c"error", strjoin(c"structured audit: ", sw_error))
		if (path_exists(loaded)):
			for char* value in ht_split(ht_read(loaded).data, 10):
				if (value[0] == 0): continue
				char* path = ht_resolve(path_join(repo, value))
				if (path == 0 || !starts_with(path, strjoin(corpus, c"/"))):
					vj_s(translated, c"status", c"error")
					vj_s(translated, c"error", strjoin(c"dependency outside pinned corpus: ", value))
					break
				json_value* input = vj_one(c"path", path + strlen(corpus) + 1)
				vj_s(input, c"sha256", sw_digest(path))
				json_array_push(ht_field(current, c"dependency_inputs"), input)
		if (!sw_pass(translated)): continue
		json_value* generation = sw_run_stage(ht_argv(ht_text(tools, c"generator"), pg, c"-o", generated), path_join(output, c"generate.log"), timeout, repo)
		json_object_set(stages, c"generate", generation)
		sw_outputs(generation, ht_argv(generated))
		if (!sw_pass(generation)): continue
		char* program = path_join(output, c"compile.w")
		string_builder* text = string_from(ht_read(ht_text(tools, c"common_matchers")).data)
		string_append(text, c"\n")
		string_append(text, ht_read(matchers).data)
		string_append(text, c"\n")
		string_append(text, ht_read(generated).data)
		string_append(text, c"\nint main():\n\treturn 0\n")
		ht_write(program, text.data, text.length)
		for char* stage in ht_command(c"compile compiler_strict"):
			char* binary = path_join(output, strjoin(stage, c".bin"))
			command = ht_argv(ht_text(tools, c"compiler"), program)
			if (strcmp(stage, c"compiler_strict") == 0): command.push(c"--strict")
			command.push(c"-o")
			command.push(binary)
			json_value* compiled = sw_run_stage(command, path_join(output, strjoin(stage, c".log")), timeout, repo)
			sw_outputs(compiled, ht_argv(binary))
			json_object_set(stages, stage, compiled)
	json_value* standard = ht_field(currents, c"default_permissive")
	json_value* stages = json_object()
	for char* stage in ht_command(c"translate generate compile"): json_object_set(stages, stage, ht_field(ht_field(standard, c"stages"), stage))
	json_object_set(stages, c"strict", ht_field(ht_field(ht_field(currents, c"default_strict"), c"stages"), c"translate"))
	json_object_set(result, c"stages", stages)
	json_object_set(result, c"dependency_inputs", ht_field(standard, c"dependency_inputs"))
	return result

json_value* sw_compare(json_value* manifest, json_value* results):
	map[char*, json_value*] actual = new map[char*, json_value*]
	for json_value* row in results.array_values: actual[ht_text(row, c"name")] = row
	json_value* regressions = json_array()
	for json_value* entry in ht_field(manifest, c"cases").array_values:
		char* name = ht_text(entry, c"name")
		if (!(name in actual)):
			json_array_push(regressions, json_string(strjoin(name, c": missing result")))
			continue
		for json_value* stage in ht_field(entry, c"expected_pass").array_values:
			char* status = ht_text(ht_field(ht_field(actual[name], c"stages"), stage.string_value), c"status")
			if (strcmp(status, c"pass") != 0): json_array_push(regressions, json_string(strjoin(strjoin(name, c": "), strjoin(stage.string_value, strjoin(c" regressed to ", status)))))
		json_value* configs = jc_get(entry, c"expected_configurations")
		if (configs == 0): continue
		for char* configuration in configs.object_values.keys():
			json_value* measured = jc_get(jc_get(jc_get(actual[name], c"configurations"), configuration), c"stages")
			for json_value* stage in ht_field(configs, configuration).array_values:
				json_value* got = jc_get(jc_get(measured, stage.string_value), c"status")
				char* status = c"missing"
				if (got != 0): status = got.string_value
				if (strcmp(status, c"pass") != 0): json_array_push(regressions, json_string(strjoin(strjoin(name, c": "), strjoin(strjoin(configuration, c"/"), strjoin(stage.string_value, strjoin(c" regressed to ", status))))))
	return regressions

void sw_csv_row(string_builder* output, list[char*] values):
	for i in range(values.length):
		if (i > 0): string_append_char(output, ',')
		string_append_char(output, '"')
		string_append(output, replace(values[i], c"\"", c"\"\""))
		string_append_char(output, '"')
	string_append(output, c"\r\n")

json_value* sw_write_results(char* work, json_value* manifest, json_value* results, json_value* provenance, char* csv_path = 0):
	json_value* regressions = sw_compare(manifest, results)
	json_value* errors = jc_get(provenance, c"infrastructure_errors")
	if (errors == 0): errors = json_array()
	else: errors = vj_copy(errors)
	list[char*] configurations = new list[char*]
	for json_value* row in results.array_values:
		json_value* current = jc_get(row, c"configurations")
		if (current == 0):
			current = json_object()
			json_value* legacy = json_object()
			json_object_set(legacy, c"stages", ht_field(row, c"stages"))
			json_object_set(current, c"legacy", legacy)
		else:
			for char* name in current.object_values.keys():
				if (!(name in configurations)): configurations.push(name)
		for char* configuration in current.object_values.keys():
			json_value* stages = ht_field(ht_field(current, configuration), c"stages")
			for char* stage in stages.object_values.keys():
				char* status = ht_text(ht_field(stages, stage), c"status")
				if (strcmp(status, c"error") == 0 || strcmp(status, c"timeout") == 0 || strcmp(status, c"crash") == 0): json_array_push(errors, json_string(strjoin(strjoin(ht_text(row, c"name"), c": "), strjoin(strjoin(configuration, c"/"), strjoin(stage, strjoin(c" ", status))))))
	json_value* totals = json_object()
	for char* stage in sw_stages():
		int count = 0
		for json_value* row in results.array_values:
			if (sw_pass(ht_field(ht_field(row, c"stages"), stage))): count = count + 1
		vj_i(totals, stage, count)
	json_value* config_totals = json_object()
	json_value* finding_counts = json_object()
	for char* name in configurations:
		json_value* counts = json_object()
		for char* stage in sw_build_stages():
			int count = 0
			for json_value* row in results.array_values:
				if (sw_pass(jc_get(jc_get(jc_get(jc_get(row, c"configurations"), name), c"stages"), stage))): count = count + 1
			vj_i(counts, stage, count)
		json_object_set(config_totals, name, counts)
		json_value* codes = json_object()
		for json_value* row in results.array_values:
			json_value* findings = jc_get(jc_get(jc_get(row, c"configurations"), name), c"findings")
			if (findings == 0): continue
			set[char*] seen = new set[char*]
			for json_value* finding in findings.array_values:
				char* code = ht_text(finding, c"code")
				if (code in seen): continue
				seen.add(code)
				int count = 0
				if (json_object_has(codes, code)): count = ht_number(codes, code)
				vj_i(codes, code, count + 1)
		json_object_set(finding_counts, name, codes)
	json_value* summary = json_object()
	vj_i(summary, c"cases", results.array_values.length)
	json_object_set(summary, c"passing", totals)
	json_object_set(summary, c"configurations", config_totals)
	json_object_set(summary, c"finding_grammar_counts", finding_counts)
	int historical = 0
	for json_value* row in results.array_values:
		if (ht_field(row, c"historical_288").int_value && sw_pass(ht_field(ht_field(row, c"stages"), c"compile"))): historical = historical + 1
	vj_i(summary, c"historical_288_compiled", historical)
	vj_s(summary, c"runtime_smoke", c"not_configured")
	json_object_set(summary, c"regressions", regressions)
	json_object_set(summary, c"infrastructure_errors", errors)
	json_value* report = json_parse(c"{\"schema\":2}")
	json_object_set(report, c"provenance", provenance)
	json_object_set(report, c"summary", summary)
	json_object_set(report, c"cases", results)
	vj_write(path_join(work, c"results.json"), report)
	string_builder* csv = string_new()
	list[char*] header = ht_command(c"name inputs translate generate compile strict runtime_smoke")
	for char* configuration in configurations:
		for char* stage in sw_build_stages(): header.push(strjoin(strjoin(configuration, c"/"), stage))
	sw_csv_row(csv, header)
	for json_value* row in results.array_values:
		list[char*] inputs = new list[char*]
		for json_value* input in ht_field(row, c"inputs").array_values: inputs.push(ht_text(input, c"path"))
		list[char*] values = ht_argv(ht_text(row, c"name"), join(inputs, c";"))
		for char* stage in sw_stages(): values.push(ht_text(ht_field(ht_field(row, c"stages"), stage), c"status"))
		values.push(ht_text(row, c"runtime_smoke"))
		for char* configuration in configurations:
			for char* stage in sw_build_stages():
				json_value* status = jc_get(jc_get(jc_get(jc_get(jc_get(row, c"configurations"), configuration), c"stages"), stage), c"status")
				char* value = c"not_run"
				if (status != 0): value = status.string_value
				values.push(value)
		sw_csv_row(csv, values)
	if (csv_path == 0): csv_path = path_join(work, c"results.csv")
	ht_write(csv_path, csv.data, csv.length)
	return summary
