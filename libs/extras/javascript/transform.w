import libs.extras.javascript.parser
import libs.extras.javascript.printer
import libs.extras.javascript.strings
import libs.extras.javascript.edits


void js_module_edits(pg_ast_node* node, char* from, char* replacement, list[js_source_edit*] edits, pg_diagnostics* diagnostics):
	if (node == 0): return
	if (js_cst_is(node, c"import_statement") || js_cst_is(node, c"export_from") || js_cst_is(node, c"export_all")):
		pg_ast_node* literal = js_cst_child(node, c"STRING")
		if (literal != 0):
			char* decoded = js_string_decode(literal.text, diagnostics)
			if (decoded != 0):
				if (strcmp(decoded, from) == 0): edits.push(js_source_edit_new(literal.token.offset, literal.token.length, replacement, strlen(replacement)))
				free(decoded)
	for i in range(node.children.length): js_module_edits(node.children[i], from, replacement, edits, diagnostics)


# Rewrites only static import/re-export specifiers in a successfully parsed tree.
# Caller owns output; source/tree remain valid and unchanged. Reparse to obtain
# a tree with updated spans. An invalid input or edit returns 0 + diagnostics.
char* js_rewrite_module_specifiers(pg_parse_result* result, char* from, char* to, int* output_length):
	*output_length = 0
	if (result.success == 0): return 0
	string_builder* quoted = string_new()
	js_print_quoted(quoted, to)
	char* replacement = quoted.data
	free(quoted)
	list[js_source_edit*] edits = new list[js_source_edit*]
	js_module_edits(result.root, from, replacement, edits, result.diagnostics)
	free(replacement)
	char* output = 0
	if (pg_diagnostics_count(result.diagnostics) == 0): output = js_source_edits_apply(result.source, result.length, edits, result.diagnostics, output_length)
	for i in range(edits.length): js_source_edit_free(edits[i])
	__w_list_free(cast(__w_list*, edits))
	return output
