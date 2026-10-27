# Staged grammars-v4 sweep: each configuration has independent artifacts,
# dependency closure evidence, semantic outcomes and infrastructure failures.
import tools.host_report
import tools.javascript_conformance_lib
import libs.standard.fs.glob
import libs.standard.text.re

char* sw_error
list[char*] sw_stages(): return ht_command(c"translate generate compile strict")
list[char*] sw_build_stages(): return ht_command(c"translate generate compile compiler_strict examples")
# Each example runs in its own process with this ceiling (or the stage
# timeout, if smaller); a hung parser is a measured failure, not an
# infrastructure error.
int sw_example_timeout_ms = 10000
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
int sw_is_file(char* path):
	file_stat st
	return file_stat_path(path, &st) == 0 && (st.mode & FILE_S_IFMT) == FILE_S_IFREG
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

# A case's optional `runtime` pins the start rule and the example inputs
# its generated parser must accept (or, with a non-empty upstream
# `.errors` file, reject); `expected_examples` lists, per configuration,
# the pinned examples that currently behave as expected.
int sw_check_runtime(json_value* entry, char* corpus):
	json_value* runtime = jc_get(entry, c"runtime")
	set[char*] paths = new set[char*]
	if (runtime != 0):
		json_value* start = jc_get(runtime, c"entry")
		if (!sw_check(start == 0 || jc_type(start, json_type_null()) || (jc_type(start, json_type_string()) && re_fullmatch(re_compile(c"[A-Za-z_][A-Za-z0-9_]*", 0), start.string_value) != 0), c"invalid runtime entry rule")): return 0
		json_value* examples = jc_get(runtime, c"examples")
		if (!sw_check(jc_type(examples, json_type_array()), c"runtime examples must be an array")): return 0
		for json_value* example in examples.array_values:
			json_value* expect = jc_get(example, c"expect")
			if (!sw_check(jc_is(expect, c"accept") || jc_is(expect, c"reject"), c"runtime example expect must be accept or reject")): return 0
			char* path = ht_text(example, c"path")
			if (!sw_check(!(path in paths), c"duplicate runtime example")): return 0
			paths.add(path)
			char* resolved = ht_resolve(strjoin(strjoin(corpus, c"/"), path))
			if (!sw_check(resolved != 0 && starts_with(resolved, strjoin(corpus, c"/")) && sw_is_file(resolved) && strcmp(sw_digest(resolved), ht_text(example, c"sha256")) == 0, c"runtime example hash/path mismatch (check out the pinned examples; see --sparse-patterns)")): return 0
	json_value* expected = jc_get(entry, c"expected_examples")
	if (expected == 0): return 1
	json_value* all_configs = sw_configurations(1)
	for char* configuration in expected.object_values.keys():
		if (!sw_check(json_object_has(all_configs, configuration), c"invalid example baseline configuration")): return 0
		for json_value* path in ht_field(expected, configuration).array_values:
			if (!sw_check(jc_type(path, json_type_string()) && path.string_value in paths, c"example baseline names an unpinned example")): return 0
	return 1

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
		if (!sw_check_runtime(entry, corpus)): return 0
	if (!sw_check(sw_git(corpus, ht_command(c"status --porcelain --untracked-files=all -- *.g4"))[0] == 0, c"corpus grammar files must be clean (including untracked siblings)")): return 0
	return manifest

# Runtime example selection. It runs once, when the baseline is (re)pinned,
# and reads the corpus through git, so it sees files a sparse checkout omits.
# For a case directory D: the start rule and input patterns come from the
# first <test> of D/desc.xml (or the whole file), the start rule otherwise
# from D/pom.xml's first <entryPoint>, else the first parser rule; patterns
# default to examples/**. Candidates are blobs under D matching a positive
# pattern and no `!` pattern, excluding *.errors/*.tree, hidden segments,
# paths outside [A-Za-z0-9._/+-], files over max_bytes and files with NUL
# bytes; the first max_examples in byte order are pinned. An example with a
# non-empty sibling `.errors` file must be rejected, any other accepted.
char* sw_xml_tag_from(char* text, char* tag, int* next):
	char* open = strjoin(strjoin(c"<", tag), c">")
	int at = index_of(text, open)
	if (at < 0): return 0
	char* rest = text + at + strlen(open)
	int end = index_of(rest, strjoin(strjoin(c"</", tag), c">"))
	if (end < 0): return 0
	next[0] = at + strlen(open) + end
	return strip(substring(rest, 0, end))
char* sw_xml_tag(char* text, char* tag):
	int next = 0
	return sw_xml_tag_from(text, tag, &next)
list[char*] sw_xml_tags(char* text, char* tag):
	list[char*] out = new list[char*]
	int next = 0
	char* value = sw_xml_tag_from(text, tag, &next)
	while (value != 0):
		out.push(value)
		text = text + next
		value = sw_xml_tag_from(text, tag, &next)
	return out
# Each <test> of a desc.xml, or the whole file when it has none.
list[char*] sw_xml_scopes(char* text):
	list[char*] scopes = sw_xml_tags(text, c"test")
	if (scopes.length == 0): scopes.push(text)
	return scopes
# Whether a selected grammar declares parser rule `rule` at the start of a
# line (the corpus convention); upstream metadata can name a rule of a
# sibling grammar that this case does not translate.
int sw_defines_rule(list[char*] grammars, char* rule):
	int n = strlen(rule)
	for char* text in grammars:
		for char* line in ht_split(text, 10):
			if (starts_with(line, rule) && !isalnum(line[n]) && line[n] != '_'): return 1
	return 0
# Path-segment glob: `**` spans zero or more whole segments.
int sw_glob_match(list[char*] path, int pi, list[char*] pattern, int qi):
	if (qi == pattern.length): return pi == path.length
	if (strcmp(pattern[qi], c"**") == 0):
		for i in range(pi, path.length + 1):
			if (sw_glob_match(path, i, pattern, qi + 1)): return 1
		return 0
	if (pi == path.length): return 0
	return fnmatch_match(path[pi], pattern[qi]) && sw_glob_match(path, pi + 1, pattern, qi + 1)
int sw_glob_any(list[list[char*]] patterns, list[char*] path):
	for list[char*] pattern in patterns:
		if (sw_glob_match(path, 0, pattern, 0)): return 1
	return 0
# Checked-out files are read directly (the caller requires a clean corpus);
# others come from git, which may fetch them lazily from a partial clone.
char* sw_blob(char* corpus, char* path, char* object, int* length):
	char* local = path_join(corpus, path)
	if (sw_is_file(local)):
		string_builder* data = ht_read(local)
		length[0] = data.length
		return data.data
	process_result* result = ht_run(ht_argv(c"git", c"-C", corpus, c"cat-file", c"blob", object), 0, 0, 600000)
	ht_success(result)
	length[0] = result.stdout_length
	return result.stdout_text

int sw_blob_size(char* corpus, char* path, char* object):
	file_stat st
	if (file_stat_path(path_join(corpus, path), &st) == 0 && (st.mode & FILE_S_IFMT) == FILE_S_IFREG): return st.size
	process_result* result = ht_run(ht_argv(c"git", c"-C", corpus, c"cat-file", c"-s", object), 0, 0, 600000)
	ht_success(result)
	return atoi(strip(result.stdout_text))

json_value* sw_select_runtime(json_value* entry, char* corpus, int max_examples, int max_bytes):
	char* first = ht_text(ht_field(entry, c"inputs").array_values[0], c"path")
	char* dir = substring(first, 0, index_of(first, c"/"))
	# No `-l`: object sizes would fetch every blob of a partial clone.
	process_result* listing = ht_checked(ht_argv(c"git", c"-C", corpus, c"ls-tree", c"-r", c"HEAD", c"--", strjoin(dir, c"/")))
	map[char*, char*] blobs = new map[char*, char*]
	list[char*] paths = new list[char*]
	for char* line in ht_split(listing.stdout_text, 10):
		int tab = index_of(line, c"\t")
		if (tab < 0): continue
		list[char*] fields = split(substring(line, 0, tab))
		if (fields.length != 3 || strcmp(fields[1], c"blob") != 0): continue
		char* path = line + tab + 1
		blobs[path] = fields[2]
		paths.push(path)
	ht_sort(paths)
	int length = 0
	list[char*] grammars = new list[char*]
	for json_value* input in ht_field(entry, c"inputs").array_values: grammars.push(ht_read(path_join(corpus, ht_text(input, c"path"))).data)
	char* scope = c""
	char* start = 0
	char* source = c"desc.xml"
	char* desc = strjoin(dir, c"/desc.xml")
	if (desc in blobs):
		list[char*] scopes = sw_xml_scopes(sw_blob(corpus, desc, blobs[desc], &length))
		scope = scopes[0]
		for char* candidate in scopes:
			char* rule = sw_xml_tag(candidate, c"entry-point")
			if (rule != 0 && sw_defines_rule(grammars, rule)):
				scope = candidate
				start = rule
				break
	json_value* runtime = json_object()
	char* pom = strjoin(dir, c"/pom.xml")
	if (start == 0 && pom in blobs):
		start = sw_xml_tag(sw_blob(corpus, pom, blobs[pom], &length), c"entryPoint")
		source = c"pom.xml"
	if (start != 0 && (re_fullmatch(re_compile(c"[A-Za-z_][A-Za-z0-9_]*", 0), start) == 0 || !sw_defines_rule(grammars, start))): start = 0
	if (start != 0): vj_s(runtime, c"entry", start)
	else:
		json_object_set(runtime, c"entry", json_null())
		source = c"first parser rule"
	vj_s(runtime, c"entry_source", source)
	list[char*] patterns = sw_xml_tags(scope, c"inputs")
	if (patterns.length == 0): patterns.push(c"examples/**")
	list[list[char*]] include = new list[list[char*]]
	list[list[char*]] exclude = new list[list[char*]]
	for char* pattern in patterns:
		int negative = pattern[0] == '!'
		if (negative): pattern = pattern + 1
		char* prefix = strjoin(strjoin(strjoin(dir, c"/"), pattern), c"/")
		int directory = 0
		for char* path in paths:
			if (starts_with(path, prefix)): directory = 1
		if (!glob_has_magic(pattern) && directory): pattern = strjoin(pattern, c"/**")
		if (negative): exclude.push(ht_split(pattern, '/'))
		else: include.push(ht_split(pattern, '/'))
	json_value* examples = json_array()
	for char* path in paths:
		if (examples.array_values.length >= max_examples): break
		if (ends_with(path, c".errors") || ends_with(path, c".tree") || re_fullmatch(re_compile(c"[A-Za-z0-9._/+-]+", 0), path) == 0): continue
		list[char*] segments = ht_split(path + strlen(dir) + 1, '/')
		int hidden = 0
		for char* segment in segments:
			if (segment[0] == '.'): hidden = 1
		if (hidden || !sw_glob_any(include, segments) || sw_glob_any(exclude, segments) || sw_blob_size(corpus, path, blobs[path]) > max_bytes): continue
		char* text = sw_blob(corpus, path, blobs[path], &length)
		if (strlen(text) != length): continue
		json_value* example = vj_one(c"path", path)
		vj_s(example, c"sha256", ht_digest(text, length))
		char* errors = strjoin(path, c".errors")
		if (errors in blobs && sw_blob_size(corpus, errors, blobs[errors]) > 0): vj_s(example, c"expect", c"reject")
		else: vj_s(example, c"expect", c"accept")
		json_array_push(examples, example)
	json_object_set(runtime, c"examples", examples)
	return runtime

# Sparse-checkout patterns for exactly the pinned corpus files: every
# top-level grammar plus each pinned runtime example.
char* sw_sparse_patterns(json_value* manifest):
	string_builder* out = string_from(c"/*/*.g4\n")
	for json_value* entry in ht_field(manifest, c"cases").array_values:
		json_value* examples = jc_get(jc_get(entry, c"runtime"), c"examples")
		if (!jc_type(examples, json_type_array())): continue
		for json_value* example in examples.array_values:
			string_append_char(out, '/')
			string_append(out, ht_text(example, c"path"))
			string_append_char(out, 10)
	return out.data

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

char* sw_runtime_entry(json_value* entry):
	json_value* start = jc_get(jc_get(entry, c"runtime"), c"entry")
	if (jc_type(start, json_type_string())): return start.string_value
	return 0

# The compile harness's main parses one file with the generated start rule:
# exit 0 accepts, 1 rejects (diagnostics printed), 2 cannot read the input.
char* sw_driver(char* parser_name):
	string_builder* text = string_from(c"\nimport lib.file\n\nint main(int argc, char** argv):\n\tif (argc != 2): return 2\n\tchar* source = file_read_text(argv[1])\n\tif (source == 0): return 2\n\tpg_diagnostics* diagnostics = pg_diagnostics_new()\n\tpg_ast_node* root = ")
	string_append(text, parser_name)
	string_append(text, c"_parse(source, argv[1], diagnostics)\n\tif ((root == 0) || (pg_diagnostics_count(diagnostics) != 0)):\n\t\tpg_diagnostics_print(diagnostics)\n\t\treturn 1\n\treturn 0\n")
	return text.data

# Runs every pinned example through the compiled driver. A wrong verdict,
# hang or crash is a measured failure of the generated parser; only an
# unrunnable driver or unreadable input is an infrastructure error.
json_value* sw_examples(json_value* runtime, char* corpus, char* binary, char* output, int timeout, char* repo):
	json_value* stage = vj_one(c"status", c"no_examples")
	json_value* rows = json_array()
	json_value* examples = jc_get(runtime, c"examples")
	int total = 0
	if (jc_type(examples, json_type_array())): total = examples.array_values.length
	vj_i(stage, c"total", total)
	vj_i(stage, c"passed", 0)
	json_object_set(stage, c"examples", rows)
	if (total == 0): return stage
	int limit = sw_example_timeout_ms
	if (timeout < limit): limit = timeout
	char* logs = path_join(output, c"examples")
	ht_mkdir(logs)
	int passed = 0
	int broken = 0
	for i in range(total):
		json_value* example = examples.array_values[i]
		char* expect = ht_text(example, c"expect")
		json_value* run = sw_run_stage(ht_argv(binary, path_join(corpus, ht_text(example, c"path"))), path_join(logs, strjoin(itoa(i), c".log")), limit, repo)
		char* status = ht_text(run, c"status")
		char* outcome = status
		if (strcmp(status, c"pass") == 0): outcome = c"accepted"
		elif (strcmp(status, c"fail") == 0 && ht_number(run, c"exit_code") == 1): outcome = c"rejected"
		elif (strcmp(status, c"fail") == 0): outcome = c"error"
		if (strcmp(outcome, c"error") == 0): broken = 1
		int ok = (strcmp(expect, c"accept") == 0 && strcmp(outcome, c"accepted") == 0) || (strcmp(expect, c"reject") == 0 && strcmp(outcome, c"rejected") == 0)
		passed = passed + ok
		json_value* row = vj_one(c"path", ht_text(example, c"path"))
		vj_s(row, c"expect", expect)
		vj_s(row, c"outcome", outcome)
		if (ok): vj_s(row, c"status", c"pass")
		else: vj_s(row, c"status", c"fail")
		json_value* code = jc_get(run, c"exit_code")
		if (code == 0): code = json_null()
		json_object_set(row, c"exit_code", code)
		json_object_set(row, c"seconds", ht_field(run, c"seconds"))
		vj_s(row, c"log", ht_text(run, c"log"))
		json_array_push(rows, row)
	vj_i(stage, c"passed", passed)
	if (broken): vj_s(stage, c"status", c"error")
	elif (passed == total): vj_s(stage, c"status", c"pass")
	else: vj_s(stage, c"status", c"fail")
	return stage

json_value* sw_case(json_value* entry, char* corpus, char* work, json_value* tools, int timeout, char* repo, json_value* configurations):
	char* name = ht_text(entry, c"name")
	char* directory = path_join(work, name)
	ht_require(mkdir(directory, 493) == 0, c"case artifact directory already exists")
	char* parser_name = strjoin(c"sweep_", replace(name, c"-", c"_"))
	json_value* result = vj_one(c"name", name)
	json_object_set(result, c"inputs", ht_field(entry, c"inputs"))
	vj_b(result, c"historical_288", jc_get(entry, c"historical_288") != 0 && ht_field(entry, c"historical_288").int_value)
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
		char* start = sw_runtime_entry(entry)
		if (start != 0):
			command.push(c"--start")
			command.push(start)
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
		string_append(text, sw_driver(parser_name))
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
		if (sw_pass(ht_field(stages, c"compile"))): json_object_set(stages, c"examples", sw_examples(jc_get(entry, c"runtime"), corpus, path_join(output, c"compile.bin"), output, timeout, repo))
	json_value* standard = ht_field(currents, c"default_permissive")
	json_value* stages = json_object()
	for char* stage in ht_command(c"translate generate compile"): json_object_set(stages, stage, ht_field(ht_field(standard, c"stages"), stage))
	json_object_set(stages, c"strict", ht_field(ht_field(ht_field(currents, c"default_strict"), c"stages"), c"translate"))
	json_object_set(result, c"stages", stages)
	json_object_set(result, c"dependency_inputs", ht_field(standard, c"dependency_inputs"))
	return result

json_value* sw_example_row(json_value* rows, char* path):
	if (!jc_type(rows, json_type_array())): return 0
	for json_value* row in rows.array_values:
		if (jc_is(jc_get(row, c"path"), path)): return row
	return 0

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
		json_value* examples = jc_get(entry, c"expected_examples")
		if (examples == 0): continue
		for char* configuration in examples.object_values.keys():
			json_value* rows = jc_get(jc_get(jc_get(jc_get(jc_get(actual[name], c"configurations"), configuration), c"stages"), c"examples"), c"examples")
			for json_value* path in ht_field(examples, configuration).array_values:
				char* outcome = c"not_run"
				json_value* row = sw_example_row(rows, path.string_value)
				if (row != 0 && jc_is(jc_get(row, c"status"), c"pass")): continue
				if (row != 0): outcome = ht_text(row, c"outcome")
				json_array_push(regressions, json_string(strjoin(strjoin(name, c": "), strjoin(strjoin(configuration, c"/examples "), strjoin(path.string_value, strjoin(c" regressed to ", outcome))))))
	return regressions

# Passing stages and examples the baseline does not expect. The gate fails
# on these too, so the committed baseline always states the measured
# coverage; --update-baseline records them after review.
json_value* sw_progressions(json_value* manifest, json_value* results):
	map[char*, json_value*] actual = new map[char*, json_value*]
	for json_value* row in results.array_values: actual[ht_text(row, c"name")] = row
	json_value* progressions = json_array()
	for json_value* entry in ht_field(manifest, c"cases").array_values:
		char* name = ht_text(entry, c"name")
		if (!(name in actual)): continue
		json_value* row = actual[name]
		for char* stage in sw_stages():
			if (sw_pass(jc_get(jc_get(row, c"stages"), stage)) && !sw_has(jc_get(entry, c"expected_pass"), stage)): json_array_push(progressions, json_string(strjoin(strjoin(name, c": "), strjoin(stage, c" progressed to pass"))))
		json_value* measured = jc_get(row, c"configurations")
		if (measured == 0): continue
		for char* configuration in measured.object_values.keys():
			json_value* stages = jc_get(ht_field(measured, configuration), c"stages")
			json_value* expected = jc_get(jc_get(entry, c"expected_configurations"), configuration)
			for char* stage in sw_build_stages():
				if (sw_pass(jc_get(stages, stage)) && !sw_has(expected, stage)): json_array_push(progressions, json_string(strjoin(strjoin(name, c": "), strjoin(strjoin(configuration, c"/"), strjoin(stage, c" progressed to pass")))))
			json_value* rows = jc_get(jc_get(stages, c"examples"), c"examples")
			if (!jc_type(rows, json_type_array())): continue
			json_value* listed = jc_get(jc_get(entry, c"expected_examples"), configuration)
			for json_value* example in rows.array_values:
				char* path = ht_text(example, c"path")
				if (jc_is(jc_get(example, c"status"), c"pass") && !sw_has(listed, path)): json_array_push(progressions, json_string(strjoin(strjoin(name, c": "), strjoin(strjoin(configuration, c"/examples "), strjoin(path, c" progressed to pass")))))
	return progressions

# Ordered union: every value of `order` that is in `old` or `extra`.
json_value* sw_union(list[char*] order, json_value* old, set[char*] extra):
	json_value* out = json_array()
	for char* value in order:
		if (sw_has(old, value) || value in extra): json_array_push(out, json_string(value))
	return out

# The baseline with every measured progression added. Expectations are only
# ever added: a regression stays in the baseline (and keeps failing the
# gate) until a reviewed `reclassified` entry removes it by hand.
json_value* sw_accept(json_value* manifest, json_value* results):
	map[char*, json_value*] actual = new map[char*, json_value*]
	for json_value* row in results.array_values: actual[ht_text(row, c"name")] = row
	json_value* updated = vj_copy(manifest)
	for json_value* entry in ht_field(updated, c"cases").array_values:
		char* name = ht_text(entry, c"name")
		if (!(name in actual)): continue
		json_value* row = actual[name]
		set[char*] passing = new set[char*]
		for char* stage in sw_stages():
			if (sw_pass(jc_get(jc_get(row, c"stages"), stage))): passing.add(stage)
		json_object_set(entry, c"expected_pass", sw_union(sw_stages(), jc_get(entry, c"expected_pass"), passing))
		json_value* measured = jc_get(row, c"configurations")
		if (measured == 0): continue
		json_value* configs = jc_get(entry, c"expected_configurations")
		if (configs == 0):
			configs = json_object()
			json_object_set(entry, c"expected_configurations", configs)
		list[char*] example_paths = new list[char*]
		json_value* pinned = jc_get(jc_get(entry, c"runtime"), c"examples")
		if (jc_type(pinned, json_type_array())):
			for json_value* example in pinned.array_values: example_paths.push(ht_text(example, c"path"))
		json_value* examples = jc_get(entry, c"expected_examples")
		if (examples == 0 && example_paths.length > 0):
			examples = json_object()
			json_object_set(entry, c"expected_examples", examples)
		for char* configuration in measured.object_values.keys():
			json_value* stages = jc_get(ht_field(measured, configuration), c"stages")
			passing = new set[char*]
			for char* stage in sw_build_stages():
				if (sw_pass(jc_get(stages, stage))): passing.add(stage)
			json_object_set(configs, configuration, sw_union(sw_build_stages(), jc_get(configs, configuration), passing))
			if (example_paths.length == 0): continue
			passing = new set[char*]
			json_value* rows = jc_get(jc_get(stages, c"examples"), c"examples")
			if (jc_type(rows, json_type_array())):
				for json_value* example in rows.array_values:
					if (jc_is(jc_get(example, c"status"), c"pass")): passing.add(ht_text(example, c"path"))
			json_object_set(examples, configuration, sw_union(example_paths, jc_get(examples, configuration), passing))
	return updated

# Python json.dumps(indent=2) layout, so a rewritten baseline diffs cleanly.
void sw_pretty_into(string_builder* out, json_value* value, int depth):
	if (jc_type(value, json_type_object()) && value.object_values.length > 0):
		string_append(out, c"{")
		int first = 1
		for char* key in value.object_values.keys():
			if (!first): string_append_char(out, ',')
			first = 0
			string_append_char(out, 10)
			string_append(out, ht_repeat(' ', 2 * depth + 2))
			json_append_escaped_string(out, key)
			string_append(out, c": ")
			sw_pretty_into(out, ht_field(value, key), depth + 1)
		string_append_char(out, 10)
		string_append(out, ht_repeat(' ', 2 * depth))
		string_append(out, c"}")
	elif (jc_type(value, json_type_array()) && value.array_values.length > 0):
		string_append(out, c"[")
		for i in range(value.array_values.length):
			if (i > 0): string_append_char(out, ',')
			string_append_char(out, 10)
			string_append(out, ht_repeat(' ', 2 * depth + 2))
			sw_pretty_into(out, value.array_values[i], depth + 1)
		string_append_char(out, 10)
		string_append(out, ht_repeat(' ', 2 * depth))
		string_append(out, c"]")
	else: string_append(out, json_stringify(value))
char* sw_pretty(json_value* value):
	string_builder* out = string_new()
	sw_pretty_into(out, value, 0)
	string_append_char(out, 10)
	return out.data

void sw_csv_row(string_builder* output, list[char*] values):
	for i in range(values.length):
		if (i > 0): string_append_char(output, ',')
		string_append_char(output, '"')
		string_append(output, replace(values[i], c"\"", c"\"\""))
		string_append_char(output, '"')
	string_append(output, c"\r\n")

json_value* sw_example_totals(json_value* results, char* configuration):
	int cases = 0
	int complete = 0
	int total = 0
	int passed = 0
	for json_value* row in results.array_values:
		json_value* examples = jc_get(jc_get(jc_get(jc_get(row, c"configurations"), configuration), c"stages"), c"examples")
		if (jc_get(examples, c"total") == 0 || ht_number(examples, c"total") == 0): continue
		cases = cases + 1
		complete = complete + sw_pass(examples)
		total = total + ht_number(examples, c"total")
		passed = passed + ht_number(examples, c"passed")
	json_value* out = json_object()
	vj_i(out, c"cases_run", cases)
	vj_i(out, c"cases_all_passed", complete)
	vj_i(out, c"examples_run", total)
	vj_i(out, c"examples_passed", passed)
	return out

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
	json_value* example_totals = json_object()
	json_value* finding_counts = json_object()
	for char* name in configurations:
		json_value* counts = json_object()
		for char* stage in sw_build_stages():
			int count = 0
			for json_value* row in results.array_values:
				if (sw_pass(jc_get(jc_get(jc_get(jc_get(row, c"configurations"), name), c"stages"), stage))): count = count + 1
			vj_i(counts, stage, count)
		json_object_set(config_totals, name, counts)
		json_object_set(example_totals, name, sw_example_totals(results, name))
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
	json_object_set(summary, c"examples", example_totals)
	json_object_set(summary, c"finding_grammar_counts", finding_counts)
	int historical = 0
	for json_value* row in results.array_values:
		if (ht_field(row, c"historical_288").int_value && sw_pass(ht_field(ht_field(row, c"stages"), c"compile"))): historical = historical + 1
	vj_i(summary, c"historical_288_compiled", historical)
	json_object_set(summary, c"regressions", regressions)
	json_object_set(summary, c"progressions", sw_progressions(manifest, results))
	json_object_set(summary, c"infrastructure_errors", errors)
	json_value* report = json_parse(c"{\"schema\":2}")
	json_object_set(report, c"provenance", provenance)
	json_object_set(report, c"summary", summary)
	json_object_set(report, c"cases", results)
	vj_write(path_join(work, c"results.json"), report)
	string_builder* csv = string_new()
	list[char*] header = ht_command(c"name inputs translate generate compile strict")
	for char* configuration in configurations:
		for char* stage in sw_build_stages(): header.push(strjoin(strjoin(configuration, c"/"), stage))
		header.push(strjoin(configuration, c"/examples_passed"))
	sw_csv_row(csv, header)
	for json_value* row in results.array_values:
		list[char*] inputs = new list[char*]
		for json_value* input in ht_field(row, c"inputs").array_values: inputs.push(ht_text(input, c"path"))
		list[char*] values = ht_argv(ht_text(row, c"name"), join(inputs, c";"))
		for char* stage in sw_stages(): values.push(ht_text(ht_field(ht_field(row, c"stages"), stage), c"status"))
		for char* configuration in configurations:
			for char* stage in sw_build_stages():
				json_value* status = jc_get(jc_get(jc_get(jc_get(jc_get(row, c"configurations"), configuration), c"stages"), stage), c"status")
				char* value = c"not_run"
				if (status != 0): value = status.string_value
				values.push(value)
			json_value* examples = jc_get(jc_get(jc_get(jc_get(row, c"configurations"), configuration), c"stages"), c"examples")
			if (jc_get(examples, c"total") != 0): values.push(strjoin(itoa(ht_number(examples, c"passed")), strjoin(c"/", itoa(ht_number(examples, c"total")))))
			else: values.push(c"")
		sw_csv_row(csv, values)
	if (csv_path == 0): csv_path = path_join(work, c"results.csv")
	ht_write(csv_path, csv.data, csv.length)
	return summary
