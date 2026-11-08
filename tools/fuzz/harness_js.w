# wbuild: target=wfuzz_js_smoke tag=tests dep=wfuzz dep=javascript_parser data=tests/javascript/conformance/ data=tools/fuzz/dicts/js.dict
# wbuild: step="bin/wv2 --coverage tools/fuzz/harness_js.w -o bin/wfuzz_js_harness"
# wbuild: step="rm -rf bin/wfuzz_js_smoke"
# wbuild: step="bin/wfuzz --binary bin/wfuzz_js_harness --ext .js --dict tools/fuzz/dicts/js.dict --corpus tests/javascript/conformance --out bin/wfuzz_js_smoke --cases 0 --fail-on-findings" expect_stdout="crashes: 0" timeout=300000
# wbuild: target=wfuzz_js tag=fuzz_campaign dep=wfuzz dep=javascript_parser
# wbuild: step="bin/wv2 --coverage tools/fuzz/harness_js.w -o bin/wfuzz_js_harness"
# wbuild: step="bin/wfuzz --binary bin/wfuzz_js_harness --ext .js --dict tools/fuzz/dicts/js.dict --corpus tests/javascript/conformance --corpus tests/javascript/corpus --out bin/wfuzz_js" timeout=3600000
# Fuzz harness for the JavaScript front end (issue #842):
# libs/extras/javascript/parser.w (the generated parser plus the early
# error, binding and restriction validators) as a script and as a
# module, under its default resource limits. A program that parses and
# lowers (lower.w) must print (printer.w) to source that parses and
# lowers to an equal tree, as tests/javascript/roundtrip_test.w checks
# for its fixed examples.
import tools.fuzz.harness
import libs.extras.javascript.parser
import libs.extras.javascript.lower
import libs.extras.javascript.printer


int fh_js_round_trip(char* data, int length, int module):
	pg_parse_result* parsed = js_parse(data, length, c"case.js", module)
	if (parsed.success == 0):
		pg_parse_result_free(parsed)
		return 0
	js_node* tree = js_lower(parsed)
	if (tree == 0):
		pg_parse_result_free(parsed)
		return 1
	char* printed = js_print(tree, parsed.diagnostics)
	if (printed != 0):
		pg_parse_result* reparsed = js_parse(printed, strlen(printed), c"printed.js", module)
		if (reparsed.success == 0):
			println2(printed)
			pg_diagnostics_print(reparsed.diagnostics)
			fh_fail(c"printed program does not parse")
		js_node* other = js_lower(reparsed)
		fh_check(other != 0, c"printed program does not lower")
		fh_check(js_node_equal(tree, other), c"printed program lowers to a different tree")
		js_node_free(other)
		pg_parse_result_free(reparsed)
		free(printed)
	js_node_free(tree)
	pg_parse_result_free(parsed)
	return 1


int main(int argc, int argv):
	int length = 0
	char* data = fh_input(argc, argv, &length)
	int accepted = fh_js_round_trip(data, length, 0)
	if (fh_js_round_trip(data, length, 1)): accepted = 1
	if (accepted): return 0
	return 1
