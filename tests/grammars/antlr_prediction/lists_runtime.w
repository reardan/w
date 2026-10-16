import lib.assert
import bin.prediction_lists_matchers
import bin.prediction_lists_parser


int list_metadata_count(pg_ast_node* node, char* key):
	int count = pg_ast_get_metadata(node, key, 0) > 0
	for pg_ast_node* child in node.children: count = count + list_metadata_count(child, key)
	return count


void list_accept(char* input, int appends, int empties):
	pg_parse_result* result = lists_parse_owned(input, strlen(input), c"list")
	if (result.success == 0): pg_diagnostics_print(result.diagnostics)
	assert1(result.success)
	assert_equal(appends, list_metadata_count(result.root, c"antlr_alt:Append"))
	assert_equal(appends, list_metadata_count(result.root, c"antlr_label:statement="))
	assert_equal(appends, list_metadata_count(result.root, c"antlr_lhs_label:head="))
	assert_equal(empties, list_metadata_count(result.root, c"antlr_alt:Empty"))
	pg_parse_result_free(result)


int main():
	list_accept(c"", 0, 1)
	list_accept(c"begin end", 1, 2)
	list_accept(c"a begin a begin end a end a", 6, 3)
	pg_parse_result* result = lists_parse_owned(c"begin a", 7, c"bad")
	assert_equal(0, result.success)
	pg_parse_result_free(result)
	println(c"nullable lists preserve keyword-guarded bodies and source provenance")
	return 0
