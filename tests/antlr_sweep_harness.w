# wbuild: binary=antlr_sweep_driver arch=x64 dep=antlr_sweep_mock
# wbuild: target=antlr_sweep_harness_test tag=tests dep=antlr_sweep_driver
# wbuild: step="bin/antlr_sweep_driver"
import tools.antlr_sweep_lib

char* sh_root
char* sh_corpus
char* sh_work
json_value* sh_case
json_value* sh_tools
void sh_setup():
	sh_root = path_join(ht_temp(), c"with spaces")
	sh_corpus = path_join(sh_root, c"corpus")
	sh_work = path_join(sh_root, c"work")
	ht_mkdir(sh_corpus)
	ht_mkdir(sh_work)
	char* source = path_join(sh_corpus, c"Grammar.g4")
	char* text = c"grammar Fixture; root: 'a';"
	ht_write(source, text, strlen(text))
	sh_case = json_parse(c"{\"name\":\"fixture\",\"inputs\":[{\"path\":\"Grammar.g4\"}],\"expected_pass\":[\"translate\",\"generate\",\"compile\",\"strict\"]}")
	vj_s(ht_field(sh_case, c"inputs").array_values[0], c"sha256", sw_digest(source))
	sh_tools = json_object()
	for char* name in ht_command(c"translator generator compiler"):
		char* tool = path_join(sh_root, name)
		ht_require(shutil_copy(c"bin/antlr_sweep_mock", tool) == 0, c"cannot install sweep fixture")
		vj_s(sh_tools, name, tool)
	char* common = path_join(sh_root, c"common.w")
	ht_write(common, c"# common matchers\n", 18)
	vj_s(sh_tools, c"common_matchers", common)
void sh_mode(char* tool, char* mode): ht_write(strjoin(ht_text(sh_tools, tool), c".mode"), mode, strlen(mode))
json_value* sh_run(int timeout = 5000, int extended = 0): return sw_case(sh_case, sh_corpus, sh_work, sh_tools, timeout, sh_root, sw_configurations(extended))
json_value* sh_manifest():
	json_value* manifest = json_parse(c"{\"schema\":1,\"cases\":[]}")
	json_array_push(ht_field(manifest, c"cases"), sh_case)
	return manifest
json_value* sh_rows(json_value* row):
	json_value* rows = json_array()
	json_array_push(rows, row)
	return rows
json_value* sh_stage(json_value* row, char* stage): return ht_field(ht_field(row, c"stages"), stage)
void sh_status(json_value* row, char* stage, char* expected): ht_require(strcmp(ht_text(sh_stage(row, stage), c"status"), expected) == 0, strjoin(c"wrong stage attribution: ", stage))
json_value* sh_summary(json_value* row): return sw_write_results(sh_work, sh_manifest(), sh_rows(row), json_object())

# Pinned examples covering every verdict: expected accept and reject, a
# wrong verdict, a hang and a crash. Only the first two pass.
void sh_pin_examples():
	json_value* runtime = json_parse(c"{\"entry\":\"root\",\"entry_source\":\"pom.xml\",\"examples\":[]}")
	for char* spec in ht_command(c"ok:accept reject:reject reject-wrong:accept hang:accept crash:accept"):
		list[char*] parts = ht_split(spec, ':')
		char* path = strjoin(strjoin(c"ex/", parts[0]), c".txt")
		ht_mkdir(path_join(sh_corpus, c"ex"))
		ht_write(path_join(sh_corpus, path), parts[0], strlen(parts[0]))
		json_value* example = vj_one(c"path", path)
		vj_s(example, c"sha256", sw_digest(path_join(sh_corpus, path)))
		vj_s(example, c"expect", parts[1])
		json_array_push(ht_field(runtime, c"examples"), example)
	json_object_set(sh_case, c"runtime", runtime)
	sw_example_timeout_ms = 300

void sh_runtime(json_value* row):
	json_value* configs = ht_field(row, c"configurations")
	json_value* stages = ht_field(ht_field(configs, c"default_permissive"), c"stages")
	ht_require(sw_has(ht_field(ht_field(stages, c"translate"), c"argv"), c"--start") && sw_has(ht_field(ht_field(stages, c"translate"), c"argv"), c"root"), c"start rule not passed to the translator")
	json_value* examples = ht_field(stages, c"examples")
	ht_require(jc_is(ht_field(examples, c"status"), c"fail") && ht_number(examples, c"passed") == 2 && ht_number(examples, c"total") == 5, c"example verdicts not counted")
	list[char*] outcomes = new list[char*]
	for json_value* example in ht_field(examples, c"examples").array_values: outcomes.push(ht_text(example, c"outcome"))
	ht_require(strcmp(join(outcomes, c" "), c"accepted rejected rejected timeout crash") == 0, strjoin(c"example outcomes: ", join(outcomes, c" ")))
	json_object_set(sh_case, c"expected_configurations", json_parse(c"{\"default_permissive\":[\"translate\",\"generate\",\"compile\",\"compiler_strict\"]}"))
	json_object_set(sh_case, c"expected_examples", json_parse(c"{\"default_permissive\":[\"ex/ok.txt\",\"ex/reject-wrong.txt\"]}"))
	json_value* summary = sh_summary(row)
	ht_require(ht_field(summary, c"infrastructure_errors").array_values.length == 0, c"parser hang or crash reported as infrastructure")
	ht_require(jc_equal(ht_field(summary, c"regressions"), json_parse(c"[\"fixture: default_permissive/examples ex/reject-wrong.txt regressed to rejected\"]")), c"example regression not detected")
	ht_require(ht_number(ht_field(ht_field(summary, c"examples"), c"default_permissive"), c"examples_passed") == 2, c"example totals")
	json_value* progressions = ht_field(summary, c"progressions")
	ht_require(sw_has(progressions, c"fixture: default_permissive/examples ex/reject.txt progressed to pass") && sw_has(progressions, c"fixture: stateful_permissive/compile progressed to pass") && !sw_has(progressions, c"fixture: default_permissive/compile progressed to pass"), c"progressions not detected")
	json_value* accepted = ht_field(sw_accept(sh_manifest(), sh_rows(row)), c"cases").array_values[0]
	ht_require(jc_equal(ht_field(ht_field(accepted, c"expected_examples"), c"default_permissive"), json_parse(c"[\"ex/ok.txt\",\"ex/reject.txt\",\"ex/reject-wrong.txt\"]")), c"accepting progressions dropped a regression or lost order")
	ht_require(jc_equal(ht_field(ht_field(accepted, c"expected_configurations"), c"stateful_permissive"), json_parse(c"[\"translate\",\"generate\",\"compile\",\"compiler_strict\"]")), c"stage progressions not accepted")
	json_value* rows = sh_rows(row)
	ht_require(sw_progressions(sw_accept(sh_manifest(), rows), rows).array_values.length == 0, c"accepted baseline still reports progressions")

void sh_scenarios():
	for scenario in range(13):
		sh_setup()
		if (scenario == 1): sh_mode(c"generator", c"fail")
		if (scenario == 2): sh_mode(c"translator", c"fail")
		if (scenario == 3): sh_mode(c"translator", c"strict_fail")
		if (scenario == 4): sh_mode(c"generator", c"timeout")
		if (scenario == 5): sh_mode(c"translator", c"missing")
		if (scenario == 6): sh_mode(c"generator", c"crash")
		if (scenario == 7): sh_mode(c"compiler", c"fail")
		if (scenario == 8): sh_mode(c"compiler", c"strict_fail")
		if (scenario == 9): sh_mode(c"translator", c"stateful_fail")
		int timeout = 5000
		if (scenario == 4): timeout = 200
		if (scenario == 12): sh_pin_examples()
		json_value* row = sh_run(timeout, scenario == 10)
		json_value* configs = ht_field(row, c"configurations")
		if (scenario == 12): sh_runtime(row)
		if (scenario == 0 || (scenario >= 8 && scenario < 12)):
			for char* stage in sw_stages(): sh_status(row, stage, c"pass")
		if (scenario == 0):
			ht_require(jc_equal(ht_field(row, c"dependency_inputs"), ht_field(sh_case, c"inputs")), c"dependency closure differs")
			ht_require(jc_is(jc_get(ht_field(ht_field(ht_field(configs, c"default_permissive"), c"stages"), c"examples"), c"status"), c"no_examples"), c"examples claimed without pinned examples")
			ht_require(contains(ht_read(path_join(sh_work, c"fixture/compile.w")).data, c"sweep_fixture_parse(source, argv[1], diagnostics)"), c"compile harness does not drive the generated parser")
			ht_require(contains(ht_read(path_join(sh_work, c"fixture/compile.log")).data, c"commas and \"quotes\""), c"log bytes lost")
			set[char*] programs = new set[char*]
			for char* name in configs.object_values.keys():
				json_value* current = ht_field(configs, name)
				json_value* stages = ht_field(current, c"stages")
				for char* stage in sw_build_stages():
					if (strcmp(stage, c"examples") != 0): ht_require(sw_pass(ht_field(stages, stage)), c"configuration did not build")
				json_value* compile_args = ht_field(ht_field(stages, c"compile"), c"argv")
				json_value* strict_args = ht_field(ht_field(stages, c"compiler_strict"), c"argv")
				programs.add(compile_args.array_values[1].string_value)
				ht_require(jc_equal(compile_args.array_values[1], strict_args.array_values[1]) && sw_has(strict_args, c"--strict") && !sw_has(compile_args, c"--strict"), c"compiler strict measurement not independent")
				ht_require(jc_equal(ht_field(current, c"dependency_inputs"), ht_field(sh_case, c"inputs")), c"configuration closure differs")
			ht_require(programs.length == 4, c"configuration artifacts reused")
			ht_require(jc_equal(sh_stage(row, c"strict"), ht_field(ht_field(ht_field(configs, c"default_strict"), c"stages"), c"translate")), c"historical strict column changed")
			json_value* summary = sh_summary(row)
			ht_require(ht_number(ht_json(path_join(sh_work, c"results.json")), c"schema") == 2, c"sweep report schema")
			for char* stage in sw_stages(): ht_require(ht_number(ht_field(summary, c"passing"), stage) == 1, c"historical counts changed")
			ht_require(contains(ht_read(path_join(sh_work, c"results.csv")).data, c"\"default_strict/compiler_strict\""), c"CSV configuration column missing")
			int pid = fork()
			ht_require(pid >= 0, c"cannot fork stale artifact check")
			if (pid == 0):
				ht_scratch = 0
				ht_children = 0
				sh_run()
				exit(0)
			int status = 0
			wait4(pid, &status, 0, 0)
			ht_require(process_decode_status(status) != 0, c"stale artifacts accepted")
		if (scenario == 1):
			sh_status(row, c"translate", c"pass")
			sh_status(row, c"compile", c"not_run")
			sh_status(row, c"strict", c"pass")
			ht_require(ht_number(sh_stage(row, c"generate"), c"exit_code") == 7, c"generator exit attribution")
		if (scenario == 2):
			sh_status(row, c"generate", c"not_run")
			ht_require(ht_number(sh_stage(row, c"strict"), c"exit_code") == 7, c"strict failure not audited")
		if (scenario == 3):
			sh_status(row, c"compile", c"pass")
			sh_status(row, c"strict", c"fail")
		if (scenario == 4 || scenario == 6):
			json_object_set(sh_case, c"expected_pass", json_array())
			json_value* summary = sh_summary(row)
			ht_require(ht_field(summary, c"regressions").array_values.length == 0 && ht_field(summary, c"infrastructure_errors").array_values.length == 4, c"baseline failure concealed infrastructure failure")
			if (scenario == 4):
				sh_status(row, c"generate", c"timeout")
				ht_require(contains(ht_read(path_join(sh_work, c"fixture/generate.log")).data, c"stage timeout"), c"timeout log missing")
			else: ht_require(ht_number(sh_stage(row, c"generate"), c"exit_code") < 0, c"signal crash lost negative status")
		if (scenario == 5):
			sh_status(row, c"translate", c"error")
			sh_status(row, c"generate", c"not_run")
		if (scenario == 7):
			json_value* passed = vj_copy(row)
			vj_s(passed, c"name", c"newly_passing")
			json_object_set(passed, c"stages", sw_empty(sw_stages(), c"pass"))
			json_value* rows = sh_rows(row)
			json_array_push(rows, passed)
			json_value* summary = sw_write_results(sh_work, sh_manifest(), rows, json_object())
			ht_require(ht_number(ht_field(summary, c"passing"), c"compile") == 1 && jc_equal(ht_field(summary, c"regressions"), json_parse(c"[\"fixture: compile regressed to fail\"]")), c"another case hid regression")
			ht_require(jc_equal(sw_compare(sh_manifest(), json_array()), json_parse(c"[\"fixture: missing result\"]")), c"missing result not detected")
		if (scenario == 8):
			for char* name in configs.object_values.keys():
				json_value* stages = ht_field(ht_field(configs, name), c"stages")
				ht_require(sw_pass(ht_field(stages, c"compile")) && jc_is(ht_field(ht_field(stages, c"compiler_strict"), c"status"), c"fail"), c"warning failure erased ordinary compile")
			json_object_set(sh_case, c"expected_configurations", json_parse(c"{\"stateful_strict\":[\"compiler_strict\"]}"))
			ht_require(jc_equal(sw_compare(sh_manifest(), sh_rows(row)), json_parse(c"[\"fixture: stateful_strict/compiler_strict regressed to fail\"]")), c"configuration regression not detected")
		if (scenario == 9):
			for char* name in ht_command(c"stateful_permissive stateful_strict"):
				json_value* stages = ht_field(ht_field(configs, name), c"stages")
				ht_require(ht_number(ht_field(stages, c"translate"), c"exit_code") == 8 && jc_is(ht_field(ht_field(stages, c"compile"), c"status"), c"not_run"), c"stateful failure attribution")
		if (scenario == 10):
			ht_require(configs.object_values.length == 6, c"extended configurations not separate")
			json_value* stages = ht_field(ht_field(configs, c"exact_strict"), c"stages")
			for char* flag in ht_command(c"--strict --exact-lexer --prediction"): ht_require(sw_has(ht_field(ht_field(stages, c"translate"), c"argv"), flag), c"extended translator flag missing")
			ht_require(contains(ht_field(ht_field(stages, c"compile"), c"argv").array_values[1].string_value, c"exact_strict"), c"extended artifacts reused")
		if (scenario == 11):
			json_value* findings = ht_field(ht_field(configs, c"default_strict"), c"findings")
			ht_require(strcmp(ht_text(findings.array_values[0], c"code"), c"AT_FIXTURE") == 0 && ht_number(findings.array_values[0], c"column") == 2, c"structured findings not preserved")
			json_value* duplicate = vj_copy(findings.array_values[0])
			vj_i(duplicate, c"line", 2)
			json_array_push(findings, duplicate)
			ht_require(ht_number(ht_field(ht_field(sh_summary(row), c"finding_grammar_counts"), c"default_strict"), c"AT_FIXTURE") == 1, c"findings counted instances instead of grammars")

void sh_manifest_tests():
	sh_setup()
	for char* text in ht_split(c"{}|{\"schema_version\":1,\"findings\":[\"bad\"]}|{\"schema_version\":1,\"findings\":[{\"code\":\"AT_BAD\"}]}", '|'):
		char* path = path_join(sh_root, c"bad.audit.json")
		ht_write(path, text, strlen(text))
		ht_require(sw_findings(path) == 0, c"malformed audit accepted")
	ht_checked(ht_argv(c"git", c"init", c"-q", sh_corpus))
	ht_checked(ht_argv(c"git", c"-C", sh_corpus, c"add", c"."))
	ht_checked(ht_argv(c"git", c"-C", sh_corpus, c"-c", c"user.name=Sweep Test", c"-c", c"user.email=sweep@example.invalid", c"commit", c"-qm", c"fixture"))
	char* commit = sw_git(sh_corpus, ht_command(c"rev-parse HEAD"))
	json_value* manifest = sh_manifest()
	vj_s(manifest, c"corpus_commit", commit)
	char* path = path_join(sh_root, c"manifest.json")
	vj_write(path, manifest)
	ht_require(jc_equal(sw_load(path, sh_corpus), manifest), c"valid manifest rejected")
	char* source = path_join(sh_corpus, c"Grammar.g4")
	ht_write(source, c"changed", 7)
	ht_require(sw_load(path, sh_corpus) == 0 && contains(sw_error, c"hash/path mismatch"), c"changed source accepted")
	ht_checked(ht_argv(c"git", c"-C", sh_corpus, c"checkout", c"--", c"Grammar.g4"))
	char* sibling = path_join(sh_corpus, c"Unpinned.g4")
	ht_write(sibling, c"lexer grammar Unpinned;", 23)
	ht_require(sw_load(path, sh_corpus) == 0 && contains(sw_error, c"untracked siblings"), c"unpinned sibling shadow accepted")
	unlink(sibling)
	vj_s(manifest, c"corpus_commit", ht_repeat('0', 40))
	vj_write(path, manifest)
	ht_require(sw_load(path, sh_corpus) == 0 && contains(sw_error, c"revision mismatch"), c"wrong revision accepted")
	vj_s(manifest, c"corpus_commit", commit)
	json_object_set(sh_case, c"recorded_pass", json_parse(c"[\"compile\"]"))
	json_object_set(sh_case, c"expected_pass", json_array())
	vj_write(path, manifest)
	ht_require(sw_load(path, sh_corpus) == 0 && contains(sw_error, c"requires a reclassified reason"), c"historical pass removed without reason")
	json_object_set(sh_case, c"reclassified", json_parse(c"{\"compile\":\"Fixture intentionally rejects an unsafe empty token\"}"))
	vj_write(path, manifest)
	ht_require(sw_load(path, sh_corpus) != 0, c"documented reclassification rejected")
	json_array_push(ht_field(manifest, c"cases"), sh_case)
	vj_write(path, manifest)
	ht_require(sw_load(path, sh_corpus) == 0 && contains(sw_error, c"duplicate case"), c"duplicate case accepted")
	json_value* pinned = ht_json(c"libs/extras/grammars/antlr_to_pg/sweep_baseline.json")
	set[char*] names = new set[char*]
	int historical = 0
	int compiled = 0
	int strict = 0
	for json_value* entry in ht_field(pinned, c"cases").array_values:
		names.add(ht_text(entry, c"name"))
		historical = historical + ht_field(entry, c"historical_288").int_value
		compiled = compiled + sw_has(ht_field(entry, c"recorded_pass"), c"compile")
		strict = strict + sw_has(ht_field(entry, c"recorded_pass"), c"strict")
	ht_require(ht_field(pinned, c"cases").array_values.length == 291 && names.length == 291 && historical == 288 && compiled == 179 && strict == 10 && strcmp(ht_text(pinned, c"baseline_w_commit"), c"298246c6d6906650d4cd9c677e93933abd9bf619") == 0, c"original measurement baseline changed")

void sh_file(char* root, char* path, char* text, int length):
	ht_mkdir(path_dirname(path_join(root, path)))
	ht_write(path_join(root, path), text, length)

list[char*] sh_selected(json_value* runtime):
	list[char*] out = new list[char*]
	for json_value* example in ht_field(runtime, c"examples").array_values: out.push(strjoin(strjoin(ht_text(example, c"path"), c"="), ht_text(example, c"expect")))
	return out

# Example selection reads the pinned revision through git: pom/desc start
# rules, the first desc.xml test's patterns, exclusions and byte order.
void sh_selection_tests():
	char* corpus = path_join(ht_temp(), c"selection")
	sh_file(corpus, c"fx/G.g4", c"grammar G;\nroot: 'a';\n", 23)
	sh_file(corpus, c"fx/pom.xml", c"<entryPoint>root</entryPoint>", 29)
	for char* name in ht_command(c"examples/b.txt examples/a.txt examples/sub/d.txt examples/.hidden examples/c.tree examples/z.txt"): sh_file(corpus, strjoin(c"fx/", name), c"a", 1)
	sh_file(corpus, c"fx/examples/b.txt.errors", c"line 1: error", 13)
	sh_file(corpus, c"fx/examples/z.txt.errors", c"", 0)
	sh_file(corpus, c"fx/examples/big.txt", ht_repeat('a', 101), 101)
	sh_file(corpus, c"fx/examples/nul.txt", c"a\0b", 3)
	sh_file(corpus, c"fx/examples/sp ace.txt", c"a", 1)
	sh_file(corpus, c"fy/G.g4", c"grammar G;\nstart: 'a';\nother: start;\n", 37)
	# The first test names a rule of a sibling grammar, so the second is used.
	char* desc = c"<desc><test><entry-point>absent</entry-point><inputs>examples</inputs></test><test><entry-point>start</entry-point><inputs>more</inputs><inputs>!more/skip*</inputs></test><test><entry-point>other</entry-point><inputs>examples</inputs></test></desc>"
	sh_file(corpus, c"fy/desc.xml", desc, strlen(desc))
	sh_file(corpus, c"fy/pom.xml", c"<entryPoint>ignored</entryPoint>", 32)
	for char* name in ht_command(c"more/x.txt more/skip1.txt more/deep/y.txt examples/e.txt"): sh_file(corpus, strjoin(c"fy/", name), c"a", 1)
	sh_file(corpus, c"fz/G.g4", c"grammar G;\nstart: 'a';\n", 24)
	sh_file(corpus, c"fz/pom.xml", c"<entryPoint>elsewhere</entryPoint>", 34)
	sh_file(corpus, c"fz/examples/only.txt", c"a", 1)
	ht_checked(ht_argv(c"git", c"init", c"-q", corpus))
	ht_checked(ht_argv(c"git", c"-C", corpus, c"add", c"."))
	ht_checked(ht_argv(c"git", c"-C", corpus, c"-c", c"user.name=Sweep Test", c"-c", c"user.email=sweep@example.invalid", c"commit", c"-qm", c"fixture"))
	json_value* fx = sw_select_runtime(json_parse(c"{\"inputs\":[{\"path\":\"fx/G.g4\"}]}"), corpus, 10, 100)
	ht_require(jc_is(ht_field(fx, c"entry"), c"root") && jc_is(ht_field(fx, c"entry_source"), c"pom.xml"), c"pom.xml start rule")
	ht_require(strcmp(join(sh_selected(fx), c" "), c"fx/examples/a.txt=accept fx/examples/b.txt=reject fx/examples/sub/d.txt=accept fx/examples/z.txt=accept") == 0, strjoin(c"default example selection: ", join(sh_selected(fx), c" ")))
	ht_require(strcmp(ht_text(ht_field(fx, c"examples").array_values[0], c"sha256"), sw_digest(path_join(corpus, c"fx/examples/a.txt"))) == 0, c"example hash")
	ht_require(ht_field(sw_select_runtime(json_parse(c"{\"inputs\":[{\"path\":\"fx/G.g4\"}]}"), corpus, 1, 100), c"examples").array_values.length == 1, c"example limit")
	json_value* fy = sw_select_runtime(json_parse(c"{\"inputs\":[{\"path\":\"fy/G.g4\"}]}"), corpus, 10, 100)
	ht_require(jc_is(ht_field(fy, c"entry"), c"start") && jc_is(ht_field(fy, c"entry_source"), c"desc.xml"), c"desc.xml start rule")
	ht_require(strcmp(join(sh_selected(fy), c" "), c"fy/more/deep/y.txt=accept fy/more/x.txt=accept") == 0, strjoin(c"desc.xml input patterns: ", join(sh_selected(fy), c" ")))
	# Files a sparse checkout omits are still read from the pinned revision.
	unlink(path_join(corpus, c"fz/examples/only.txt"))
	json_value* fz = sw_select_runtime(json_parse(c"{\"inputs\":[{\"path\":\"fz/G.g4\"}]}"), corpus, 10, 100)
	ht_require(jc_type(ht_field(fz, c"entry"), json_type_null()) && jc_is(ht_field(fz, c"entry_source"), c"first parser rule") && strcmp(join(sh_selected(fz), c" "), c"fz/examples/only.txt=accept") == 0, c"selection without metadata or checkout")
	json_value* manifest = json_parse(c"{\"cases\":[{\"name\":\"fx\"}]}")
	json_object_set(ht_field(manifest, c"cases").array_values[0], c"runtime", fx)
	ht_require(strcmp(sw_sparse_patterns(manifest), c"/*/*.g4\n/fx/examples/a.txt\n/fx/examples/b.txt\n/fx/examples/sub/d.txt\n/fx/examples/z.txt\n") == 0, c"sparse patterns")
	ht_require(strcmp(sw_pretty(json_parse(c"{\"a\":[],\"b\":{\"c\":[1,\"x\"]},\"d\":{}}")), c"{\n  \"a\": [],\n  \"b\": {\n    \"c\": [\n      1,\n      \"x\"\n    ]\n  },\n  \"d\": {}\n}\n") == 0, c"pretty baseline layout")
	char* pinned = ht_read(c"libs/extras/grammars/antlr_to_pg/sweep_baseline.json").data
	ht_require(strcmp(sw_pretty(json_parse(pinned)), pinned) == 0, c"committed baseline is not in the rewritten layout")

int main():
	sh_scenarios()
	sh_manifest_tests()
	sh_selection_tests()
	ht_cleanup()
	println(c"ANTLR sweep harness checks OK")
	return 0
