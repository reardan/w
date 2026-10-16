import lib.assert
import bin.prediction_labels_matchers
import bin.prediction_labels_parser


int labels_count(pg_ast_node* node, char* key):
	int count = pg_ast_get_metadata(node, key, 0) > 0
	for pg_ast_node* child in node.children: count = count + labels_count(child, key)
	return count


pg_ast_node* labels_find(pg_ast_node* node, char* key):
	if (pg_ast_get_metadata(node, key, 0) > 0): return node
	for pg_ast_node* child in node.children:
		pg_ast_node* found = labels_find(child, key)
		if (found != 0): return found
	return 0


int main():
	char* input = c"2^3^2+4!;5,6,7"
	pg_parse_result* result = labels_parse_owned(input, strlen(input), c"labels")
	if (result.success == 0): pg_diagnostics_print(result.diagnostics)
	assert1(result.success)
	assert_equal(2, labels_count(result.root, c"antlr_alt:Power"))
	assert_equal(1, labels_count(result.root, c"antlr_alt:Add"))
	assert_equal(1, labels_count(result.root, c"antlr_alt:Postfix"))
	assert_equal(4, labels_count(result.root, c"antlr_alt:Number"))
	assert_equal(4, labels_count(result.root, c"antlr_lhs_label:left="))
	assert_equal(3, labels_count(result.root, c"antlr_label:right="))
	assert_equal(3, labels_count(result.root, c"antlr_label:entries+="))
	assert_equal(1, labels_count(result.root, c"antlr_label:expression="))
	assert_equal(1, labels_count(result.root, c"antlr_label:collected="))
	pg_ast_node* power = labels_find(result.root, c"antlr_alt:Power")
	assert_equal(1, pg_ast_get_metadata(power, c"antlr_rule:e", 0))
	assert1(pg_ast_get_metadata(power, c"antlr_source_line", 0) > 0)
	assert1(pg_ast_get_metadata(power, c"antlr_source_column", 0) > 0)
	pg_ast_node* right = labels_find(power, c"antlr_label:right=")
	assert_strings_equal(c"3", right.first_token.text)
	assert_strings_equal(c"2", right.last_token.text)
	assert_equal(3, right.last_token.offset + right.last_token.length - right.first_token.offset)
	pg_parse_result_free(result)
	println(c"source alternatives, labeled operands and list labels survive normalization")
	return 0
