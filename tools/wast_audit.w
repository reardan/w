# wbuild: binary=wast_audit
/*
Usage:
  bin/wast_audit manifest bin/ast_suite_manifest.json
  bin/wast_audit required-manifest bin/ast_required_suite_manifest.json
  bin/wast_audit census bin/compiler_ast_audit.jsonl

manifest generates today's manifest from build.base.json and source directives,
adds --ast-full-expressions to direct production compile/check steps, writes
the manifest, and prints a JSON selection report. It never executes steps.
Run it with: bin/wexec -f bin/ast_suite_manifest.json -j 1 tests
Serial execution avoids nested default-manifest rebuild races. Driver-owned
compiler launches are not rewritten. Explicit AST modes and pinned seeds stay
intact. Compile flags also apply to each compilation's implicit imports.

required-manifest rejects expression fallback in positive compile/check steps
and diagnostic fixtures. Expected failures use permissive AST mode to preserve
diagnostics. Explicit modes, seeds and other nested drivers remain unchanged.

census prints deterministic file/token fallback counts and accumulated AST /
streaming counters from --ast-audit --stats stderr. It returns 1 for malformed
audit records, counter overflow, or inconsistent record/streaming-root totals.
Counts aggregate across invocations; absent or malformed streaming-root stats
leave consistency unknown. Consistency cannot establish log completeness or
compiler success: truncation after an earlier complete invocation is invisible.
Example input: bin/wv2 check --quiet --ast-audit --stats w.w 2>bin/audit.jsonl
Neither a hybrid-suite pass nor compiler-only required mode means complete
language coverage. Both commands emit JSON on stdout and diagnostics on stderr.
*/
import tools.ast_audit
import tools.wbuildgen_lib


int wast_audit_error(char* message):
	wstream* err = stderr_writer()
	stream_write_cstr(err, c"wast_audit: ")
	stream_write_line(err, message)
	stream_flush(err)
	return 1


int main(int argc, int argv):
	char** args = cast(char**, argv)
	if (argc == 2 && strcmp(args[1], c"--help") == 0):
		wstream* help = stdout_writer()
		stream_write_line(help, c"wast_audit manifest <output.json>  Generate an AST suite manifest; print selection JSON.")
		stream_write_line(help, c"wast_audit required-manifest <output.json>  Gate positive compiler steps and fixtures.")
		stream_write_line(help, c"wast_audit census <audit.jsonl>    Summarize --ast-audit --stats stderr as JSON.")
		stream_write_line(help, c"Direct compile/check steps include implicit imports. Nested compiler launches remain driver-controlled.")
		stream_write_line(help, c"Run manifests serially: bin/wexec -f <output.json> -j 1 tests")
		stream_flush(help)
		return 0
	if (argc != 3):
		return wast_audit_error(c"usage: wast_audit manifest|required-manifest <output.json> | census <audit.jsonl>; direct manifest steps only, nested compiler launches stay driver-controlled")
	json_value* report = 0
	int status = 0
	if (strcmp(args[1], c"manifest") == 0 || strcmp(args[1], c"required-manifest") == 0):
		char* generated = wbg_generate(c"build.base.json", 1)
		if (generated == 0): return 1
		json_value* root = json_parse(generated)
		free(generated)
		report = ast_audit_manifest_mode(root, strcmp(args[1], c"required-manifest") == 0)
		if (report == 0):
			json_free(root)
			return wast_audit_error(c"invalid generated manifest")
		char* output = json_stringify(root)
		string_builder* temporary = string_new()
		string_append(temporary, args[2])
		string_append(temporary, c".tmp.")
		string_append_int(temporary, getpid())
		int written = file_write_text(temporary.data, output)
		if (written):
			chmod(temporary.data, 420)
			written = rename(temporary.data, args[2]) == 0
		if (written == 0): unlink(temporary.data)
		string_free(temporary)
		free(output)
		json_free(root)
		if (written == 0):
			json_free(report)
			return wast_audit_error(c"cannot write manifest")
	else if (strcmp(args[1], c"census") == 0):
		char* input = file_read_text(args[2])
		if (input == 0): return wast_audit_error(c"cannot read audit log")
		report = ast_audit_census(input)
		free(input)
		if (jfield_int(report, c"invalid_records", 0) != 0): status = 1
		json_value* matching = json_object_get(report, c"records_match_streaming_roots")
		if (matching.type == json_type_bool() && matching.int_value == 0): status = 1
	else: return wast_audit_error(c"unknown command; use manifest, required-manifest or census")
	char* rendered = json_stringify(report)
	wstream* out = stdout_writer()
	stream_write_line(out, rendered)
	stream_flush(out)
	free(rendered)
	json_free(report)
	return status

# wbuild: target=ast_expression_suite dep=build dep=wast_audit dep=wfixture
# wbuild: step="bin/wast_audit required-manifest bin/ast_required_suite_manifest.json"
# wbuild: step="bin/wexec -f bin/ast_required_suite_manifest.json -j 1 tests"
