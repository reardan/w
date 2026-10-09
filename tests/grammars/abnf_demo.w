# wbuild: target=grammars_abnf_test tag=tests dep=grammars_parser_generator
# wbuild: step="bin/parser_generator_grammars libs/extras/grammars/abnf.pg -o bin/generated_grammars_abnf_parser.w"
# wbuild: step="bin/wv2 tests/grammars/abnf_demo.w -o bin/grammars_abnf_demo"
# wbuild: step="bin/grammars_abnf_demo"
/*
Demo/test for the ABNF grammar (translated from grammars-v4 Abnf.g4)
(libs/extras/grammars/abnf.pg): sample inputs that must parse cleanly and
ones that must be rejected. Sample shapes follow the small ABNF rules in grammars-v4/abnf/examples/.
*/
import libs.extras.grammars.matchers
import libs.extras.grammars.abnf_matchers
import bin.generated_grammars_abnf_parser
import tests.grammars.grammar_demo


int main():
	grammar_demo_begin(abnf_parse, c"demo.abnf")
	expect_clean(c"rule = \"a\"\n")
	expect_clean(c"name = ALPHA / DIGIT\n")
	expect_clean(c"list = *element\n")
	expect_clean(c"hex = %x41-5A\n")
	expect_clean(c"group = ( a / b )\n")
	expect_clean(c"; comment\nr = \"x\"\n")

	expect_errors(c"= missing-name\n")
	expect_errors(c"rule \"no-equals\"\n")

	return grammar_demo_finish()
