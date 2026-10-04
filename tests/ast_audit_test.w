# wbuild: x64
import lib.testing
import tools.ast_audit


void test_ast_audit_selects_only_direct_compilations():
	json_value* root = json_parse(c"{\"dirs\":[\"bin\"],\"targets\":[{\"name\":\"sample\",\"steps\":[{\"cmd\":[\"bin/wv2\",\"x64\",\"program.w\",\"-o\",\"out\"],\"stdin\":\"keep\",\"env\":[\"K=V\"]},{\"cmd\":[\"bin/wv2\",\"check\",\"--json\",\"--lint\",\"program.w\"]},{\"cmd\":[\"./w\",\"w.w\",\"-o\",\"bin/wv2\"]},{\"cmd\":[\"bin/wv2\",\"--ast-required\",\"w.w\"]},{\"cmd\":[\"bin/wv2\",\"symbols\",\"--json\",\"w.w\"]},{\"cmd\":[\"sh\",\"-c\",\"bin/wv2 program.w\"]},{\"cmd\":[\"bin/wv2_fake\",\"w.w\"]},{\"cmd\":[\"bin/wv2\",\"-o\",\"output.w\"]},{\"cmd\":[\"bin/wv2_64\",\"--import-root\",\"directory.w\",\"--help\"]},{\"cmd\":[\"bin/wv3\",\"--strict\",\"w.w\",\"-o\",\"bin/wv4\"]}]}]}")
	json_value* report = ast_audit_manifest(root)
	assert1(report != 0)
	assert_equal(3, jfield_int(report, c"changed_steps", -1))
	assert_equal(1, jfield_int(report, c"explicit_ast_steps", -1))
	assert_equal(3, jfield_int(report, c"query_or_sourceless_steps", -1))
	assert_equal(3, jfield_int(report, c"other_steps", -1))
	json_value* target = json_array_get(jfield_array(root, c"targets"), 0)
	json_value* steps = jfield_array(target, c"steps")
	json_value* first = json_array_get(steps, 0)
	assert_strings_equal(c"keep", jfield_string(first, c"stdin"))
	json_value* cmd = jfield_array(first, c"cmd")
	assert_equal(6, json_array_length(cmd))
	assert_strings_equal(c"out", json_array_get(cmd, 4).string_value)
	assert_strings_equal(c"--ast-full-expressions", json_array_get(cmd, 5).string_value)
	first = json_array_get(steps, 1)
	cmd = jfield_array(first, c"cmd")
	assert_strings_equal(c"--json", json_array_get(cmd, 2).string_value)
	assert_strings_equal(c"--ast-full-expressions", json_array_get(cmd, 5).string_value)
	first = json_array_get(steps, 2)
	assert_equal(4, json_array_length(jfield_array(first, c"cmd")))
	json_value* repeated = ast_audit_manifest(root)
	assert_equal(0, jfield_int(repeated, c"changed_steps", -1))
	assert_equal(4, jfield_int(repeated, c"explicit_ast_steps", -1))
	json_free(repeated)
	json_free(report)
	json_free(root)


void test_ast_audit_census_is_sorted_and_preserves_missing_stats():
	char* input = c"compiling 'w.w'\n{\"ast_fallback\":true,\"file\":\"z.w\",\"line\":2,\"column\":1,\"token\":\"new\"}\n{\"ast_fallback\":true,\"file\":\"a.w\",\"line\":3,\"column\":4,\"token\":\"(\"}\n{\"ast_fallback\":true,\"file\":\"z.w\",\"line\":4,\"column\":5,\"token\":\"new\"}\nAST expression roots: 20\nStreaming expression roots: 3\nAST expression roots: 7\nStreaming return statements: 0"
	json_value* report = ast_audit_census(input)
	assert_equal(3, jfield_int(report, c"fallback_records", -1))
	assert_equal(0, jfield_int(report, c"invalid_records", -1))
	assert_equal(1, jfield_int(report, c"ignored_lines", -1))
	json_value* files = jfield_array(report, c"by_file")
	assert_equal(2, json_array_length(files))
	json_value* row = json_array_get(files, 0)
	assert_strings_equal(c"a.w", jfield_string(row, c"file"))
	assert_equal(1, jfield_int(row, c"count", -1))
	row = json_array_get(files, 1)
	assert_strings_equal(c"z.w", jfield_string(row, c"file"))
	assert_equal(2, jfield_int(row, c"count", -1))
	json_value* tokens = jfield_array(report, c"by_token")
	row = json_array_get(tokens, 0)
	assert_strings_equal(c"(", jfield_string(row, c"token"))
	row = json_array_get(tokens, 1)
	assert_equal(2, jfield_int(row, c"count", -1))
	json_value* counters = jfield_array(report, c"counters")
	row = json_array_get(counters, 0)
	assert_strings_equal(c"AST expression roots", jfield_string(row, c"counter"))
	assert_equal(27, jfield_int(row, c"count", -1))
	json_free(report)
	report = ast_audit_census(c"")
	assert_equal(0, json_array_length(jfield_array(report, c"counters")))
	assert_equal(0, jfield_int(report, c"fallback_records", -1))
	json_free(report)


void test_ast_audit_reports_malformed_records():
	json_value* report = ast_audit_census(c"{\"ast_fallback\": true\n{\"ast_fallback\":true,\"file\":\"a.w\",\"token\":\"x\"}\nAST expression roots: nope\n{\"unrelated\":true}\n{\"ast_fallback\":\"true\",\"file\":\"a.w\",\"line\":1,\"column\":1,\"token\":\"x\"}\n{\"ast_fallback\":null}\n")
	assert_equal(5, jfield_int(report, c"invalid_records", -1))
	assert_equal(1, jfield_int(report, c"ignored_lines", -1))
	assert_equal(0, jfield_int(report, c"fallback_records", -1))
	json_free(report)


void test_ast_audit_command_option_operands():
	json_value* cmd = json_parse(c"[\"bin/wv2\",\"-v\",\"program.w\"]")
	assert_equal(1, ast_audit_command_kind(cmd))
	json_free(cmd)
	cmd = json_parse(c"[\"bin/wv2\",\"--import-root=directory.w\",\"--ptx=trace.w\"]")
	assert_equal(3, ast_audit_command_kind(cmd))
	json_free(cmd)
	cmd = json_parse(c"[\"bin/wv2\",\"--import-root\",\"--ast-required\",\"program.w\",\"-o\",\"--ast-audit\"]")
	assert_equal(1, ast_audit_command_kind(cmd))
	json_free(cmd)
