# wbuild: target=grammars_graphql_test tag=tests dep=grammars_parser_generator
# wbuild: step="bin/parser_generator_grammars libs/extras/grammars/graphql.pg -o bin/generated_grammars_graphql_parser.w"
# wbuild: step="bin/wv2 tests/grammars/graphql_demo.w -o bin/grammars_graphql_demo"
# wbuild: step="bin/grammars_graphql_demo"
/*
Demo/test for the GraphQL grammar (translated from grammars-v4 GraphQL.g4)
(libs/extras/grammars/graphql.pg): sample inputs that must parse cleanly and
ones that must be rejected.
*/
import libs.extras.grammars.matchers
import libs.extras.grammars.graphql_matchers
import bin.generated_grammars_graphql_parser
import tests.grammars.grammar_demo


int main():
	grammar_demo_begin(graphql_parse, c"demo.graphql")
	expect_clean(c"{ hero }\n")
	expect_clean(c"query { hero { name } }\n")
	expect_clean(c"{ hero(episode: 1) { name } }\n")
	expect_clean(c"mutation { create(name: \"Ada\") { id } }\n")
	expect_clean(c"{ hero { ... on Human { name } } }\n")
	expect_clean(c"type Human implements Character { name: String }\n")
	expect_clean(c"type Human implements Character & Named & Node { name: String }\n")
	expect_clean(c"interface Character implements & Named & Node { name: String }\n")
	expect_clean(c"extend type Human implements Character & Named\n")

	expect_errors(c"{ }\n")
	expect_errors(c"query\n")
	expect_errors(c"type Human implements { name: String }\n")
	expect_errors(c"type Human implements Character & { name: String }\n")
	expect_errors(c"type Human implements Character Named { name: String }\n")

	return grammar_demo_finish()
