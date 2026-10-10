# wbuild: name=javascript_transform_test
# wbuild: target=javascript_transform_test tag=tests dep=javascript_parser
# wbuild: step="bin/wv2 tests/javascript/transform_test.w -o bin/javascript_transform_test"
# wbuild: step="bin/javascript_transform_test"
import lib.testing
import libs.extras.javascript.transform


void test_js_structural_module_rewrite():
	char* source = c"// './old.js' stays\nimport value from './old.js';\nexport {x} from './old.js';\nexport * from './old.js';\nconst text = './old.js';\nimport('./old.js');\n"
	char* expected = c"// './old.js' stays\nimport value from \"./new.js\";\nexport {x} from \"./new.js\";\nexport * from \"./new.js\";\nconst text = './old.js';\nimport('./old.js');\n"
	pg_parse_result* parsed = js_parse_module(source, c"before.js")
	assert_equal(1, parsed.success)
	int length = 0
	char* output = js_rewrite_module_specifiers(parsed, c"./old.js", c"./new.js", &length)
	assert_strings_equal(expected, output)
	assert_equal(strlen(expected), length)
	assert_strings_equal(source, parsed.source)
	pg_parse_result* rewritten = js_parse(output, length, c"after.js", 1)
	assert_equal(1, rewritten.success)
	pg_parse_result_free(rewritten)
	free(output)
	pg_parse_result_free(parsed)


void test_js_escaped_specifier_and_string_decoding():
	pg_parse_result* parsed = js_parse_module(c"import './\\u006fld.js';", c"escaped.js")
	assert_equal(1, parsed.success)
	int length = 0
	char* output = js_rewrite_module_specifiers(parsed, c"./old.js", c"./a\"b.js", &length)
	assert_strings_equal(c"import \"./a\\\"b.js\";", output)
	free(output)
	pg_parse_result_free(parsed)
	pg_diagnostics* diagnostics = pg_diagnostics_new()
	char* decoded = js_string_decode(c"'\\uD83D\\uDE00'", diagnostics)
	assert_strings_equal(c"\xf0\x9f\x98\x80", decoded)
	free(decoded)
	assert_equal(0, pg_diagnostics_count(diagnostics))
	assert1(js_string_decode(c"'\\0'", diagnostics) == 0)
	assert_equal(1, pg_diagnostics_count(diagnostics))
	pg_diagnostics_free(diagnostics)
