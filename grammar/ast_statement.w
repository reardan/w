# Start with return statements; unsupported statement forms keep their
# existing parser until they have complete owned nodes and lowering.
int ast_statement_return_try():
	if ((ast_expressions_mode < 2) || (peek(c"return") == 0)): return 0
	if (in_generator_body || in_gpu_for_body):
		ast_return_statements_fallback = ast_return_statements_fallback + 1
		return 0
	statement_ast node
	node.kind = statement_ast_return
	int saved_readonly = expression_lhs_readonly
	int saved_increment = increment_statement_context
	expression_lhs_readonly = 0
	increment_statement_context = 0
	int root = ast_expression_prepare_at(&node.expressions, token_start_offset, 3)
	if (root < 0):
		expression_lhs_readonly = saved_readonly
		increment_statement_context = saved_increment
		ast_return_statements_fallback = ast_return_statements_fallback + 1
		return 0
	node.root = node.expressions.left[root]
	if (node.root >= 0): expression_lhs_readonly = node.expressions.readonly
	else:
		expression_lhs_readonly = saved_readonly
		increment_statement_context = saved_increment
	# Parsing owns advancement past the expression's virtual end token.
	token_start_offset = node.expressions.final_token_offset
	get_token()
	emit_statement_ast(&node)
	ast_return_statements_emitted = ast_return_statements_emitted + 1
	if (node.root >= 0):
		ast_expressions_emitted = ast_expressions_emitted + 1
		ast_roots_emitted = ast_roots_emitted + 1
	return 1


# The final statement dispatch owns expression statements, after declarations
# and labels have had their turn. Match expression()'s cleared entry context
# and keep emission before the final lexer advance, including its diagnostics.
int ast_statement_expression_try():
	if (ast_expressions_mode < 2): return 0
	statement_ast node
	node.kind = statement_ast_expression
	int saved_readonly = expression_lhs_readonly
	int saved_increment = increment_statement_context
	expression_lhs_readonly = 0
	increment_statement_context = 0
	node.root = ast_expression_prepare_at(&node.expressions, token_start_offset, 2)
	if (node.root < 0):
		expression_lhs_readonly = saved_readonly
		increment_statement_context = saved_increment
		ast_expression_statements_fallback = ast_expression_statements_fallback + 1
		return 0
	emit_statement_ast(&node)
	expression_lhs_readonly = node.expressions.readonly
	token_start_offset = node.expressions.final_token_offset
	get_token()
	ast_expression_statements_emitted = ast_expression_statements_emitted + 1
	ast_expressions_emitted = ast_expressions_emitted + 1
	ast_roots_emitted = ast_roots_emitted + 1
	return 1


# if/elif and while retain their existing control regions and streaming
# bodies. Only the condition and false edge belong to this immediate node;
# release its arena before descending into the body or the next elif.
int ast_statement_condition_try(int kind, int false_target, int outer_condition):
	if (ast_expressions_mode < 2): return 0
	statement_ast node
	node.kind = kind
	node.false_target = false_target
	int saved_readonly = expression_lhs_readonly
	int saved_increment = increment_statement_context
	expression_lhs_readonly = 0
	increment_statement_context = 0
	node.root = ast_expression_prepare_at(&node.expressions, token_start_offset, 1)
	if (node.root < 0):
		expression_lhs_readonly = saved_readonly
		increment_statement_context = saved_increment
		if (kind == statement_ast_if_header): ast_if_headers_fallback = ast_if_headers_fallback + 1
		else: ast_while_headers_fallback = ast_while_headers_fallback + 1
		return 0
	emit_statement_ast(&node)
	expression_lhs_readonly = node.expressions.readonly
	token_start_offset = node.expressions.final_token_offset
	get_token()
	emit_statement_ast_condition_branch(&node, outer_condition)
	if (kind == statement_ast_if_header): ast_if_headers_emitted = ast_if_headers_emitted + 1
	else: ast_while_headers_emitted = ast_while_headers_emitted + 1
	ast_expressions_emitted = ast_expressions_emitted + 1
	ast_roots_emitted = ast_roots_emitted + 1
	return 1
