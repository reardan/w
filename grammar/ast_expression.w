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
		if ((ch >= 'a') && (ch <= 'z')): allowed = 1
		if ((ch >= 'A') && (ch <= 'Z')): allowed = 1
		if ((ch == '_') || (ch == ' ') || (ch == 9)): allowed = 1
		if ((ch == '!') || (ch == '~')): allowed = 1
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


# Only scalar integer storage enters this stage. Preserve its original
# type (including aliases/const) on the node so the existing promote()
# selects the right signed/unsigned load, and a grouped name stays an
# lvalue. Wide storage on a narrower target, pointers, floats, aggregates,
# dynamic values and device-qualified objects stay with the streaming rule.
int ast_expression_integer_type(int type):
	if (type_is_gpu_object(type)): return 0
	int base = type_unqualified(type)
	if (type_get_pointer_level(base) > 0): return 0
	if (type_float_kind(base)): return 0
	if (type_num_args(base) > 0): return 0
	int kind = type_get_kind(base)
	if ((kind != 0) && (kind != type_kind_enum)): return 0
	int size = type_get_size(base)
	if (size > word_size): return 0
	return (size == 1) || (size == 2) || (size == 4) || (size == 8)


int ast_expression_name(expression_ast* tree):
	# These primary/unary keywords precede identifier() in the streaming
	# parser even if a user declared a symbol with the same spelling.
	if (peek(c"cast") || peek(c"sizeof") || peek(c"new")): return -1
	if (peek(c"true") || peek(c"false") || peek(c"__word_size__") || peek(c"__target_isa__")):
		int id = expression_ast_add(tree, 'c', -1, -1)
		if (id < 0): return -1
		if (peek(c"true") || peek(c"false")):
			tree.value[id] = peek(c"true")
			tree.result_type[id] = type_value(bool_type)
		else if (peek(c"__word_size__")): tree.value[id] = word_size
		else: tree.value[id] = target_isa
		get_token()
		return id
	int sym = sym_probe(token)
	if (sym < 0): return -1
	if (load_int(table + sym + 10) == 2): return -1
	int type = load_int(table + sym + 6)
	if (ast_expression_integer_type(type) == 0): return -1
	int visibility = sym_decl_visibility(sym)
	if ((visibility != 'D') && (visibility != 'U') && (visibility != 'L') && (visibility != 'A')): return -1
	int id = expression_ast_add(tree, 'v', -1, -1)
	if (id < 0): return -1
	tree.symbol[id] = sym
	tree.result_type[id] = type
	# The symbol table is stable for this short-lived tree: no declarations
	# or calls are parsed inside the island. Store a name offset, not a
	# borrowed token pointer or a separate allocation needing error cleanup.
	tree.value[id] = sym - strlen(token)
	get_token()
	return id


int ast_expression_atom(expression_ast* tree, int depth):
	if ((depth > 96) || (expr_nesting_depth + depth >= 1000)): return -1
	if (token_start_offset >= tree.end_offset): return -1
	if (peek(c"+") || peek(c"-") || peek(c"~") || peek(c"!") || peek(c"!!")):
		int op = 'p'
		if (peek(c"-")): op = 'n'
		if (peek(c"~")): op = '~'
		if (peek(c"!")): op = '!'
		if (peek(c"!!")): op = 'b'
		get_token()
		int child = ast_expression_atom(tree, depth + 1)
		if (child < 0): return -1
		int id = expression_ast_add(tree, op, child, -1)
		if ((id >= 0) && ((op == '!') || (op == 'b'))): tree.result_type[id] = type_value(bool_type)
		return id
	if (accept(c"(")):
		int child = ast_expression_sum(tree, depth + 1)
		if ((child < 0) || (peek(c")") == 0)): return -1
		if (token_start_offset >= tree.end_offset): return -1
		get_token()
		return child
	if (is_ident_start_byte(token[0])): return ast_expression_name(tree)
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
# with the caller's stack on recovery. Return the expression's real type
# (possibly an lvalue or a negative value type), or -1 for fallback.
int ast_expression_try(int group_offset):
	if (ast_expressions_mode == 0): return -1
	if (target_isa == 3): return -1
	# Keep the streaming parser's pending lvalue/call/statement machinery
	# out of this first island. Expanding that boundary needs its own
	# semantic nodes and tests, rather than discarding parser state.
	if (hash_index_pending || nd_index_pending || expression_lhs_readonly): return -1
	if (increment_statement_context || generic_pending_call_signature || generic_pending_call_name): return -1
	int end = ast_expression_end(group_offset)
	if (end < 0): return -1
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
	if (accepted == 0): return -1
	while (token_start_offset < end):
		for id in range(tree.count):
			if ((tree.op[id] == 0) && (tree.offset[id] == token_start_offset)):
				tree.value[id] = int_literal_value(0)
			if ((tree.op[id] == 'v') && (tree.offset[id] == token_start_offset)):
				import_warn_unqualified(token)
				import_warn_transitive(token)
				strcpy(last_identifier, token)
				# This is the committed use: update unused-local tracking
				# only now, at the same source token as identifier().
				sym_lookup(token)
		get_token()
	emit_expression_ast(&tree, root)
	ast_expressions_emitted = ast_expressions_emitted + 1
	return tree.result_type[root]
