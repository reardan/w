# Only probe closed, single-line groups with a small alphabet. In
# particular no comments, strings, newlines or UTF-8 can reach the
# speculative tokenizer, so it cannot issue diagnostics or run past the
# closing ')'. Inspect only bytes already in the tokenizer's buffered
# window: no I/O, seek, diagnostic or compiler-state changes. Crossing a
# buffer boundary falls back too (including on non-seekable inputs).
# The byte/node/depth limits are fallback boundaries, not language limits.
int ast_expression_end(int start):
	if ((file < 0) || (file >= GETCHAR_MAX_FD)): return -1
	int window_start = getchar_kernel_pos[file] - getchar_limit[file]
	int index = start - window_start
	if ((index < 0) || (index >= getchar_limit[file])): return -1
	char* bytes = cast(char*, getchar_buf_addr[file])
	int depth = 0
	int previous = 0
	int end = -1
	int i = 0
	while ((i < 2048) && (index + i + 1 < getchar_limit[file])):
		int ch = bytes[index + i] & 255
		int allowed = (ch >= '0') && (ch <= '9')
		if ((ch >= 'a') && (ch <= 'f')): allowed = 1
		if ((ch >= 'A') && (ch <= 'F')): allowed = 1
		if ((ch == 'x') || (ch == ' ') || (ch == 9)): allowed = 1
		if ((ch == '+') || (ch == '-') || (ch == '*') || (ch == '/') || (ch == '%')): allowed = 1
		if (ch == '('):
			allowed = 1
			depth = depth + 1
		if (ch == ')'):
			allowed = 1
			depth = depth - 1
			if (depth == 0):
				# The loop leaves one byte for lexing ')'s lookahead,
				# so even a missing-final-newline warning cannot fire.
				end = start + i
				break
		if (allowed == 0): break
		if ((previous == '/') && ((ch == '*') || (ch == '/'))): break
		previous = ch
		i = i + 1
	return end


int ast_expression_sum(expression_ast* tree, int depth);


int ast_expression_atom(expression_ast* tree, int depth):
	if ((depth > 96) || (expr_nesting_depth + depth >= 1000)): return -1
	if (token_start_offset >= tree.end_offset): return -1
	if (peek(c"+") || peek(c"-")):
		int op = 'p'
		if (peek(c"-")): op = 'n'
		get_token()
		int child = ast_expression_atom(tree, depth + 1)
		if (child < 0): return -1
		return expression_ast_add(tree, op, child, -1)
	if (accept(c"(")):
		int child = ast_expression_sum(tree, depth + 1)
		if ((child < 0) || (peek(c")") == 0)): return -1
		if (token_start_offset >= tree.end_offset): return -1
		get_token()
		return child
	if ((token[0] < '0') || (token[0] > '9') || token_is_float_literal()): return -1
	int id = expression_ast_add(tree, 0, -1, -1)
	if (id >= 0): get_token()
	return id


int ast_expression_product(expression_ast* tree, int depth):
	int left = ast_expression_atom(tree, depth)
	while (left >= 0):
		if ((peek(c"*") || peek(c"/") || peek(c"%")) == 0): return left
		int op = token[0]
		get_token()
		int right = ast_expression_atom(tree, depth)
		if (right < 0): return -1
		left = expression_ast_add(tree, op, left, right)
	return -1


int ast_expression_sum(expression_ast* tree, int depth):
	int left = ast_expression_product(tree, depth)
	while (left >= 0):
		if ((peek(c"+") || peek(c"-")) == 0): return left
		int op = token[0]
		get_token()
		int right = ast_expression_product(tree, depth)
		if (right < 0): return -1
		left = expression_ast_add(tree, op, left, right)
	return -1


# Called immediately after primary_expr consumes an opening '('. The
# speculative pass builds the tree without decoding literals or emitting
# code. Restore *all* changed state before either falling back or replaying
# the accepted tokens once for the existing literal diagnostics. The tokenizer
# snapshot is freed before any diagnostic can longjmp; the arena unwinds
# with the caller's stack on recovery.
int ast_expression_try(int group_offset):
	if (ast_expressions_mode == 0): return 0
	# Keep the streaming parser's pending lvalue/call/statement machinery
	# out of this first island. Expanding that boundary needs its own
	# semantic nodes and tests, rather than discarding parser state.
	if (hash_index_pending || nd_index_pending || expression_lhs_readonly): return 0
	if (increment_statement_context || generic_pending_call_signature || generic_pending_call_name): return 0
	int end = ast_expression_end(group_offset)
	if (end < 0): return 0
	expression_ast tree
	tree.count = 0
	tree.end_offset = end
	char* saved = generic_reparse_save()
	int serial = token_serial
	int root = ast_expression_sum(&tree, 1)
	int accepted = (root >= 0) && (token_start_offset == end) && peek(c")")
	getchar_seek(file, load_ptr(saved + 7 * __word_size__))
	generic_reparse_restore(saved)
	token_serial = serial
	if (accepted == 0): return 0
	while (token_start_offset < end):
		for id in range(tree.count):
			if ((tree.op[id] == 0) && (tree.offset[id] == token_start_offset)):
				tree.value[id] = int_literal_value(0)
		get_token()
	emit_expression_ast(&tree, root)
	ast_expressions_emitted = ast_expressions_emitted + 1
	return 1
