# wbuild: target=grammars_dot_test tag=tests dep=grammars_parser_generator
# wbuild: step="bin/parser_generator_grammars libs/extras/grammars/dot.pg -o bin/generated_grammars_dot_parser.w"
# wbuild: step="bin/wv2 tests/grammars/dot_demo.w -o bin/grammars_dot_demo"
# wbuild: step="bin/grammars_dot_demo"
/*
Demo/test for the DOT grammar (translated from grammars-v4 DOT.g4)
(libs/extras/grammars/dot.pg): sample inputs that must parse cleanly and
ones that must be rejected. IDs are lowercase-only in the source LETTER fragment, matching samples under
grammars-v4/dot/examples/ (simplified).
*/
import libs.extras.grammars.matchers
import libs.extras.grammars.dot_matchers
import bin.generated_grammars_dot_parser
import tests.grammars.grammar_demo


int main():
	grammar_demo_begin(dot_parse, c"demo.dot")
	expect_clean(c"digraph g { a -> b; }\n")
	expect_clean(c"graph g { a -- b; }\n")
	expect_clean(c"digraph g { a -> b -> c; }\n")
	expect_clean(c"digraph g { a [label=\"hi\"]; a -> b; }\n")
	expect_clean(c"digraph g { subgraph cluster_0 { a -> b; } }\n")

	expect_errors(c"digraph { -> ; }\n")
	expect_errors(c"notagraph g { }\n")

	return grammar_demo_finish()
