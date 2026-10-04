# Locate a complete quoted token without running the lexer. Quotes and
# escapes may contain operator characters; raw newlines still fall back.
# f-strings are deliberately excluded because their lexer has semantic
# chunk boundaries and can diagnose a stray brace while tokenizing.
int ast_expression_quoted_end(char* bytes, int start, int limit):
	if ((bytes[start] == '"') && (start > 0) && (bytes[start - 1] == 'f')): return -1
	int quote = bytes[start]
	int i = start + 1
	while (i < limit):
		if (bytes[i] == 10): return -1
		if (bytes[i] == quote): return i
		if (bytes[i] == 92):
			i = i + 1
			if ((i >= limit) || (bytes[i] == 10)): return -1
		i = i + 1
	return -1


# Return the byte after a closed block comment. Expressions currently
# require single-line comments; boundary lookahead may skip whole comment
# lines because it never tokenizes them speculatively. Decline the legacy
# lexer's special '/*/' shape instead of guessing its continuation.
int ast_expression_comment_end(char* bytes, int start, int limit, int multiline):
	int i = start + 2
	if ((i >= limit) || (bytes[i] == '/')): return -1
	while (i + 1 < limit):
		if ((bytes[i] == 10) && (multiline == 0)): return -1
		if ((bytes[i] == '*') && (bytes[i + 1] == '/')): return i + 2
		i = i + 1
	return -1


# Only probe closed, single-line groups with a small alphabet. In
# particular newlines and unterminated comments or quoted tokens cannot
# reach the speculative tokenizer, so it cannot diagnose or run past the
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
		if ((ch == '/') && (bytes[index + i + 1] == '*')):
			int after = ast_expression_comment_end(bytes, index + i, getchar_limit[file] - 1, 0)
			if ((after < 0) || (after - index >= 2048)): return -1
			i = after - index
			previous = 0
			continue
		if ((ch == 39) || (ch == '"')):
			int quoted = ast_expression_quoted_end(bytes, index + i, getchar_limit[file] - 1)
			if ((quoted < 0) || (quoted - index >= 2048)): return -1
			i = quoted - index + 1
			previous = 0
			continue
		int allowed = (ch >= '0') && (ch <= '9')
		if ((ch >= 'a') && (ch <= 'z')): allowed = 1
		if ((ch >= 'A') && (ch <= 'Z')): allowed = 1
		if ((ch == '_') || (ch == ' ') || (ch == 9)): allowed = 1
		if ((ch == '!') || (ch == '~') || (ch == '.') || (ch == ',')): allowed = 1
		if ((ch == '+') || (ch == '-') || (ch == '*') || (ch == '/') || (ch == '%')): allowed = 1
		if ((ch == '<') || (ch == '>') || (ch == '=') || (ch == '&') || (ch == '|')): allowed = 1
		if ((ch == '[') || (ch == ']') || (ch == '^') || (ch == '?') || (ch == ':')): allowed = 1
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


# A newline is not necessarily an expression boundary: postfix tails and
# infix operators on the next line still belong to the streaming expression.
# Until multi-line trees are supported, decline such roots before emission.
int ast_expression_line_boundary(char* bytes, int index, int limit):
	while (index < limit):
		int ch = bytes[index] & 255
		if ((ch == '/') && (index + 1 < limit) && (bytes[index + 1] == '*')):
			index = ast_expression_comment_end(bytes, index, limit, 1)
			if (index < 0): return 0
			continue
		if (ch == '#'):
			while ((index < limit) && (bytes[index] != 10)): index = index + 1
			continue
		if ((ch == ' ') || (ch == 9) || (ch == 10) || (ch == 13)):
			index = index + 1
			continue
		char* tails = c"([.+-*/%<>=&|^?"
		for j in range(15):
			if (tails[j] == ch): return 0
		if ((ch == 'i') && (index + 2 < limit) && (bytes[index + 1] == 'n')):
			if (is_ident_part_byte(bytes[index + 2]) == 0): return 0
		return 1
	return 0


# A complete scalar expression on one buffered line. The terminator is
# left for the enclosing grammar. Unsupported characters
# decline the whole root. No lexing or I/O happens in this preflight.
int ast_expression_root_end():
	if ((file < 0) || (file >= GETCHAR_MAX_FD)): return -1
	int window_start = getchar_kernel_pos[file] - getchar_limit[file]
	int index = token_start_offset - window_start
	if ((index < 0) || (index >= getchar_limit[file])): return -1
	char* bytes = cast(char*, getchar_buf_addr[file])
	int parens = 0
	int brackets = 0
	int ternaries = 0
	int previous = 0
	int i = 0
	while ((i < 2048) && (index + i + 1 < getchar_limit[file])):
		int ch = bytes[index + i] & 255
		if ((ch == '/') && (bytes[index + i + 1] == '*')):
			int after = ast_expression_comment_end(bytes, index + i, getchar_limit[file] - 1, 0)
			if ((after < 0) || (after - index >= 2048)): return -1
			i = after - index
			previous = 0
			continue
		if ((ch == 39) || (ch == '"')):
			int quoted = ast_expression_quoted_end(bytes, index + i, getchar_limit[file] - 1)
			if ((quoted < 0) || (quoted - index >= 2048)): return -1
			i = quoted - index + 1
			previous = 0
			continue
		if ((parens == 0) && (brackets == 0)):
			if ((ch == ')') || (ch == ']') || (ch == ',') || (ch == ';') || (ch == '}') || (ch == '#') || (ch == 10)):
				if (ternaries): return -1
				if ((ch == '#') || (ch == 10)):
					if (ast_expression_line_boundary(bytes, index + i, getchar_limit[file]) == 0): return -1
				return window_start + index + i
			if ((ch == ':') && (ternaries == 0)): return window_start + index + i
			if (ch == '?'): ternaries = ternaries + 1
			if (ch == ':'): ternaries = ternaries - 1
		if ((ch == 10) || (ch == '#')): return -1
		int allowed = (ch >= '0') && (ch <= '9')
		if ((ch >= 'a') && (ch <= 'z')): allowed = 1
		if ((ch >= 'A') && (ch <= 'Z')): allowed = 1
		if ((ch == '_') || (ch == ' ') || (ch == 9)): allowed = 1
		if ((ch == '!') || (ch == '~') || (ch == '.') || (ch == ',')): allowed = 1
		if ((ch == '+') || (ch == '-') || (ch == '*') || (ch == '/') || (ch == '%')): allowed = 1
		if ((ch == '<') || (ch == '>') || (ch == '=') || (ch == '&') || (ch == '|')): allowed = 1
		if ((ch == '^') || (ch == '?') || (ch == ':')): allowed = 1
		if (ch == '('):
			parens = parens + 1
			allowed = 1
		if (ch == ')'):
			parens = parens - 1
			allowed = 1
		if (ch == '['):
			brackets = brackets + 1
			allowed = 1
		if (ch == ']'):
			brackets = brackets - 1
			allowed = 1
		if (allowed == 0): return -1
		if ((previous == '/') && ((ch == '/') || (ch == '*'))): return -1
		previous = ch
		i = i + 1
	return -1


# Stop at a virtual end token before lexing the next statement. In
# particular, an indentation/EOF diagnostic must never escape a probe.
# The committed visitor runs before the one real get_token at the end.
void ast_expression_advance(expression_ast* tree):
	if (tree.whole_expression):
		int pos = byte_offset - 1
		int window_start = getchar_kernel_pos[file] - getchar_limit[file]
		char* bytes = cast(char*, getchar_buf_addr[file])
		while (pos < tree.end_offset):
			int ch = bytes[pos - window_start] & 255
			if ((ch == '/') && (bytes[pos - window_start + 1] == '*')):
				int after = ast_expression_comment_end(bytes, pos - window_start, getchar_limit[file], 0)
				if (after < 0): break
				pos = window_start + after
				continue
			if ((ch != ' ') && (ch != 9)): break
			pos = pos + 1
		if (pos >= tree.end_offset):
			# Keep the final token spelling: whitespace diagnostics in
			# the next real get_token refer to that preceding token.
			tree.final_token_offset = token_start_offset
			token_start_offset = tree.end_offset
			return
	get_token()


int ast_expression_accept(expression_ast* tree, char* spelling):
	if (tree.whole_expression && (token_start_offset >= tree.end_offset)): return 0
	if (peek(spelling) == 0): return 0
	ast_expression_advance(tree)
	return 1


int ast_expression_conditional(expression_ast* tree, int depth);
int ast_expression_assignment(expression_ast* tree, int depth);


# These predicates inspect existing types only. No inferred types, imports,
# symbol uses or diagnostics may be created until the candidate is accepted.
int ast_expression_scalar_type(int type):
	if (type_is_gpu_object(type) || type_is_gpu_pointer(type)): return 0
	int base = type_unqualified(type)
	if (type_get_pointer_level(base) > 0): return 1
	if (type_is_string(base)): return 1
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
	if ((type == 3) || (type == float32_value_type) || (type == float64_value_type) || (type == string_value_type) || (type == string_literal_type)): return 1
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
	if (type_is_gpu_object(type) || type_is_gpu_pointer(type)): return 0
	if (type_is_buffer(type)): return 1
	return ast_expression_scalar_type(type) || ast_expression_record_type(type)


# The type-only half of promote(), restricted to this arena's scalar
# types. Value-encoded call results differ from loaded float lvalues.
int ast_expression_promoted_type(int type):
	if (type == string_type): return string_value_type
	if (type_is_value(type)): return type_strip_gpu(type_real(type))
	int kind = type_float_kind(type)
	if (kind): return float_binary_result_type(kind)
	return type


int ast_expression_call(expression_ast* tree, int id, int depth):
	int sym = tree.symbol[id]
	int arity = sym_num_args(sym)
	if ((arity < 0) || (arity > 10)): return -1
	if ((sym_variadic_fixed_args(sym) >= 0) || (sym_w_variadic_fixed_args(sym) >= 0)): return -1
	if (sym_is_generator(sym) || sym_is_kernel(sym)): return -1
	int result = load_int(table + sym + 6)
	if ((result != 0) && (result != 4) && (ast_expression_scalar_type(result) == 0)): return -1
	if (ast_expression_accept(tree, c"(") == 0): return -1
	int count = 0
	int previous = -1
	while (peek(c")") == 0):
		if (count >= arity): return -1
		int param = sym_param_type(sym, count)
		if ((param >= 0) && (ast_expression_scalar_type(param) == 0)): return -1
		int arg = ast_expression_assignment(tree, depth + 1)
		if (arg < 0): return -1
		if (ast_expression_scalar_value(tree.result_type[arg]) == 0): return -1
		int got = ast_expression_promoted_type(tree.result_type[arg])
		if ((param >= 0) && type_is_string(param) && type_is_char_pointer(got)):
			if (sym_probe(c"str_from_cstr") < 0): return -1
		# Let the streaming parser issue argument diagnostics at its exact
		# source position, including warnings promoted by --strict.
		if ((param >= 0) && (types_compatible_with_expression(param, got) == 0)): return -1
		if (previous < 0): tree.left[id] = arg
		else: tree.next_arg[previous] = arg
		previous = arg
		count = count + 1
		if (ast_expression_accept(tree, c",") == 0): break
		if (peek(c")")): return -1
	if ((count != arity) || (peek(c")") == 0)): return -1
	if (token_start_offset >= tree.end_offset): return -1

	ast_expression_advance(tree)
	tree.op[id] = 'C'
	tree.result_type[id] = type_value(result)
	if (result == 4): tree.result_type[id] = 3
	return id


int ast_expression_print(expression_ast* tree, int depth):
	int newline = peek(c"println")
	int id = expression_ast_add(tree, 'P', -1, -1)
	if (id < 0): return -1
	tree.value[id] = newline
	tree.result_type[id] = type_value(0)
	ast_expression_advance(tree)
	if (ast_expression_accept(tree, c"(") == 0): return -1
	if (peek(c")")):
		if (newline == 0): return -1
	else:
		int arg = ast_expression_assignment(tree, depth + 1)
		if (arg < 0): return -1
		int vc = value_class(ast_expression_promoted_type(tree.result_type[arg]))
		int helper = -1
		if (vc == VC_INT): helper = 0
		if (vc == VC_CSTR): helper = 1
		if (vc == VC_STRING): helper = 2
		if (vc == VC_F32): helper = 3
		if (vc == VC_CHAR): helper = 13
		if (helper < 0): return -1
		tree.left[id] = arg
		tree.high[id] = helper
	if ((peek(c")") == 0) || (token_start_offset >= tree.end_offset)): return -1
	ast_expression_advance(tree)
	return id


int ast_expression_name(expression_ast* tree, int depth):
	# Keywords, unshadowable builtins, generics and constructors take
	# precedence over identifier() in the streaming grammar.
	if (peek(c"cast") || peek(c"sizeof") || peek(c"new")): return -1
	if ((nextc == '(') && (peek(c"print") || peek(c"println"))): return ast_expression_print(tree, depth)
	if (peek(c"to_json") || peek(c"from_json")): return -1
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
		ast_expression_advance(tree)
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
	# Keep a stable name offset across append-only lazy helper registration
	# during emission, with no allocation needing error cleanup.
	tree.value[id] = sym - strlen(token)
	ast_expression_advance(tree)
	if (is_call): return ast_expression_call(tree, id, depth)
	return id


int ast_expression_postfix(expression_ast* tree, int depth);


# Resolve already-existing simple cast types without creating records.
# Composite/generic/qualified type syntax remains a streaming fallback.
int ast_expression_cast_type(expression_ast* tree):
	int is_const = ast_expression_accept(tree, c"const")
	int type = generic_subst_lookup(token)
	if (type < 0): type = type_lookup(token)
	if (type < 0): return -1
	ast_expression_advance(tree)
	int base = type_unqualified(type)
	if ((word_size != 8) && ((base == float64_type) || (base == int64_type) || (base == uint64_type))): return -1
	if (is_const):
		type = type_lookup_const(type)
		if (type < 0): return -1
	while (ast_expression_accept(tree, c"*")):
		type = type_lookup_next_pointer(type)
		if (type < 0): return -1
	if (ast_expression_scalar_type(type) == 0): return -1
	return type


int ast_expression_unary(expression_ast* tree, int depth):
	if ((depth > 96) || (expr_nesting_depth + depth >= 1000)): return -1
	if (token_start_offset >= tree.end_offset): return -1
	if (ast_expression_accept(tree, c"cast")):
		if (ast_expression_accept(tree, c"(") == 0): return -1
		int want = ast_expression_cast_type(tree)
		if ((want < 0) || (ast_expression_accept(tree, c",") == 0)): return -1
		tree.cast_depth = tree.cast_depth + 1
		int child = ast_expression_assignment(tree, depth + 1)
		tree.cast_depth = tree.cast_depth - 1
		if ((child < 0) || (peek(c")") == 0)): return -1
		if (ast_expression_scalar_value(tree.result_type[child]) == 0): return -1
		int got = ast_expression_promoted_type(tree.result_type[child])
		# coerce_explicit diagnoses truncating an address. Leave that at
		# the streaming parser's source location and diagnostic order.
		if ((type_get_pointer_level(got) > 0) && (type_get_pointer_level(want) == 0)):
			if ((type_float_kind(want) == 0) && (type_get_size(want) < word_size)): return -1
		if (token_start_offset >= tree.end_offset): return -1
		ast_expression_advance(tree)
		int id = expression_ast_add(tree, 'K', child, -1)
		if (id < 0): return -1
		tree.value[id] = want
		tree.result_type[id] = type_value(want)
		return id
	if (peek(c"+") || peek(c"-") || peek(c"~") || peek(c"!") || peek(c"!!") || peek(c"&") || peek(c"*")):
		int op = 'p'
		if (peek(c"-")): op = 'n'
		if (peek(c"~")): op = '~'
		if (peek(c"!")): op = '!'
		if (peek(c"!!")): op = 'b'
		if (peek(c"&")): op = 'r'
		if (peek(c"*")): op = 'd'
		ast_expression_advance(tree)
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
	if (ast_expression_accept(tree, c"(")):
		int child = ast_expression_assignment(tree, depth + 1)
		if ((child < 0) || (peek(c")") == 0)): return -1
		if (token_start_offset >= tree.end_offset): return -1
		ast_expression_advance(tree)
		return child
	if (token[0] == 39):
		int id = expression_ast_add(tree, 'h', -1, -1)
		if (id >= 0): ast_expression_advance(tree)
		return id
	if ((token[0] == '"') || (((token[0] == 'c') || (token[0] == 's')) && (token[1] == '"'))):
		int op = 'S'
		int type = string_literal_type
		int start = 1
		if (token[1] == '"'):
			start = 2
			if (token[0] == 'c'):
				op = 's'
				type = type_lookup_pointer(c"char", 1)
				if (type < 0): return -1
				type = type_value(type)
			else: type = string_value_type
		int id = expression_ast_add(tree, op, -1, -1)
		if (id < 0): return -1
		tree.result_type[id] = type
		tree.value[id] = start
		ast_expression_advance(tree)
		return id
	if (is_ident_start_byte(token[0])): return ast_expression_name(tree, depth)
	if ((token[0] < '0') || (token[0] > '9')): return -1
	int op = 0
	if (token_is_float_literal()): op = 'f'
	int id = expression_ast_add(tree, op, -1, -1)
	if ((id >= 0) && (op == 'f')):
		tree.result_type[id] = float32_value_type
		if (word_size == 8): tree.result_type[id] = float64_value_type
	if (id >= 0): ast_expression_advance(tree)
	return id


int ast_expression_postfix(expression_ast* tree, int depth):
	int left = ast_expression_atom(tree, depth)
	while (left >= 0):
		int type = tree.result_type[left]
		if (ast_expression_accept(tree, c"[")):
			int op = 'i'
			int element
			if (type_is_buffer(type)):
				op = 'I'
				element = buffer_element_type(type)
			else:
				# Containers retain their pending-element machinery until
				# it has explicit AST nodes of its own.
				if (type_get_pointer_level(type) <= 0): return -1
				element = type_lookup_previous_pointer(type)
			if ((element < 0) || (ast_expression_storage_type(element) == 0)): return -1
			int index = ast_expression_assignment(tree, depth + 1)
			if ((index < 0) || (peek(c"]") == 0)): return -1
			if (ast_expression_scalar_value(tree.result_type[index]) == 0): return -1
			ast_expression_advance(tree)
			left = expression_ast_add(tree, op, left, index)
			if (left < 0): return -1
			tree.result_type[left] = element
			tree.value[left] = type_get_size(element)
		else if (ast_expression_accept(tree, c".")):
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
			ast_expression_advance(tree)
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
		ast_expression_advance(tree)
		int right = ast_expression_unary(tree, depth)
		if (right < 0): return -1
		left = ast_expression_binary(tree, op, left, right)
	return -1


int ast_expression_sum(expression_ast* tree, int depth):
	int left = ast_expression_product(tree, depth)
	while (left >= 0):
		if ((peek(c"+") || peek(c"-")) == 0): return left
		int op = token[0]
		ast_expression_advance(tree)
		int right = ast_expression_product(tree, depth)
		if (right < 0): return -1
		left = ast_expression_binary(tree, op, left, right)
	return -1


int ast_expression_shift(expression_ast* tree, int depth):
	int left = ast_expression_sum(tree, depth)
	while (left >= 0):
		int op = 0
		if (peek(c"<<")): op = 'L'
		if (peek(c">>")): op = 'R'
		if (op == 0): return left
		ast_expression_advance(tree)
		int right = ast_expression_sum(tree, depth)
		if (right < 0): return -1
		if ((ast_expression_scalar_value(tree.result_type[left]) && ast_expression_scalar_value(tree.result_type[right])) == 0): return -1
		left = expression_ast_add(tree, op, left, right)
	return -1


# Comparison nodes carry the existing integer setcc byte as their op;
# floats use the existing unordered/swap conventions in the emitter.
int ast_expression_compare(expression_ast* tree, int depth, int equality):
	int left
	if (equality): left = ast_expression_compare(tree, depth, 0)
	else: left = ast_expression_shift(tree, depth)
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
		ast_expression_advance(tree)
		int right
		if (equality): right = ast_expression_compare(tree, depth, 0)
		else: right = ast_expression_shift(tree, depth)
		if (right < 0): return -1
		if ((ast_expression_scalar_value(tree.result_type[left]) && ast_expression_scalar_value(tree.result_type[right])) == 0): return -1
		left = expression_ast_add(tree, op, left, right)
		if (left < 0): return -1
		tree.result_type[left] = type_value(bool_type)
	return -1


int ast_expression_bitwise(expression_ast* tree, int depth, int level):
	int left
	if (level): left = ast_expression_bitwise(tree, depth, level - 1)
	else: left = ast_expression_compare(tree, depth, 1)
	int op = '&'
	char* spelling = c"&"
	if (level == 1):
		op = '^'
		spelling = c"^"
	if (level == 2):
		op = '|'
		spelling = c"|"
	while ((left >= 0) && ast_expression_accept(tree, spelling)):
		int right
		if (level): right = ast_expression_bitwise(tree, depth, level - 1)
		else: right = ast_expression_compare(tree, depth, 1)
		if (right < 0): return -1
		int lt = tree.result_type[left]
		int rt = tree.result_type[right]
		if ((ast_expression_scalar_value(lt) && ast_expression_scalar_value(rt)) == 0): return -1
		# Preserve the streaming bool-bitwise hint's purity and chain
		# tracking until those diagnostics have their own AST records.
		if (condition_context && (op != '^') && operand_is_bool_condition(lt) && operand_is_bool_condition(rt)): return -1
		left = expression_ast_add(tree, op, left, right)
	return left


# A whole same-precedence chain is one node, matching the streaming
# grammar's single branch target and final booleanization. Grouped
# subchains remain separate nodes, even when their operator is the same.
int ast_expression_logic(expression_ast* tree, int depth, int is_or):
	int first
	if (is_or): first = ast_expression_logic(tree, depth, 0)
	else: first = ast_expression_bitwise(tree, depth, 2)
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
	while (ast_expression_accept(tree, spelling)):
		int child
		if (is_or): child = ast_expression_logic(tree, depth, 0)
		else: child = ast_expression_bitwise(tree, depth, 2)
		if (child < 0): return -1
		if (ast_expression_scalar_value(tree.result_type[child]) == 0): return -1
		tree.next_arg[previous] = child
		previous = child
	return id


int ast_expression_conditional(expression_ast* tree, int depth):
	if ((depth > 96) || (expr_nesting_depth + depth >= 1000)): return -1
	int condition = ast_expression_logic(tree, depth, 1)
	if ((condition < 0) || (peek(c"?") == 0)): return condition
	int ct = tree.result_type[condition]
	if (ast_expression_scalar_value(ct) == 0): return -1
	# A wresult pointer's '?' belongs to postfix error propagation.
	if (result_propagate_struct(type_real(ct)) >= 0): return -1
	ast_expression_advance(tree)
	int yes = ast_expression_assignment(tree, depth + 1)
	if ((yes < 0) || (ast_expression_accept(tree, c":") == 0)): return -1
	int no = ast_expression_conditional(tree, depth + 1)
	if (no < 0): return -1
	if ((ast_expression_scalar_value(tree.result_type[yes]) && ast_expression_scalar_value(tree.result_type[no])) == 0): return -1
	int yt = ast_expression_promoted_type(tree.result_type[yes])
	int nt = ast_expression_promoted_type(tree.result_type[no])
	int result = yt
	if (yt == 3): result = nt
	if (types_compatible(type_real(result), type_real(nt)) == 0): return -1
	int id = expression_ast_add(tree, '?', condition, yes)
	if (id < 0): return -1
	tree.high[id] = no
	if ((conditional_arm_is_value(result) || type_is_value(result)) == 0): result = type_value(type_real(result))
	tree.result_type[id] = result
	return id


# Scalar stores are AST nodes as well as values. Unsupported/lint-bearing
# assignments fall back before binding uses, emitting code or diagnostics.
int ast_expression_assignment(expression_ast* tree, int depth):
	if ((depth > 96) || (expr_nesting_depth + depth >= 1000)): return -1
	int left = ast_expression_conditional(tree, depth)
	if (left < 0): return -1
	int op = compound_assign_op()
	if ((op == 0) && (peek(c"=") == 0)): return left
	if (lint_mode): return -1
	int lt = tree.result_type[left]
	if (type_is_value(lt) || (lt == 3) || type_is_const(lt)): return -1
	if (ast_expression_scalar_type(lt) == 0): return -1
	if (op && type_is_buffer(type_canonical(lt))): return -1
	ast_expression_advance(tree)
	int right = ast_expression_assignment(tree, depth + 1)
	if (right < 0): return -1
	if (ast_expression_scalar_value(tree.result_type[right]) == 0): return -1
	int rt = ast_expression_promoted_type(tree.result_type[right])
	int result = rt
	if (op):
		int kind = binary_float_kind(ast_expression_promoted_type(lt), rt)
		if (kind && ((op != '+') && (op != '-') && (op != '*') && (op != '/'))): return -1
		result = 3
		if (kind): result = float_binary_result_type(kind)
	if (types_compatible_with_expression(lt, result) == 0): return -1
	int id = expression_ast_add(tree, '=', left, right)
	if (id < 0): return -1
	tree.value[id] = op
	tree.result_type[id] = type_value(lt)
	return id


# Called immediately after primary_expr consumes an opening '('. The
# speculative pass builds the tree without decoding literals or emitting
# code. Restore *all* changed state before either falling back or replaying
# the accepted tokens once for the existing literal diagnostics. The tokenizer
# snapshot is freed before any diagnostic can longjmp; the arena unwinds
# with the caller's stack on recovery. Return the expression's real type
# (possibly an lvalue or a negative value type), or -1 for fallback.
int ast_expression_try_at(int group_offset, int whole):
	if (ast_expressions_mode == 0): return -1
	if (target_isa == 3): return -1
	# Keep the streaming parser's pending lvalue/call/statement machinery
	# out of this first island. Expanding that boundary needs its own
	# semantic nodes and tests, rather than discarding parser state.
	if (hash_index_pending || nd_index_pending || expression_lhs_readonly): return -1
	if (increment_statement_context || generic_pending_call_signature || generic_pending_call_name): return -1
	int end
	if (whole): end = ast_expression_root_end()
	else: end = ast_expression_end(group_offset)
	if (end < 0): return -1
	if (whole > 1):
		int window_start = getchar_kernel_pos[file] - getchar_limit[file]
		char* bytes = cast(char*, getchar_buf_addr[file])
		if (bytes[end - window_start] == ','): return -1
	expression_ast tree
	tree.count = 0
	tree.text_used = 0
	tree.whole_expression = whole
	tree.end_offset = end
	tree.cast_depth = cast_context
	char* saved = generic_reparse_save()
	int serial = token_serial
	int root = ast_expression_assignment(&tree, 1)
	int accepted = (root >= 0) && (token_start_offset == end)
	if (whole == 0): accepted = accepted && peek(c")")
	if (accepted): accepted = ast_expression_scalar_value(tree.result_type[root]) || (tree.result_type[root] == type_value(0))
	getchar_seek(file, load_ptr(saved + 7 * __word_size__))
	generic_reparse_restore(saved)
	token_serial = serial
	if (accepted == 0): return -1
	while (token_start_offset < end):
		for id in range(tree.count):
			if ((tree.op[id] == 0) && (tree.offset[id] == token_start_offset)):
				int outer_cast = cast_context
				cast_context = tree.in_cast[id]
				tree.value[id] = int_literal_value(0)
				cast_context = outer_cast
			if ((tree.op[id] == 'h') && (tree.offset[id] == token_start_offset)):
				tree.value[id] = char_literal_value()
			if (((tree.op[id] == 's') || (tree.op[id] == 'S')) && (tree.offset[id] == token_start_offset)):
				int length = process_string_literal_from(tree.value[id])
				if (tree.op[id] == 'S'): validate_utf8_literal(length)
				token[length] = 0
				# The 2048-byte source bound leaves ample space for all
				# decoded bytes and one terminator per arena node.
				assert1(tree.text_used + length + 1 <= 4096)
				tree.value[id] = tree.text_used
				tree.high[id] = length
				for j in range(length + 1): tree.text[tree.text_used + j] = token[j]
				tree.text_used = tree.text_used + length + 1
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
		ast_expression_advance(&tree)
	emit_expression_ast(&tree, root)
	if (whole):
		token_start_offset = tree.final_token_offset
		get_token()
	ast_expressions_emitted = ast_expressions_emitted + 1
	return tree.result_type[root]


int ast_expression_try(int group_offset):
	return ast_expression_try_at(group_offset, 0)


int ast_expression_try_root(int statement_context):
	int result = ast_expression_try_at(token_start_offset, 1 + statement_context)
	if (result != -1):
		ast_roots_emitted = ast_roots_emitted + 1
		return result
	ast_roots_fallback = ast_roots_fallback + 1
	if (ast_audit_mode):
		diag_write_cstr(c"{\"ast_fallback\": true, ")
		diag_write_json_field(c"file", filename)
		diag_write_cstr(c", ")
		diag_write_json_int_field(c"line", diag_token_line)
		diag_write_cstr(c", ")
		diag_write_json_int_field(c"column", diag_token_column)
		diag_write_cstr(c", ")
		diag_write_json_field(c"token", token)
		diag_write_cstr(c"}\n")
		write(2, diag_out_buffer, diag_out_buffer_pos)
		diag_out_buffer_pos = 0
	if (ast_required_mode): error(c"AST-required compilation encountered an unsupported expression")
	return -1
