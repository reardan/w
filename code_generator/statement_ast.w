# Statement emission consumes the resolved node, with no expression parsing.
void emit_statement_ast(statement_ast* node):
	if ((node.kind == statement_ast_expression) || (node.kind == statement_ast_if_header) || (node.kind == statement_ast_while_header)):
		emit_expression_ast(&node.expressions, node.root)
		return
	assert1(node.kind == statement_ast_return)
	int return_type = 0
	if (node.root >= 0):
		emit_expression_ast(&node.expressions, node.root)
		return_type = promote(node.expressions.result_type[node.root])
	finish_return_statement(node.root >= 0, return_type)


# The header parser has advanced past the expression before promotion, just
# as expression() does. Its branch target is owned by the surrounding region;
# bodies are still parsed and emitted by the ordinary statement machinery.
void emit_statement_ast_condition_branch(statement_ast* node, int outer_condition):
	finish_statement_condition(node.expressions.result_type[node.root], outer_condition, node.false_target)
