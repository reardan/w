# wbuild: binary=antlr_sweep arch=x64 tag=tests
import tools.antlr_sweep_lib
import libs.standard.cli.argparse

json_value* sw_tool_hashes(json_value* tools):
	json_value* hashes = json_object()
	for char* name in tools.object_values.keys(): vj_s(hashes, name, sw_digest(ht_text(tools, name)))
	return hashes

int main(int argc, int argv):
	arg_parser* parser = argparse_new(c"antlr_sweep")
	arg_spec* corpus_option = argparse_add_option(parser, c"--corpus", c"PATH", c"pinned grammars-v4 checkout")
	if (env_get(c"GV4") != 0): argparse_arg_default(corpus_option, env_get(c"GV4"))
	argparse_arg_default(argparse_add_option(parser, c"--manifest", c"FILE", c"baseline"), c"libs/extras/grammars/antlr_to_pg/sweep_baseline.json")
	arg_spec* work_option = argparse_add_option(parser, c"--work", c"PATH", c"new/empty artifact directory")
	if (env_get(c"WORK") != 0): argparse_arg_default(work_option, env_get(c"WORK"))
	arg_spec* csv_option = argparse_add_option(parser, c"--csv", c"FILE", c"CSV output")
	if (env_get(c"OUT_CSV") != 0): argparse_arg_default(csv_option, env_get(c"OUT_CSV"))
	char* jobs_default = env_get(c"JOBS")
	if (jobs_default == 0): jobs_default = c"4"
	argparse_arg_default(argparse_add_int(parser, c"--jobs", c"N", c"concurrent cases"), jobs_default)
	argparse_arg_default(argparse_add_float(parser, c"--timeout", c"SECONDS", c"per stage"), c"90")
	argparse_add_list(parser, c"--case", c"NAME", c"selected pinned cases")
	argparse_add_flag(parser, c"--extended-configurations", c"also measure exact lexer/prediction")
	arg_namespace* args = argparse_parse_or_exit(parser, argc, argv)
	ht_require(argparse_get(args, c"corpus") != 0, c"set GV4 or pass --corpus")
	int jobs = argparse_get_int(args, c"jobs")
	float seconds = argparse_get_float(args, c"timeout")
	ht_require(jobs >= 1 && seconds > 0.0 && seconds <= 2147483.0, c"jobs and timeout must be positive and bounded")
	int timeout = cast(int, seconds * 1000.0)
	char* corpus = ht_resolve(argparse_get(args, c"corpus"))
	char* repo = ht_resolve(c".")
	char* manifest_path = argparse_get(args, c"manifest")
	json_value* manifest = sw_load(manifest_path, corpus)
	if (manifest == 0):
		println2(strjoin(c"sweep: ", sw_error))
		return 2
	json_value* configurations = sw_configurations(argparse_get_bool(args, c"extended_configurations"))
	json_value* cases = ht_field(manifest, c"cases")
	list[char*] selected = argparse_get_list(args, c"case")
	if (selected.length > 0):
		json_value* chosen = json_array()
		set[char*] found = new set[char*]
		for json_value* entry in cases.array_values:
			if (ht_text(entry, c"name") in selected):
				json_array_push(chosen, entry)
				found.add(ht_text(entry, c"name"))
		for char* name in selected: ht_require(name in found, strjoin(c"unknown case: ", name))
		cases = chosen
		json_object_set(manifest, c"cases", cases)
	json_value* tools = json_object()
	vj_s(tools, c"translator", path_join(repo, c"bin/antlr_to_pg"))
	vj_s(tools, c"generator", path_join(repo, c"bin/parser_generator_grammars"))
	vj_s(tools, c"compiler", path_join(repo, c"bin/wv2"))
	vj_s(tools, c"common_matchers", path_join(repo, c"libs/extras/grammars/matchers.w"))
	for char* name in tools.object_values.keys():
		char* path = ht_text(tools, name)
		file_stat st
		ht_require(sw_is_file(path) && file_stat_path(path, &st) == 0 && (strcmp(name, c"common_matchers") == 0 || (st.mode & 73) != 0), strjoin(c"missing tool/input; run ./wbuild antlr_to_pg: ", path))
	char* work = argparse_get(args, c"work")
	if (work != 0):
		work = ht_resolve(work)
		ht_mkdir(work)
		# Include dotfiles when checking that no stale artifacts can be reused.
		ht_require(glob_glob(path_join(work, c"*")).length == 0 && glob_glob(path_join(work, c".[!.]*")).length == 0 && glob_glob(path_join(work, c"..?*")).length == 0, c"artifact directory is not empty")
	else:
		ht_mkdir(c"bin/grammar_sweep")
		work = tempfile_mkdtemp_in(ht_resolve(c"bin/grammar_sweep"), c"run-", c"")
		ht_require(work != 0, c"cannot create sweep artifacts")
	json_value* provenance = json_object()
	json_object_set(provenance, c"corpus_commit", ht_field(manifest, c"corpus_commit"))
	vj_s(provenance, c"w_commit", sw_git(repo, ht_command(c"rev-parse HEAD")))
	vj_b(provenance, c"w_dirty", sw_git(repo, ht_command(c"status --porcelain"))[0] != 0)
	vj_s(provenance, c"manifest_sha256", sw_digest(manifest_path))
	vj_s(provenance, c"runner_sha256", sw_digest(c"tools/antlr_sweep.w"))
	json_object_set(provenance, c"tools_sha256", sw_tool_hashes(tools))
	if (selected.length > 0): json_object_set(provenance, c"selection", vj_strings(selected))
	else: vj_s(provenance, c"selection", c"all pinned cases")
	json_object_set(provenance, c"configurations", configurations)
	vj_f(provenance, c"timeout_seconds", seconds)
	vj_s(provenance, c"compile_harness", c"empty main; generated parser is not executed")
	println(strjoin(c"Artifacts: ", work))
	map[int, json_value*] active = new map[int, json_value*]
	map[char*, json_value*] completed = new map[char*, json_value*]
	int next = 0
	while (next < cases.array_values.length || active.length > 0):
		while (next < cases.array_values.length && active.length < jobs):
			json_value* entry = cases.array_values[next]
			next = next + 1
			int pid = fork()
			ht_require(pid >= 0, c"cannot fork sweep case")
			if (pid == 0):
				ht_scratch = 0
				ht_children = 0
				json_value* result = sw_case(entry, corpus, work, tools, timeout, repo, configurations)
				vj_write(path_join(work, strjoin(ht_text(entry, c"name"), c".result.json")), result)
				ht_cleanup()
				exit(0)
			active[pid] = entry
		for int pid in active.keys():
			int status = 0
			int reaped = wait4(pid, &status, 1, 0)
			if (reaped == 0 || reaped == -4): continue
			ht_require(reaped == pid, c"cannot reap sweep worker")
			json_value* entry = active[pid]
			char* name = ht_text(entry, c"name")
			char* path = path_join(work, strjoin(name, c".result.json"))
			json_value* result = 0
			if (status == 0 && path_exists(path)): result = json_parse(ht_read(path).data)
			if (result == 0):
				result = vj_one(c"name", name)
				json_object_set(result, c"inputs", ht_field(entry, c"inputs"))
				vj_b(result, c"historical_288", jc_get(entry, c"historical_288") != 0 && ht_field(entry, c"historical_288").int_value)
				vj_s(result, c"runtime_smoke", c"not_configured")
				json_object_set(result, c"configurations", sw_empty_configs(configurations, c"error"))
				json_object_set(result, c"stages", sw_empty(sw_stages(), c"error"))
				vj_s(result, c"error", c"case worker failed; see terminal diagnostics")
			completed[name] = result
			active.remove(pid)
			println(strjoin(strjoin(c"completed ", name), strjoin(c" (", strjoin(itoa(completed.length), c")"))))
		if (active.length > 0): process_sleep_ms(10)
	list[char*] names = completed.keys()
	ht_sort(names)
	json_value* results = json_array()
	for char* name in names: json_array_push(results, completed[name])
	json_value* hashes = sw_tool_hashes(tools)
	json_object_set(provenance, c"tools_sha256_after", hashes)
	json_value* errors = json_array()
	for char* name in hashes.object_values.keys():
		if (!jc_equal(ht_field(hashes, name), ht_field(ht_field(provenance, c"tools_sha256"), name))): json_array_push(errors, json_string(strjoin(c"tool/input changed during sweep: ", name)))
	if (sw_git(corpus, ht_command(c"status --porcelain --untracked-files=all -- *.g4"))[0] != 0): json_array_push(errors, json_string(c"corpus grammar files changed during sweep"))
	json_object_set(provenance, c"infrastructure_errors", errors)
	json_value* summary = sw_write_results(work, manifest, results, provenance, argparse_get(args, c"csv"))
	println(json_stringify(summary))
	return ht_field(summary, c"regressions").array_values.length > 0 || ht_field(summary, c"infrastructure_errors").array_values.length > 0
