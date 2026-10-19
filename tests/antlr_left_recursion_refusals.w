# wbuild: binary=antlr_left_recursion_refusals
# Current observed guards are separate from the pinned historical oracle.
import tools.javascript_conformance_lib
import libs.standard.cli.argparse

char* lr_root

char* lr_digest(char* path):
	string_builder* data = ht_read(path)
	return ht_digest(data.data, data.length)

json_value* lr_normalize(json_value* value):
	if (value.type == json_type_string()): return json_string(replace(value.string_value, strjoin(lr_root, c"/upstream/"), c""))
	if (value.type == json_type_array()):
		json_value* result = json_array()
		for json_value* item in value.array_values: json_array_push(result, lr_normalize(item))
		return result
	if (value.type == json_type_object()):
		json_value* result = json_object()
		for char* key in value.object_values.keys(): json_object_set(result, key, lr_normalize(ht_field(value, key)))
		return result
	return value

int main(int argc, int argv):
	arg_parser* parser = argparse_new(c"antlr_left_recursion_refusals")
	argparse_arg_default(argparse_add_option(parser, c"--tool", c"FILE", c"translator"), c"bin/antlr_to_pg")
	argparse_add_flag(parser, c"--refresh", c"explicitly replace current evidence and hash")
	arg_namespace* args = argparse_parse_or_exit(parser, argc, argv)
	lr_root = ht_resolve(c"tests/grammars/antlr_left_recursion")
	char* manifest_path = path_join(lr_root, c"manifest.json")
	json_value* manifest = ht_json(manifest_path)
	ht_require(ht_number(manifest, c"schema") == 1, c"unsupported manifest schema")
	json_value* cases = ht_field(manifest, c"cases")
	set[char*] pairs = new set[char*]
	for json_value* entry in cases.array_values:
		for json_value* rule in ht_field(entry, c"rules").array_values: pairs.add(strjoin(strjoin(ht_text(entry, c"name"), c"/"), ht_text(rule, c"name")))
	ht_require(cases.array_values.length == 21 && pairs.length == 25, c"inventory must retain 21 grammars and 25 distinct rules")
	for json_value* entry in ht_field(manifest, c"files").array_values:
		char* path = ht_resolve(path_join(lr_root, ht_text(entry, c"path")))
		ht_require(path != 0 && starts_with(path, strjoin(lr_root, c"/")) && strcmp(lr_digest(path), ht_text(entry, c"sha256")) == 0, c"fixture hash/path mismatch")
	json_value* graph = ht_json(path_join(lr_root, c"original_graph.json"))
	ht_require(strcmp(ht_text(graph, c"corpus_commit"), ht_text(ht_field(manifest, c"corpus"), c"commit")) == 0, c"original graph corpus mismatch")
	json_value* evidence = ht_field(graph, c"cases")
	ht_require(evidence.array_values.length == cases.array_values.length, c"original graph inventory changed")
	for i in range(cases.array_values.length):
		json_value* entry = cases.array_values[i]
		for json_value* input in ht_field(entry, c"inputs").array_values: ht_require(strcmp(lr_digest(path_join(path_join(lr_root, c"upstream"), ht_text(input, c"path"))), ht_text(input, c"sha256")) == 0, c"original upstream hash mismatch")
		json_value* observed = evidence.array_values[i]
		json_value* analysis = ht_field(observed, c"analysis")
		ht_require(strcmp(ht_text(entry, c"name"), ht_text(observed, c"name")) == 0 && jc_equal(ht_field(entry, c"inputs"), ht_field(observed, c"inputs")) && ht_field(analysis, c"complete").int_value && !ht_field(analysis, c"exhausted").int_value, c"original graph evidence incomplete")
		for json_value* rule in ht_field(analysis, c"rules").array_values: ht_require(!ht_field(rule, c"mutual_cycle").int_value, c"original graph contradicts no-mutual-SCC observation")
	char* tool = ht_resolve(argparse_get(args, c"tool"))
	char* before = lr_digest(tool)
	char* work = ht_temp()
	json_value* rows = json_array()
	for json_value* entry in cases.array_values:
		char* output = path_join(work, c"grammar.pg")
		char* audit = path_join(work, c"audit.json")
		ht_write(output, c"unchanged sentinel\n", 19)
		unlink(audit)
		list[char*] command = ht_argv(tool)
		for json_value* input in ht_field(entry, c"inputs").array_values: command.push(path_join(path_join(lr_root, c"upstream"), ht_text(input, c"path")))
		for char* arg in ht_argv(c"--exact-lexer", c"--prediction", c"-o", output, c"--audit-json", audit): command.push(arg)
		process_result* result = ht_run(command, 0, 0, 90000)
		ht_require(result.status == 1, c"expected atomic translation refusal")
		ht_equal_file(output, c"unchanged sentinel\n")
		json_value* report = lr_normalize(ht_json(audit))
		json_value* findings = ht_field(report, c"findings")
		set[char*] expected = new set[char*]
		set[char*] actual = new set[char*]
		for json_value* rule in ht_field(entry, c"rules").array_values: expected.add(ht_text(rule, c"name"))
		for json_value* finding in findings.array_values:
			if (strcmp(ht_text(finding, c"code"), c"AT_LEFT_RECURSION") != 0): continue
			actual.add(ht_text(finding, c"rule"))
			json_value* details = ht_field(finding, c"details")
			ht_require(ht_field(details, c"normalization_guards").array_values.length > 0 && ht_field(ht_field(ht_field(details, c"source"), c"plan"), c"complete").int_value, c"missing observed guards or complete source plan")
		ht_require(actual.length == expected.length, c"original rule inventory changed")
		for char* rule in actual: ht_require(rule in expected, c"unexpected recursion rule")
		json_value* row = json_parse(c"{\"exit_code\":1,\"output_preserved\":true}")
		json_object_set(row, c"name", ht_field(entry, c"name"))
		json_object_set(row, c"findings", findings)
		json_array_push(rows, row)
	ht_require(strcmp(lr_digest(tool), before) == 0, c"translator changed during measurement")
	char* report_path = path_join(lr_root, c"current_refusals.json")
	if (argparse_get_bool(args, c"refresh")):
		char* tool_root = path_dirname(path_dirname(tool))
		json_value* provenance = json_parse(c"{\"configuration\":[\"--exact-lexer\",\"--prediction\"],\"interpretation\":\"Current instrumented guard exits, separate from historical generic findings. No acceptance promotion.\"}")
		json_object_set(provenance, c"translator_sha256", json_string(before))
		json_object_set(provenance, c"source_base", json_string(strip(ht_checked(ht_argv(c"git", c"-C", tool_root, c"rev-parse", c"HEAD")).stdout_text)))
		json_object_set(provenance, c"source_dirty", json_bool(ht_checked(ht_argv(c"git", c"-C", tool_root, c"status", c"--porcelain")).stdout_length != 0))
		json_value* report = json_parse(c"{\"schema\":1}")
		json_object_set(report, c"provenance", provenance)
		json_object_set(report, c"cases", rows)
		char* text = strjoin(json_stringify(report), c"\n")
		ht_write(report_path, text, strlen(text))
		map[char*, json_value*] files = new map[char*, json_value*]
		for json_value* entry in ht_field(manifest, c"files").array_values: files[ht_text(entry, c"path")] = entry
		json_value* record = json_parse(c"{\"path\":\"current_refusals.json\"}")
		json_object_set(record, c"sha256", json_string(lr_digest(report_path)))
		files[c"current_refusals.json"] = record
		list[char*] names = files.keys()
		ht_sort(names)
		json_value* ordered = json_array()
		for char* name in names: json_array_push(ordered, files[name])
		json_object_set(manifest, c"files", ordered)
		text = strjoin(json_stringify(manifest), c"\n")
		ht_write(manifest_path, text, strlen(text))
	else: ht_require(jc_equal(rows, ht_field(ht_json(report_path), c"cases")), c"current refusal evidence differs from pinned Wave 0 findings")
	ht_cleanup()
	println(c"Observed normalization guards: 21 roots / 25 rules; every refusal preserved output")
	return 0
