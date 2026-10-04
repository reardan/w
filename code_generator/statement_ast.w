# Statement emission consumes the resolved node, with no expression parsing.
void emit_statement_ast(statement_ast* node):
	if (node.kind == statement_ast_expression):
		emit_expression_ast(&node.expressions, node.root)
		return
	assert1(node.kind == statement_ast_return)
	int return_type = 0
	if (node.root >= 0):
		emit_expression_ast(&node.expressions, node.root)
		return_type = promote(node.expressions.result_type[node.root])
	finish_return_statement(node.root >= 0, return_type)
