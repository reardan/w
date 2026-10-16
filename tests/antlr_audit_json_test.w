# wbuild: target=antlr_audit_json_test tag=tests dep=antlr_to_pg
# wbuild: step="bin/wv2 tests/antlr_audit_json_test.w -o bin/antlr_audit_json_test"
# wbuild: step="bin/antlr_audit_json_test"
# wbuild: step="python3 tests/antlr_audit_json_test.py"
import lib.testing
import libs.extras.grammars.antlr_to_pg.audit_json

void test_structured_finding_escapes_and_location():
	at_finding(c"AT_TEST", c"translate", c"test", c"unproven", c"quoted\"file.g4", 12, 7, c"root", c"reason\nline")
	json_value* finding = json_array_get(g_at_audit_findings, 0)
	assert_equal(12, json_object_get(finding, c"line").int_value)
	assert_strings_equal(c"AT_TEST", json_object_get(finding, c"code").string_value)
	char* encoded = json_stringify(finding)
	json_value* decoded = json_parse(encoded)
	assert1(decoded != 0)
	assert_strings_equal(c"reason\nline", json_object_get(decoded, c"reason").string_value)
	json_free(decoded)
	free(encoded)
