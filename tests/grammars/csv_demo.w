# wbuild: target=grammars_csv_test tag=tests dep=grammars_parser_generator
# wbuild: step="bin/parser_generator_grammars libs/extras/grammars/csv.pg -o bin/generated_grammars_csv_parser.w"
# wbuild: step="bin/wv2 tests/grammars/csv_demo.w -o bin/grammars_csv_demo"
# wbuild: step="bin/grammars_csv_demo"
/*
Demo/test for the CSV grammar (translated from ANTLR4's CSV.g4 by tools/antlr_to_pg.w)
(libs/extras/grammars/csv.pg): sample inputs that must parse cleanly and
ones that must be rejected.
*/
import libs.extras.grammars.matchers
import libs.extras.grammars.csv_matchers
import bin.generated_grammars_csv_parser
import tests.grammars.grammar_demo


int main():
	grammar_demo_begin(csv_parse, c"demo.csv")
	expect_clean(c"a,b\n1,2\n")
	expect_clean(c"name,quote\nAda,\"hello\"\n")
	expect_clean(c"a,b,c\nx,,z\n")
	expect_clean(c"a,b\n\"a\"\"b\",c\n")
	expect_clean(c"a,b\r\n1,2\r\n")

	expect_errors(c"a,b\n")
	expect_errors(c"a,b\n1,2")
	expect_errors(c"a,b\nhe\"llo,2\n")

	return grammar_demo_finish()
