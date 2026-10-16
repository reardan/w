# wbuild: target=parser_generator_api_collision_test tag=tests dep=antlr_to_pg
# wbuild: step="bin/parser_generator_grammars tests/parser_generator/api_native.pg -o bin/api_native.w"
# wbuild: step="bin/parser_generator_grammars tests/parser_generator/api_prediction.pg -o bin/api_prediction.w"
# wbuild: step="bin/wv2 --strict tests/parser_generator/api_collision_test.w -o bin/parser_generator_api_collision_test"
# wbuild: step="bin/parser_generator_api_collision_test"
import lib.testing
import bin.api_native
import bin.api_prediction


void test_rule_and_public_entry_names_remain_distinct():
	pg_parse_result* result = api_native_parse_owned(c"abc", 3, c"input")
	assert_equal(1, result.success)
	assert_strings_equal(c"provider", result.root.name)
	pg_parse_result_free(result)
	result = api_prediction_parse_owned(c"abc", 3, c"input")
	assert_equal(1, result.success)
	assert_strings_equal(c"provider", result.root.name)
	pg_parse_result_free(result)
	result = api_native_parse_owned(c"ab", 2, c"input")
	assert_equal(0, result.success)
	pg_parse_result_free(result)
	result = api_prediction_parse_owned(c"ab", 2, c"input")
	assert_equal(0, result.success)
	pg_parse_result_free(result)
