# wbuild: target=grammars_json_test tag=tests dep=grammars_parser_generator
# wbuild: step="bin/parser_generator_grammars libs/extras/grammars/json.pg -o bin/generated_grammars_json_parser.w"
# wbuild: step="bin/wv2 tests/grammars/json_demo.w -o bin/grammars_json_demo"
# wbuild: step="bin/grammars_json_demo"
/*
Demo/test for the JSON grammar (translated from ANTLR4's JSON.g4 by tools/antlr_to_pg.w)
(libs/extras/grammars/json.pg): sample inputs that must parse cleanly and
ones that must be rejected.
*/
import libs.extras.grammars.matchers
import libs.extras.grammars.json_matchers
import bin.generated_grammars_json_parser
import tests.grammars.grammar_demo


int main():
	grammar_demo_begin(json_parse, c"demo.json")
	expect_clean(c"null")
	expect_clean(c"true")
	expect_clean(c"false")
	expect_clean(c"42")
	expect_clean(c"1.5e10")
	expect_clean(c"\"hello world\"")
	expect_clean(c"[]")
	expect_clean(c"{}")
	expect_clean(c"[1, 2, 3]")
	expect_clean(c"{\"a\": 1, \"b\": [true, false, null]}")
	expect_clean(c"{\"nested\": {\"x\": [1, {\"y\": 2}], \"z\": \"str\"}}")

	expect_errors(c"")
	expect_errors(c"{a: 1}")
	expect_errors(c"[1, 2,]")
	expect_errors(c"{\"a\": }")
	# Known, documented gap: JSON.g4's NUMBER allows an optional leading '-',
	# which lexer.w's `number` matcher doesn't consume (see json.pg's
	# translation report / libs/extras/grammars/README.md) -- negative literals reject.
	expect_errors(c"-3.14")

	return grammar_demo_finish()
