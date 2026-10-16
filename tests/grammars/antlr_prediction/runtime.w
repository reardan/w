import lib.assert
import bin.prediction_matchers
import bin.prediction_parser
import bin.native_prediction_matchers
import bin.native_prediction_parser


pg_ast_node* prediction_find(pg_ast_node* node, char* name):
	if (strcmp(node.name, name) == 0): return node
	for pg_ast_node* child in node.children:
		pg_ast_node* found = prediction_find(child, name)
		if (found != 0): return found
	return 0


void prediction_accept(char* input, char* rule, int alternative):
	pg_parse_result* result = prediction_parse_owned(input, strlen(input), c"input")
	if (result.success == 0): pg_diagnostics_print(result.diagnostics)
	assert1(result.success)
	pg_ast_node* node = prediction_find(result.root, rule)
	assert1(node != 0)
	assert_equal(alternative, pg_ast_get_metadata(node, c"pg_alternative", -1))
	char* source = pg_token_stream_source(result.stream)
	assert_strings_equal(input, source)
	free(source)
	pg_parse_result_free(result)


void prediction_reject(char* input):
	pg_parse_result* result = prediction_parse_owned(input, strlen(input), c"input")
	assert_equal(0, result.success)
	assert1(pg_diagnostics_count(result.diagnostics) > 0)
	assert_equal(0, result.stream.ast_allocation_count)
	pg_parse_result_free(result)


int main():
	# Explicit opt-in only: the existing native mode retains ordered choice.
	pg_parse_result* native = native_prediction_parse_owned(c"sab", 3, c"native")
	assert_equal(0, native.success)
	pg_parse_result_free(native)
	prediction_accept(c"sa", c"choice", 1)
	prediction_accept(c"sab", c"choice", 2)
	prediction_accept(c"fab", c"followed", 2)
	prediction_accept(c"fabb", c"followed", 1)
	prediction_accept(c"oa", c"optional", 1)
	prediction_accept(c"oaa", c"optional", 1)
	prediction_accept(c"raaaa", c"repeated", 1)
	prediction_accept(c"paa", c"positive", 1)
	prediction_accept(c"na", c"nullable", 1)
	prediction_accept(c"iab", c"indirect", 2)
	prediction_accept(c"ua", c"ambiguous", 1)
	prediction_accept(c"dxxaea", c"statement", 1)
	prediction_accept(c"dxaexa", c"statement", 2)
	prediction_accept(c"s a b\n", c"choice", 2)
	prediction_reject(c"s")
	prediction_reject(c"sabb")
	prediction_reject(c"fa")
	prediction_reject(c"o")
	prediction_reject(c"oaaa")
	prediction_reject(c"r")
	prediction_reject(c"pa")
	prediction_reject(c"n")
	prediction_reject(c"ib")
	prediction_reject(c"dxxae")
	prediction_reject(c"u")
	println(c"imported prediction handles caller context, greedy terms, ambiguity and dangling else")
	return 0
