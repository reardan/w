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
		if ((ch == '!') || (ch == '~') || (ch == '.') || (ch == ',')): allowed = 1
		if ((ch == '+') || (ch == '-') || (ch == '*') || (ch == '/') || (ch == '%')): allowed = 1
		if ((ch == '<') || (ch == '>') || (ch == '=') || (ch == '&') || (ch == '|')): allowed = 1
		if ((ch == '[') || (ch == ']')): allowed = 1
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


int ast_expression_logic(expression_ast* tree, int depth, int is_or);


# These predicates inspect existing types only. No inferred types, imports,
# symbol uses or diagnostics may be created until the candidate is accepted.
int ast_expression_scalar_type(int type):
	if (type_is_gpu_object(type) || type_is_gpu_pointer(type)): return 0
	int base = type_unqualified(type)
	if (type_get_pointer_level(base) > 0): return 1
	# Half loads/conversions can diagnose unsupported backends during
	# emission. Keep their diagnostic order with the streaming parser.
	if ((base == float16_type) && (target_isa != 0)): return 0
	if (type_num_args(base) > 0): return 0
	int kind = type_get_kind(base)
	if ((kind != 0) && (kind != type_kind_enum)): return 0
	int size = type_get_size(base)
	if (size > word_size): return 0
	return (size == 1) || (size == 2) || (size == 4) || (size == 8)


int ast_expression_scalar_value(int type):
	if ((type == 3) || (type == float32_value_type) || (type == float64_value_type)): return 1
	return ast_expression_scalar_type(type)


# Aggregates enter only as addresses on the way to a field or element.
# Whole-aggregate operators, arguments and roots still fall back.
int ast_expression_record_type(int type):
	if (type_is_value(type) || type_is_gpu_object(type)): return 0
	int base = type_unqualified(type)
	int kind = type_get_kind(base)
	if ((kind != 0) && (kind != type_kind_union)): return 0
	return type_num_args(base) > 0


int ast_expression_storage_type(int type):
	return ast_expression_scalar_type(type) || ast_expression_record_type(type)


# The type-only half of promote(), restricted to this arena's scalar
# types. Value-encoded call results differ from loaded float lvalues.
int ast_expression_promoted_type(int type):
	if (type_is_value(type)): return type_strip_gpu(type_real(type))
	int kind = type_float_kind(type)
	if (kind): return float_binary_result_type(kind)
	return type


int ast_expression_call(expression_ast* tree, int id, int depth):
	int sym = tree.symbol[id]
	int arity = sym_num_args(sym)
	if ((arity < 0) || (arity > 10)): return -1
	if ((sym_variadic_fixed_args(sym) >= 0) || (sym_w_variadic_fixed_args(sym) >= 0)): return -1
	if (sym_is_generator(sym) || sym_is_kernel(sym) || sym_is_asm_stub(sym)): return -1
	if (sym_got_vaddr(sym)): return -1
	int result = load_int(table + sym + 6)
	if (ast_expression_scalar_type(result) == 0): return -1
	if (accept(c"(") == 0): return -1
	int count = 0
	int previous = -1
	while (peek(c")") == 0):
		if (count >= arity): return -1
		int param = sym_param_type(sym, count)
		if (ast_expression_scalar_type(param) == 0): return -1
		int arg = ast_expression_logic(tree, depth + 1, 1)
		if (arg < 0): return -1
		if (ast_expression_scalar_value(tree.result_type[arg]) == 0): return -1
		int got = ast_expression_promoted_type(tree.result_type[arg])
		# Let the streaming parser issue argument diagnostics at its exact
		# source position, including warnings promoted by --strict.
		if (types_compatible_with_expression(param, got) == 0): return -1
		if (previous < 0): tree.left[id] = arg
		else: tree.next_arg[previous] = arg
		previous = arg
		count = count + 1
		if (accept(c",") == 0): break
		if (peek(c")")): return -1
	if ((count != arity) || (peek(c")") == 0)): return -1
	if (token_start_offset >= tree.end_offset): return -1
	get_token()
	tree.op[id] = 'C'
	tree.result_type[id] = type_value(result)
	return id


int ast_expression_name(expression_ast* tree, int depth):
	# Keywords, unshadowable builtins, generics and constructors take
	# precedence over identifier() in the streaming grammar.
	if (peek(c"cast") || peek(c"sizeof") || peek(c"new")): return -1
	if (peek(c"print") || peek(c"println") || peek(c"to_json") || peek(c"from_json")): return -1
	if ((nextc == '.') && (import_alias_lookup(token) >= 0)): return -1
	if (generic_call_ready()): return -1
	if ((nextc == '(') && struct_value_ctor_ready()): return -1
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
	int is_call = load_int(table + sym + 10) == 2
	int type = load_int(table + sym + 6)
	if ((is_call == 0) && (ast_expression_storage_type(type) == 0)): return -1
	int visibility = sym_decl_visibility(sym)
	if ((visibility != 'D') && (visibility != 'U') && (visibility != 'L') && (visibility != 'A')): return -1
	int id = expression_ast_add(tree, 'v', -1, -1)
	if (id < 0): return -1
	tree.symbol[id] = sym
	tree.result_type[id] = type
	# Scalar calls cannot declare symbols or lazily import runtime code.
	# Keep a stable name offset, with no allocation needing error cleanup.
	tree.value[id] = sym - strlen(token)
	get_token()
	if (is_call): return ast_expression_call(tree, id, depth)
	return id


int ast_expression_postfix(expression_ast* tree, int depth);


int ast_expression_unary(expression_ast* tree, int depth):
	if ((depth > 96) || (expr_nesting_depth + depth >= 1000)): return -1
	if (token_start_offset >= tree.end_offset): return -1
	if (peek(c"+") || peek(c"-") || peek(c"~") || peek(c"!") || peek(c"!!") || peek(c"&") || peek(c"*")):
		int op = 'p'
		if (peek(c"-")): op = 'n'
		if (peek(c"~")): op = '~'
		if (peek(c"!")): op = '!'
		if (peek(c"!!")): op = 'b'
		if (peek(c"&")): op = 'r'
		if (peek(c"*")): op = 'd'
		get_token()
		int child = ast_expression_unary(tree, depth + 1)
		if (child < 0): return -1
		int child_type = tree.result_type[child]
		if (op == 'r'):
			if (type_is_value(child_type) || (child_type == 3)): return -1
			return expression_ast_add(tree, op, child, -1)
		if (ast_expression_scalar_value(child_type) == 0): return -1
		if (op == 'd'):
			if (type_get_pointer_level(child_type) <= 0): return -1
			int element = type_lookup_previous_pointer(child_type)
			if ((element < 0) || (ast_expression_storage_type(element) == 0)): return -1
			int id = expression_ast_add(tree, op, child, -1)
			if (id >= 0): tree.result_type[id] = element
			return id
		int kind = type_float_kind(ast_expression_promoted_type(tree.result_type[child]))
		if ((op == '~') && kind): return -1
		int id = expression_ast_add(tree, op, child, -1)
		if (id < 0): return -1
		if ((op == '!') || (op == 'b')): tree.result_type[id] = type_value(bool_type)
		else if (kind): tree.result_type[id] = float_binary_result_type(kind)
		return id
	return ast_expression_postfix(tree, depth)


int ast_expression_atom(expression_ast* tree, int depth):
	if (accept(c"(")):
		int child = ast_expression_logic(tree, depth + 1, 1)
		if ((child < 0) || (peek(c")") == 0)): return -1
		if (token_start_offset >= tree.end_offset): return -1
		get_token()
		return child
	if (is_ident_start_byte(token[0])): return ast_expression_name(tree, depth)
	if ((token[0] < '0') || (token[0] > '9')): return -1
	int op = 0
	if (token_is_float_literal()): op = 'f'
	int id = expression_ast_add(tree, op, -1, -1)
	if ((id >= 0) && (op == 'f')):
		tree.result_type[id] = float32_value_type
		if (word_size == 8): tree.result_type[id] = float64_value_type
	if (id >= 0): get_token()
	return id


int ast_expression_postfix(expression_ast* tree, int depth):
	int left = ast_expression_atom(tree, depth)
	while (left >= 0):
		int type = tree.result_type[left]
		if (accept(c"[")):
			# Raw typed pointers only: buffers/containers have bounds and
			# pending-element machinery owned by the streaming parser.
			if (type_get_pointer_level(type) <= 0): return -1
			int element = type_lookup_previous_pointer(type)
			if ((element < 0) || (ast_expression_storage_type(element) == 0)): return -1
			int index = ast_expression_logic(tree, depth + 1, 1)
			if ((index < 0) || (peek(c"]") == 0)): return -1
			if (ast_expression_scalar_value(tree.result_type[index]) == 0): return -1
			get_token()
			left = expression_ast_add(tree, 'i', left, index)
			if (left < 0): return -1
			tree.result_type[left] = element
			tree.value[left] = type_get_size(element)
		else if (accept(c".")):
			int record = type
			int load_pointer = 0
			if (type_get_pointer_level(type) > 0):
				record = type_lookup_previous_pointer(type)
				load_pointer = type_is_value(type) == 0
			if ((record < 0) || (ast_expression_record_type(record) == 0)): return -1
			if (type_get_arg(record, token) < 0): return -1
			int field = type_get_field_type(record, token)
			if (ast_expression_storage_type(field) == 0): return -1
			int offset = type_get_field_offset(record, token)
			get_token()
			left = expression_ast_add(tree, '.', left, -1)
			if (left < 0): return -1
			tree.result_type[left] = field
			tree.value[left] = offset
			tree.high[left] = load_pointer
		else: return left
	return -1


int ast_expression_binary(expression_ast* tree, int op, int left, int right):
	if ((ast_expression_scalar_value(tree.result_type[left]) && ast_expression_scalar_value(tree.result_type[right])) == 0): return -1
	int lt = ast_expression_promoted_type(tree.result_type[left])
	int rt = ast_expression_promoted_type(tree.result_type[right])
	int kind = binary_float_kind(lt, rt)
	int lp = type_get_pointer_level(type_unqualified(lt))
	int rp = type_get_pointer_level(type_unqualified(rt))
	if (lp || rp):
		if (kind || ((op != '+') && (op != '-'))): return -1
	if ((op == '%') && kind): return -1
	int id = expression_ast_add(tree, op, left, right)
	if (id < 0): return -1
	if (kind): tree.result_type[id] = float_binary_result_type(kind)
	else if ((op == '+') || (op == '-')):
		tree.result_type[id] = additive_scalar_result_type(lt, rt, op)
	return id


int ast_expression_product(expression_ast* tree, int depth):
	int left = ast_expression_unary(tree, depth)
	while (left >= 0):
		if ((peek(c"*") || peek(c"/") || peek(c"%")) == 0): return left
		int op = token[0]
		get_token()
		int right = ast_expression_unary(tree, depth)
		if (right < 0): return -1
		left = ast_expression_binary(tree, op, left, right)
	return -1


int ast_expression_sum(expression_ast* tree, int depth):
	int left = ast_expression_product(tree, depth)
	while (left >= 0):
		if ((peek(c"+") || peek(c"-")) == 0): return left
		int op = token[0]
		get_token()
		int right = ast_expression_product(tree, depth)
		if (right < 0): return -1
		left = ast_expression_binary(tree, op, left, right)
	return -1


# Comparison nodes carry the existing integer setcc byte as their op;
# floats use the existing unordered/swap conventions in the emitter.
int ast_expression_compare(expression_ast* tree, int depth, int equality):
	int left
	if (equality): left = ast_expression_compare(tree, depth, 0)
	else: left = ast_expression_sum(tree, depth)
	while (left >= 0):
		int op = 0
		if (equality):
			if (peek(c"==")): op = 0x94
			if (peek(c"!=")): op = 0x95
		else:
			if (peek(c"<")): op = 0x9c
			if (peek(c"<=")): op = 0x9e
			if (peek(c">")): op = 0x9f
			if (peek(c">=")): op = 0x9d
		if (op == 0): return left
		get_token()
		int right
		if (equality): right = ast_expression_compare(tree, depth, 0)
		else: right = ast_expression_sum(tree, depth)
		if (right < 0): return -1
		if ((ast_expression_scalar_value(tree.result_type[left]) && ast_expression_scalar_value(tree.result_type[right])) == 0): return -1
		left = expression_ast_add(tree, op, left, right)
		if (left < 0): return -1
		tree.result_type[left] = type_value(bool_type)
	return -1


# A whole same-precedence chain is one node, matching the streaming
# grammar's single branch target and final booleanization. Grouped
# subchains remain separate nodes, even when their operator is the same.
int ast_expression_logic(expression_ast* tree, int depth, int is_or):
	int first
	if (is_or): first = ast_expression_logic(tree, depth, 0)
	else: first = ast_expression_compare(tree, depth, 1)
	if (first < 0): return -1
	char* spelling = c"&&"
	int op = 'a'
	if (is_or):
		spelling = c"||"
		op = 'o'
	if (peek(spelling) == 0): return first
	if (ast_expression_scalar_value(tree.result_type[first]) == 0): return -1
	int id = expression_ast_add(tree, op, first, -1)
	if (id < 0): return -1
	tree.result_type[id] = type_value(bool_type)
	int previous = first
	while (accept(spelling)):
		int child
		if (is_or): child = ast_expression_logic(tree, depth, 0)
		else: child = ast_expression_compare(tree, depth, 1)
		if (child < 0): return -1
		if (ast_expression_scalar_value(tree.result_type[child]) == 0): return -1
		tree.next_arg[previous] = child
		previous = child
	return id


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
	int root = ast_expression_logic(&tree, 1, 1)
	int accepted = (root >= 0) && (token_start_offset == end) && peek(c")")
	if (accepted): accepted = ast_expression_scalar_value(tree.result_type[root])
	getchar_seek(file, load_ptr(saved + 7 * __word_size__))
	generic_reparse_restore(saved)
	token_serial = serial
	if (accepted == 0): return -1
	while (token_start_offset < end):
		for id in range(tree.count):
			if ((tree.op[id] == 0) && (tree.offset[id] == token_start_offset)):
				tree.value[id] = int_literal_value(0)
			if ((tree.op[id] == 'f') && (tree.offset[id] == token_start_offset)):
				if (word_size == 8):
					float64_bits_from_token()
					tree.value[id] = float64_literal_lo
					tree.high[id] = float64_literal_hi
				else: tree.value[id] = float32_bits_from_token()
			if (((tree.op[id] == 'v') || (tree.op[id] == 'C')) && (tree.offset[id] == token_start_offset)):
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
