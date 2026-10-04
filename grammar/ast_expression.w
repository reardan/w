int ast_expression_quoted_end_nested(char* bytes, int start, int limit, int depth);


# Preflight all literal chunks and embedded expressions before entering
# the template tokenizer, whose malformed-brace errors must not escape a
# speculative parse. Formatting specs are left to the streaming path.
int ast_expression_template_end(char* bytes, int start, int limit, int depth):
	if (depth > 96): return -1
	int i = start + 1
	int braces = 0
	while (i < limit):
		int ch = bytes[i] & 255
		if (ch == 10): return -1
		if (braces):
			if ((ch == 34) || (ch == 39)):
				int end = ast_expression_quoted_end_nested(bytes, i, limit, depth + 1)
				if (end < 0): return end
				i = end + 1
				continue
			if ((ch == '#') || (ch == ':')): return -1
			if ((ch == '/') && (i + 1 < limit) && (bytes[i + 1] == '*')): return -1
			if (ch == '{'): braces = braces + 1
			if (ch == '}'): braces = braces - 1
		else:
			if (ch == 34): return i
			if (ch == 92):
				i = i + 1
				if (i >= limit): return -2
				if (bytes[i] == 10): return -1
			else if ((ch == '{') || (ch == '}')):
				if (i + 1 >= limit): return -2
				if (bytes[i + 1] == ch): i = i + 1
				else if (ch == '{'): braces = 1
				else: return -1
		i = i + 1
	return -2


# Return a closing quote without decoding escapes or changing lexer state.
int ast_expression_quoted_end_nested(char* bytes, int start, int limit, int depth):
	if (depth > 96): return -1
	if ((bytes[start] == 34) && (start > 0) && (bytes[start - 1] == 'f')):
		return ast_expression_template_end(bytes, start, limit, depth + 1)
	int quote = bytes[start]
	int i = start + 1
	while (i < limit):
		if (bytes[i] == 10): return -1
		if (bytes[i] == quote): return i
		if (bytes[i] == 92):
			i = i + 1
			if (i >= limit): return -2
			if (bytes[i] == 10): return -1
		i = i + 1
	return -2


int ast_expression_quoted_end(char* bytes, int start, int limit):
	return ast_expression_quoted_end_nested(bytes, start, limit, 0)


# Return the byte after a closed block comment. Expression preflight and
# boundary lookahead may skip multiline comments without tokenizing them.
# Decline the legacy lexer's special '/*/' shape instead of guessing its
# continuation.
int ast_expression_comment_end(char* bytes, int start, int limit, int multiline):
	int i = start + 2
	if (i >= limit): return -2
	if (bytes[i] == '/'): return -1
	while (i + 1 < limit):
		if ((bytes[i] == 10) && (multiline == 0)): return -1
		if ((bytes[i] == '*') && (bytes[i + 1] == '/')): return i + 2
		i = i + 1
	return -2


# Only probe closed groups with a small alphabet. In particular space
# indentation and unterminated comments or quoted tokens cannot reach
# the speculative tokenizer, so it cannot diagnose or run past the
# closing ')'. A -2 result requests more buffered bytes; -1 declines
# unsupported syntax. No tokenizer or diagnostic state changes here.
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
		if (ch == '#'):
			while ((index + i < getchar_limit[file]) && (bytes[index + i] != 10)): i = i + 1
			previous = 0
			continue
		if (ch == 10):
			if (bytes[index + i + 1] == ' '): return -1
			previous = 0
			i = i + 1
			continue
		if ((ch == '/') && (bytes[index + i + 1] == '*')):
			int after = ast_expression_comment_end(bytes, index + i, getchar_limit[file] - 1, 1)
			if (after < 0): return after
			if (after - index >= 2048): return -1
			i = after - index
			previous = 0
			continue
		if ((ch == 39) || (ch == '"')):
			int quoted = ast_expression_quoted_end(bytes, index + i, getchar_limit[file] - 1)
			if (quoted < 0): return quoted
			if (quoted - index >= 2048): return -1
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
		if ((ch == '[') || (ch == ']') || (ch == '^') || (ch == '?') || (ch == ':') || (ch == '{') || (ch == '}')): allowed = 1
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
	if ((end < 0) && (i < 2048) && (index + i + 1 >= getchar_limit[file])): return -2
	return end


# A newline is not necessarily an expression boundary: postfix tails and
# infix operators on the next line still belong to the streaming expression.
# A bare '*' or prefix increment starts a fresh statement, matching the
# streaming grammar's token_newline guards. Other tails continue the root.
int ast_expression_line_boundary(char* bytes, int index, int limit, int eof):
	while (index < limit):
		int ch = bytes[index] & 255
		if ((ch == '/') && (index + 1 < limit) && (bytes[index + 1] == '*')):
			index = ast_expression_comment_end(bytes, index, limit, 1)
			if ((index == -2) && (eof == 0)): return -2
			if (index < 0): return 0
			continue
		if (ch == '#'):
			while ((index < limit) && (bytes[index] != 10)): index = index + 1
			continue
		if ((ch == ' ') || (ch == 9) || (ch == 10) || (ch == 13)):
			index = index + 1
			continue
		if ((ch == '*') || (ch == '+') || (ch == '-')):
			if (index + 1 >= limit):
				if (eof == 0): return -2
				if (ch == '*'): return 1
			else:
				if ((ch == '*') && (bytes[index + 1] != '=')): return 1
				if ((ch != '*') && (bytes[index + 1] == ch)): return 1
		char* tails = c"([.+-*/%<>=&|^?"
		for j in range(15):
			if (tails[j] == ch): return 0
		if (ch == 'i'):
			if (index + 1 >= limit):
				if (eof == 0): return -2
			else if (bytes[index + 1] == 'n'):
				if (index + 2 >= limit):
					if (eof): return 0
					return -2
				if (is_ident_part_byte(bytes[index + 2]) == 0): return 0
		return 1
	if (eof): return 1
	return -2


# A complete scalar expression in the buffered window. The terminator is
# left for the enclosing grammar. Unsupported characters
# decline the whole root. No lexing or I/O happens in this preflight.
int ast_expression_root_end(int eof, int statement):
	if ((file < 0) || (file >= GETCHAR_MAX_FD)): return -1
	int window_start = getchar_kernel_pos[file] - getchar_limit[file]
	int index = token_start_offset - window_start
	if ((index < 0) || (index >= getchar_limit[file])): return -1
	char* bytes = cast(char*, getchar_buf_addr[file])
	int parens = 0
	int brackets = 0
	int braces = 0
	int significant = 0
	int ternaries = 0
	int previous = 0
	int i = 0
	while ((i < 2048) && (index + i < getchar_limit[file])):
		int ch = bytes[index + i] & 255
		if ((ch == '/') && (index + i + 1 < getchar_limit[file]) && (bytes[index + i + 1] == '*')):
			int after = ast_expression_comment_end(bytes, index + i, getchar_limit[file] - 1, 1)
			if (after < 0): return after
			if (after - index >= 2048): return -1
			i = after - index
			previous = 0
			continue
		if ((ch == 39) || (ch == '"')):
			int quoted = ast_expression_quoted_end(bytes, index + i, getchar_limit[file] - 1)
			if (quoted < 0): return quoted
			if (quoted - index >= 2048): return -1
			i = quoted - index + 1
			significant = 34
			previous = 0
			continue
		if ((parens == 0) && (brackets == 0) && (braces == 0)):
			if ((ch == ')') || (ch == ']') || ((ch == ',') && (statement == 0)) || (ch == ';') || (ch == '}') || ((ch == '{') && (significant != ']'))):
				if (ternaries): return -1
				return window_start + index + i
			if ((ch == '#') || (ch == 10)):
				int boundary = ast_expression_line_boundary(bytes, index + i, getchar_limit[file], eof)
				if (boundary == -2): return -2
				if (boundary):
					if (ternaries): return -1
					return window_start + index + i
			if ((ch == ':') && (ternaries == 0)): return window_start + index + i
			if (ch == '?'): ternaries = ternaries + 1
			if (ch == ':'): ternaries = ternaries - 1
		if (ch == '#'):
			while ((index + i < getchar_limit[file]) && (bytes[index + i] != 10)): i = i + 1
			previous = 0
			continue
		if (ch == 10):
			if (index + i + 1 >= getchar_limit[file]): return -2
			if (bytes[index + i + 1] == ' '): return -1
			previous = 0
			i = i + 1
			continue
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
		if (ch == '{'):
			braces = braces + 1
			allowed = 1
		if (ch == '}'):
			braces = braces - 1
			allowed = 1
		if (allowed == 0): return -1
		if ((previous == '/') && ((ch == '/') || (ch == '*'))): return -1
		if ((ch != ' ') && (ch != 9)): significant = ch
		previous = ch
		i = i + 1
	if ((i < 2048) && (eof == 0)): return -2
	return -1


# Retain the candidate and lookahead while extending getchar's window.
# Compaction changes only the physical buffer position, never the logical
# lexer position. Reads happen before taking the speculative snapshot, and
# no seek is needed (including for pipes). EOF is learned from read(), not
# inferred from a short read. An unavailable prefix still declines safely.
int ast_expression_refill(int start):
	if ((file < 0) || (file >= GETCHAR_MAX_FD)): return -1
	int index = start - (getchar_kernel_pos[file] - getchar_limit[file])
	if ((index < 0) || (index > getchar_pos[file])): return -1
	int kept = getchar_limit[file] - index
	if ((kept < 0) || (kept >= GETCHAR_BUF_CAPACITY)): return -1
	char* bytes = cast(char*, getchar_buf_addr[file])
	for i in range(kept): bytes[i] = bytes[index + i]
	getchar_pos[file] = getchar_pos[file] - index
	getchar_limit[file] = kept
	int count = read(file, bytes + kept, GETCHAR_BUF_CAPACITY - kept)
	if (count <= 0): return count
	getchar_limit[file] = kept + count
	getchar_kernel_pos[file] = getchar_kernel_pos[file] + count
	return 1


# A token may itself have crossed getchar's refill before expression()
# starts. Recover its discarded prefix from the still-raw token spelling.
# Keep every already-read byte (including pipe input) in a larger owned
# buffer; the ordinary reader can reuse it for its usual 8 KiB refills.
void ast_expression_retain_token():
	if ((file < 0) || (file >= GETCHAR_MAX_FD)): return
	int missing = getchar_kernel_pos[file] - getchar_limit[file] - token_start_offset
	if (missing <= 0): return
	if ((token_i > 2048) || (missing > token_i + 1) || (nextc < 0)): return
	if (byte_offset - 1 - token_start_offset != token_i): return
	int length = getchar_limit[file]
	# A recovered token is bounded by the AST source limit. Decline an
	# unusual pre-existing window rather than assume its allocation size.
	if (length > GETCHAR_BUF_CAPACITY): return
	char* old = cast(char*, getchar_buf_addr[file])
	char* bytes = malloc(2 * GETCHAR_BUF_CAPACITY)
	# A speculative declaration lookahead can seek back to the byte
	# after nextc, leaving both the raw token and nextc outside the new
	# window. The tokenizer still owns that one lookahead byte.
	int prefix = missing
	if (prefix > token_i): prefix = token_i
	for i in range(prefix): bytes[i] = token[i]
	if (missing > token_i): bytes[token_i] = cast(char, nextc)
	for i in range(length): bytes[missing + i] = old[i]
	getchar_buf_addr[file] = cast(int, bytes)
	getchar_limit[file] = missing + length
	getchar_pos[file] = missing + getchar_pos[file]
	free(old)


int ast_expression_boundary(int start, int whole):
	if (whole): ast_expression_retain_token()
	while (1):
		int end
		if (whole): end = ast_expression_root_end(0, whole > 1)
		else: end = ast_expression_end(start)
		if (end != -2): return end
		int more = ast_expression_refill(start)
		if (more < 0): return -1
		if (more == 0):
			if (whole): end = ast_expression_root_end(1, whole > 1)
			if (end < 0): return -1
			return end
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
				int after = ast_expression_comment_end(bytes, pos - window_start, getchar_limit[file], 1)
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


# Type predicates also see the arena's temporary pointer records. No heap
# type records, imports, symbol uses or diagnostics are committed by a probe.
int ast_expression_scalar_type(int type):
	if (type_is_gpu_object(type) || type_is_gpu_pointer(type)): return 0
	int base = type_unqualified(type)
	if (type_get_pointer_level(base) > 0): return 1
	if (type_is_string(base)): return 1
	if (type_is_map(base) || type_is_set(base) || type_is_list(base)): return 1
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
	if ((type == 3) || (type == 4) || (type == float32_value_type) || (type == float64_value_type) || (type == string_value_type) || (type == string_literal_type)): return 1
	return ast_expression_scalar_type(type)


# Record lvalues can expose fields; record values can also flow through
# copies and calls without a load. Keep those two predicates separate.
int ast_expression_record_type(int type):
	if (type_is_value(type) || type_is_gpu_object(type)): return 0
	int base = type_unqualified(type)
	int kind = type_get_kind(base)
	if ((kind != 0) && (kind != type_kind_union)): return 0
	return type_num_args(base) > 0


int ast_expression_record_value(int type):
	return ast_expression_record_type(type_real(type))


int ast_expression_data_value(int type):
	return ast_expression_scalar_value(type) || ast_expression_record_value(type) || ((type_is_array(type) || type_is_slice(type)) && (type_is_gpu_object(type) == 0))


int ast_expression_storage_type(int type):
	if (type_is_gpu_object(type) || type_is_gpu_pointer(type)): return 0
	if (type_is_buffer(type) || type_is_list(type)): return 1
	return ast_expression_scalar_type(type) || ast_expression_record_type(type)


# The type-only half of promote(), restricted to this arena's scalar
# types. Value-encoded call results differ from loaded float lvalues.
int ast_expression_promoted_type(int type):
	if (type == string_type): return string_value_type
	if (type_is_value(type)): return type_strip_gpu(type_real(type))
	if (type_is_array(type) || (type_get_kind(type) == type_kind_slice)):
		int promoted = type_lookup_slice_value(type_get_element_type(type))
		if (promoted >= 0): return promoted
	int kind = type_float_kind(type)
	if (kind): return float_binary_result_type(kind)
	return type


int ast_expression_argument_compatible(expression_ast* tree, int want, int id):
	if (ast_expression_prepare_value(tree, tree.result_type[id], token_start_offset) == 0): return 0
	int got = ast_expression_promoted_type(tree.result_type[id])
	if (got == 4):
		int signature = type_function_pointer_signature(want)
		if ((signature < 0) || (tree.op[id] != 'v')): return 0
		return function_signature_matches_record(signature, tree.symbol[id])
	return types_compatible_with_expression(want, got)


int ast_expression_call(expression_ast* tree, int id, int depth):
	if (token_newline): return -1
	int sym = tree.symbol[id]
	int arity = sym_num_args(sym)
	if ((sym_variadic_fixed_args(sym) >= 0) || (sym_w_variadic_fixed_args(sym) >= 0)): return -1
	if (sym_is_generator(sym) || sym_is_kernel(sym)): return -1
	int result = load_int(table + sym + 6)
	if ((result != 0) && (result != 4) && (ast_expression_data_value(result) == 0)): return -1
	if (ast_expression_accept(tree, c"(") == 0): return -1
	int count = 0
	int previous = -1
	while (peek(c")") == 0):
		if ((arity >= 0) && (count >= arity)): return -1
		int param = sym_param_type(sym, count)
		if ((param >= 0) && (ast_expression_data_value(param) == 0)): return -1
		int arg = ast_expression_assignment(tree, depth + 1)
		if (arg < 0): return -1
		if (ast_expression_data_value(tree.result_type[arg]) == 0): return -1
		if (ast_expression_prepare_value(tree, tree.result_type[arg], token_start_offset) == 0): return -1
		int got = ast_expression_promoted_type(tree.result_type[arg])
		if ((param >= 0) && type_is_string(param) && type_is_char_pointer(got)):
			if (sym_probe(c"str_from_cstr") < 0): return -1
		# Let the streaming parser issue argument diagnostics at its exact
		# source position, including warnings promoted by --strict.
		if ((param >= 0) && (ast_expression_argument_compatible(tree, param, arg) == 0)): return -1
		if (previous < 0): tree.left[id] = arg
		else: tree.next_arg[previous] = arg
		previous = arg
		count = count + 1
		if (ast_expression_accept(tree, c",") == 0): break
		if (peek(c")")): return -1
	if (peek(c")") == 0): return -1
	if (token_start_offset >= tree.end_offset): return -1
	# Defaults are declaration-time constants, with no source-token replay.
	# Check the entire missing suffix before adding synthetic arguments.
	for i in range(count, arity):
		if (sym_param_has_default(sym, i) == 0): return -1
		int param = sym_param_type(sym, i)
		if ((param >= 0) && (ast_expression_scalar_type(param) == 0)): return -1
	while (count < arity):
		int arg = expression_ast_add(tree, 'c', -1, -1)
		if (arg < 0): return -1
		tree.value[arg] = sym_param_default(sym, count)
		if (previous < 0): tree.left[id] = arg
		else: tree.next_arg[previous] = arg
		previous = arg
		count = count + 1

	ast_expression_advance(tree)
	tree.op[id] = 'C'
	tree.result_type[id] = type_value(result)
	if (result == 4): tree.result_type[id] = 3
	return id


int ast_expression_indirect_call(expression_ast* tree, int callee, int depth):
	if (token_newline): return -1
	int type = tree.result_type[callee]
	if ((type == 4) && (tree.op[callee] == 'v')): return ast_expression_call(tree, callee, depth)
	if (ast_expression_scalar_value(type) == 0): return -1
	if (type_float_kind(type) || type_is_string(type)): return -1
	int signature = type_function_pointer_signature(type)
	int arity = -1
	int result = -1
	if (signature >= 0):
		arity = type_function_param_count(signature)
		result = type_function_return(signature)
		if ((arity < 0) || (arity > 10)): return -1
		if ((result != 0) && (ast_expression_data_value(result) == 0)): return -1
	int id = expression_ast_add(tree, 'F', callee, -1)
	if (id < 0): return -1
	tree.value[id] = signature
	tree.high[id] = result
	tree.result_type[id] = 3
	if (result >= 0): tree.result_type[id] = type_value(result)
	if (ast_expression_accept(tree, c"(") == 0): return -1
	int count = 0
	int previous = -1
	while (peek(c")") == 0):
		if ((arity >= 0) && (count >= arity)): return -1
		int arg = ast_expression_assignment(tree, depth + 1)
		if (arg < 0): return -1
		if (ast_expression_data_value(tree.result_type[arg]) == 0): return -1
		if (ast_expression_prepare_value(tree, tree.result_type[arg], token_start_offset) == 0): return -1
		if (signature >= 0):
			int param = type_function_param_type(signature, count)
			if (ast_expression_data_value(param) == 0): return -1
			if (ast_expression_argument_compatible(tree, param, arg) == 0): return -1
			if (type_is_string(param) && type_is_char_pointer(ast_expression_promoted_type(tree.result_type[arg]))):
				if (sym_probe(c"str_from_cstr") < 0): return -1
		if (previous < 0): tree.right[id] = arg
		else: tree.next_arg[previous] = arg
		previous = arg
		count = count + 1
		if (ast_expression_accept(tree, c",") == 0): break
		if (peek(c")")): return -1
	if ((arity >= 0) && (count != arity)): return -1
	if ((peek(c")") == 0) || (token_start_offset >= tree.end_offset)): return -1
	ast_expression_advance(tree)
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


int ast_expression_named_type(expression_ast* tree, int scalar, int depth);


# Bind captured signature syntax against explicit type arguments. Only
# existing composite records are admitted; pointer records are staged in
# the expression transaction at the closing type-argument bracket.
int ast_expression_bind_generic_type(expression_ast* tree, int id, generic_type_ast* node):
	int type = -1
	int def = tree.value[id]
	int argument = tree.right[id]
	int i = 0
	while (argument >= 0):
		if (strcmp(node.name, generic_def_param_name(def, i)) == 0): type = tree.value[argument]
		argument = tree.next_arg[argument]
		i = i + 1
	if (node.application == 2):
		int element = ast_expression_bind_generic_type(tree, id, node.first)
		if (element < 0): return -1
		type = type_lookup_slice(element)
	else if (node.application == 1):
		int shape_def = generic_def_lookup(node.name, 1)
		if (shape_def < 0): return -1
		int[8] arguments
		int count = 0
		generic_type_ast* argument = node.first
		while (argument != 0):
			if (count == generic_max_params): return -1
			int bound = ast_expression_bind_generic_type(tree, id, argument)
			if (bound < 0): return -1
			arguments[count] = bound
			count = count + 1
			argument = argument.next
		if (count != generic_def_param_count(shape_def)): return -1
		char* name = generic_mangle(node.name, cast(int, &arguments[0]), count)
		type = type_lookup(name)
		free(name)
	else if (node.first != 0):
		int first = ast_expression_bind_generic_type(tree, id, node.first)
		if (first < 0): return -1
		if (strcmp(node.name, c"map") == 0):
			int second = ast_expression_bind_generic_type(tree, id, node.second)
			if (second < 0): return -1
			type = type_lookup_map(first, second)
		else if (strcmp(node.name, c"set") == 0): type = type_lookup_set(first)
		else: type = type_lookup_list(first)
	else if (type < 0): type = type_lookup(node.name)
	if (type < 0): return -1
	int base = type_unqualified(type)
	if ((word_size != 8) && ((base == float64_type) || (base == int64_type) || (base == uint64_type))): return -1
	for j in range(node.stars):
		type = ast_expression_pointer_type(tree, type, tree.generic_offset[id])
		if (type < 0): return -1
	return type


int ast_expression_generic_same(expression_ast* tree, int first, int second):
	if (tree.value[first] != tree.value[second]): return 0
	int a = tree.right[first]
	int b = tree.right[second]
	while ((a >= 0) && (b >= 0)):
		if (type_canonical(tree.value[a]) != type_canonical(tree.value[b])): return 0
		a = tree.next_arg[a]
		b = tree.next_arg[b]
	return a == b


int ast_expression_generic_parameter(expression_ast* tree, int id, int index):
	if (tree.symbol[id] >= 0): return sym_param_type(tree.symbol[id], index)
	int parameter = tree.generic_parameters[id]
	if (parameter < 0): return type_function_param_type(tree.generic_signature[id], index)
	for i in range(index): parameter = tree.next_arg[parameter]
	return tree.value[parameter]


int ast_expression_generic_call(expression_ast* tree, int depth):
	if (nextc != '['): return -1
	int def = generic_def_lookup(token, 0)
	int id = expression_ast_add(tree, 'G', -1, -1)
	if (id < 0): return -1
	tree.value[id] = def
	tree.generic_parameters[id] = -1
	tree.generic_signature[id] = -1
	tree.generic_instance[id] = -1
	ast_expression_advance(tree)
	if (ast_expression_accept(tree, c"[") == 0): return -1
	int[8] types
	int count = 0
	int tail = -1
	while (1):
		if (count == generic_max_params): return -1
		int type = ast_expression_named_type(tree, 0, depth + 1)
		if (type < 0): return -1
		int argument = expression_ast_add(tree, 'g', -1, -1)
		if (argument < 0): return -1
		tree.value[argument] = type
		if (tail < 0): tree.right[id] = argument
		else: tree.next_arg[tail] = argument
		tail = argument
		types[count] = type
		count = count + 1
		if (ast_expression_accept(tree, c",") == 0): break
	if ((peek(c"]") == 0) || (count != generic_def_param_count(def))): return -1
	tree.generic_offset[id] = token_start_offset
	char* mangled = generic_mangle(generic_def_name(def), cast(int, &types[0]), count)
	int sym = sym_probe(mangled)
	int inst = generic_inst_lookup(mangled)
	free(mangled)
	tree.symbol[id] = sym
	int arity = -1
	int result = -1
	if (sym >= 0):
		arity = sym_num_args(sym)
		result = load_int(table + sym + 6)
	else:
		int signature = -1
		if (inst >= 0): signature = generic_insts[inst].signature
		if (signature >= 0):
			tree.generic_signature[id] = signature
			arity = type_function_param_count(signature)
			result = type_function_return(signature)
		else:
			# Repeated calls in one tree share the same reserved signature.
			for previous in range(id):
				if ((tree.op[previous] == 'G') && ast_expression_generic_same(tree, previous, id)):
					tree.generic_signature[id] = tree.generic_signature[previous]
					tree.generic_parameters[id] = tree.generic_parameters[previous]
					arity = tree.generic_arity[previous]
					result = tree.high[previous]
			if (tree.generic_signature[id] < 0):
				generic_signature_ast* syntax = generic_defs[def].signature_ast
				if ((syntax == 0) || tree.pending_buffer_types): return -1
				arity = syntax.count
				if (arity > 10): return -1
				result = ast_expression_bind_generic_type(tree, id, syntax.result)
				if (result < 0): return -1
				generic_type_ast* parameter = syntax.parameters
				tail = -1
				while (parameter != 0):
					int type = ast_expression_bind_generic_type(tree, id, parameter)
					if (type < 0): return -1
					int bound = expression_ast_add(tree, 'g', -1, -1)
					if (bound < 0): return -1
					tree.value[bound] = type
					if (tail < 0): tree.generic_parameters[id] = bound
					else: tree.next_arg[tail] = bound
					tail = bound
					parameter = parameter.next
				tree.generic_signature[id] = ast_expression_reserve_signature(tree, id, result, arity)
				if (tree.generic_signature[id] < 0): return -1
	if ((arity < 0) || (arity > 10)): return -1
	if ((result != 0) && (ast_expression_data_value(result) == 0)): return -1
	tree.high[id] = result
	tree.generic_arity[id] = arity
	tree.result_type[id] = type_value(result)
	ast_expression_advance(tree)
	if (token_newline || (ast_expression_accept(tree, c"(") == 0)): return -1
	count = 0
	tail = -1
	while (peek(c")") == 0):
		if (count >= arity): return -1
		int want = ast_expression_generic_parameter(tree, id, count)
		if (ast_expression_data_value(want) == 0): return -1
		int argument = ast_expression_assignment(tree, depth + 1)
		if (argument < 0): return -1
		if (ast_expression_data_value(tree.result_type[argument]) == 0): return -1
		if (ast_expression_argument_compatible(tree, want, argument) == 0): return -1
		if (type_is_string(want) && type_is_char_pointer(ast_expression_promoted_type(tree.result_type[argument]))):
			if (sym_probe(c"str_from_cstr") < 0): return -1
		if (tail < 0): tree.left[id] = argument
		else: tree.next_arg[tail] = argument
		tail = argument
		count = count + 1
		if (ast_expression_accept(tree, c",") == 0): break
		if (peek(c")")): return -1
	if ((count != arity) || (ast_expression_accept(tree, c")") == 0)): return -1
	return id


# All speculative records have been removed before this runs. Ordinary
# instantiation commits its signature at the original closing bracket;
# the reserved slot verifies that no hidden registration reordered it.
void ast_expression_commit_generic(expression_ast* tree, int id):
	int count = generic_def_param_count(tree.value[id])
	int args = cast(int, malloc(count * __word_size__))
	int argument = tree.right[id]
	for i in range(count):
		save_ptr(args + i * __word_size__, tree.value[argument])
		argument = tree.next_arg[argument]
	char* mangled = generic_mangle(generic_def_name(tree.value[id]), args, count)
	int sym = sym_lookup(mangled)
	if (sym >= 0):
		assert1(sym == tree.symbol[id])
		strcpy(last_identifier, mangled)
		free(mangled)
		free(cast(char*, args))
		return
	int inst = generic_inst_intern(tree.value[id], args, count, mangled)
	int signature = generic_inst_signature(inst)
	assert1(signature == tree.generic_signature[id])
	tree.generic_instance[id] = inst


int ast_expression_container_literal(expression_ast* tree, int depth):
	int type = ast_expression_named_type(tree, 0, depth + 1)
	if (type < 0): return -1
	if (ast_expression_accept(tree, c"{") == 0): return -1
	int map = type_is_map(type)
	int list = type_is_list(type)
	if ((map || list || type_is_set(type)) == 0): return -1
	char* create = c"__w_set_new"
	if (map): create = c"__w_map_new"
	if (list): create = c"__w_list_new"
	if (sym_probe(create) < 0): return -1
	int id = expression_ast_add(tree, 'O', -1, -1)
	if (id < 0): return -1
	tree.value[id] = type
	tree.result_type[id] = type_value(type)
	int tail = -1
	while (peek(c"}") == 0):
		int first_type = type_set_key_type(type)
		if (map): first_type = type_map_key_type(type)
		if (list): first_type = type_list_element_type(type)
		int first = ast_expression_assignment(tree, depth + 1)
		if (first < 0): return -1
		if (ast_expression_data_value(tree.result_type[first]) == 0): return -1
		if (ast_expression_argument_compatible(tree, first_type, first) == 0): return -1
		int second = -1
		int bytes = 0
		char* helper = c"__w_set_add"
		if (list):
			helper = c"__w_list_push"
			if (ast_expression_record_value(first_type) && ast_expression_record_value(tree.result_type[first])):
				helper = c"__w_list_push_bytes"
				bytes = 1
		if (map):
			if (ast_expression_accept(tree, c":") == 0): return -1
			second = ast_expression_assignment(tree, depth + 1)
			if (second < 0): return -1
			if (ast_expression_data_value(tree.result_type[second]) == 0): return -1
			int second_type = type_map_value_type(type)
			if (ast_expression_argument_compatible(tree, second_type, second) == 0): return -1
			helper = c"__w_map_set"
			if (ast_expression_record_value(second_type) && ast_expression_record_value(tree.result_type[second])):
				helper = c"__w_map_set_bytes"
				bytes = 1
		if (sym_probe(helper) < 0): return -1
		int entry = expression_ast_add(tree, 'e', first, second)
		if (entry < 0): return -1
		tree.value[entry] = bytes
		if (tail < 0): tree.left[id] = entry
		else: tree.next_arg[tail] = entry
		tail = entry
		if (ast_expression_accept(tree, c",") == 0): break
	if (ast_expression_accept(tree, c"}") == 0): return -1
	return id


# Current token is '(' after a resolved ordinary type name. Field nodes
# retain source order even when named arguments select different fields.
int ast_expression_constructor(expression_ast* tree, int base, int heap, int depth):
	if (heap && (sym_probe(c"malloc") < 0)): return -1
	if (ast_expression_accept(tree, c"(") == 0): return -1
	int id = expression_ast_add(tree, 'D', -1, -1)
	if (id < 0): return -1
	tree.value[id] = base
	tree.high[id] = heap
	int named = is_ident_start_byte(token[0]) && (nextc == ':')
	tree.symbol[id] = named
	int count = 0
	int tail = -1
	while (peek(c")") == 0):
		int field = count
		int has_name = is_ident_start_byte(token[0]) && (nextc == ':')
		if (has_name != named): return -1
		if (named):
			field = type_get_arg(base, token)
			if (field < 0): return -1
			ast_expression_advance(tree)
			if (ast_expression_accept(tree, c":") == 0): return -1
		if (field >= type_num_args(base)): return -1
		int want = type_get_field_type_at(base, field)
		if (type_has_array_field(want)): return -1
		int argument = ast_expression_assignment(tree, depth + 1)
		if (argument < 0): return -1
		if (ast_expression_data_value(tree.result_type[argument]) == 0): return -1
		if (ast_expression_argument_compatible(tree, want, argument) == 0): return -1
		int entry = expression_ast_add(tree, 'u', argument, -1)
		if (entry < 0): return -1
		tree.value[entry] = field
		if (tail < 0): tree.left[id] = entry
		else: tree.next_arg[tail] = entry
		tail = entry
		count = count + 1
		if (ast_expression_accept(tree, c",") == 0): break
		if (peek(c")")): return -1
	if (peek(c")") == 0): return -1
	if ((count > 0) && (named == 0) && (count != type_num_args(base))): return -1
	int result = base
	if (heap): result = ast_expression_pointer_type(tree, base, token_start_offset)
	if (result < 0): return -1
	tree.result_type[id] = type_value(result)
	ast_expression_advance(tree)
	return id


int ast_expression_name(expression_ast* tree, int depth):
	# Keywords, unshadowable builtins, generics and constructors take
	# precedence over identifier() in the streaming grammar.
	if (peek(c"cast") || peek(c"sizeof") || peek(c"new")): return -1
	if ((nextc == '[') && (peek(c"map") || peek(c"set") || peek(c"list"))): return ast_expression_container_literal(tree, depth)
	if ((nextc == '(') && (peek(c"print") || peek(c"println"))): return ast_expression_print(tree, depth)
	if (peek(c"to_json") || peek(c"from_json")): return -1
	if ((nextc == '.') && (import_alias_lookup(token) >= 0)): return -1
	if (generic_call_ready()): return ast_expression_generic_call(tree, depth)
	if ((nextc == '(') && struct_value_ctor_ready()):
		int base = type_lookup(token)
		if (ast_expression_record_type(base) == 0): return -1
		ast_expression_advance(tree)
		return ast_expression_constructor(tree, base, 0, depth)
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
	if (is_call): tree.result_type[id] = 4
	# Keep a stable name offset across append-only lazy helper registration
	# during emission, with no allocation needing error cleanup.
	tree.value[id] = sym - strlen(token)
	ast_expression_advance(tree)
	if (is_call && peek(c"(")): return ast_expression_call(tree, id, depth)
	return id


int ast_expression_postfix(expression_ast* tree, int depth);


# Resolve existing named/container types, staging new pointer records.
# New composite records and generic/qualified syntax still fall back.
int ast_expression_named_type(expression_ast* tree, int scalar, int depth):
	if (depth > 96): return -1
	int is_const = ast_expression_accept(tree, c"const")
	int type = -1
	if ((nextc == '[') && (peek(c"map") || peek(c"set") || peek(c"list"))):
		int kind = type_kind_list
		if (peek(c"map")): kind = type_kind_map
		if (peek(c"set")): kind = type_kind_set
		ast_expression_advance(tree)
		if (ast_expression_accept(tree, c"[") == 0): return -1
		int first = ast_expression_named_type(tree, 0, depth + 1)
		if (first < 0): return -1
		if (kind == type_kind_map):
			if (ast_expression_accept(tree, c",") == 0): return -1
			int second = ast_expression_named_type(tree, 0, depth + 1)
			if (second < 0): return -1
			type = type_lookup_map(first, second)
		else if (kind == type_kind_set): type = type_lookup_set(first)
		else: type = type_lookup_list(first)
		if (ast_expression_accept(tree, c"]") == 0): return -1
	else:
		type = generic_subst_lookup(token)
		if (type < 0): type = type_lookup(token)
		ast_expression_advance(tree)
	if (type < 0): return -1
	int base = type_unqualified(type)
	if ((word_size != 8) && ((base == float64_type) || (base == int64_type) || (base == uint64_type))): return -1
	if (is_const):
		type = type_lookup_const(type)
		if (type < 0): return -1
	while (peek(c"*") && (token_start_offset < tree.end_offset)):
		int offset = token_start_offset
		ast_expression_advance(tree)
		type = ast_expression_pointer_type(tree, type, offset)
		if (type < 0): return -1
	if (scalar && (ast_expression_scalar_type(type) == 0)): return -1
	return type


int ast_expression_new_array(expression_ast* tree, int base, int depth):
	if (type_get_size(base) <= 0): return -1
	if (sym_probe(c"malloc") < 0): return -1
	if (ast_expression_accept(tree, c"[") == 0): return -1
	int length = ast_expression_assignment(tree, depth + 1)
	if (length < 0): return -1
	if (ast_expression_scalar_value(tree.result_type[length]) == 0): return -1
	if (peek(c"]") == 0): return -1
	int type = ast_expression_slice_value_type(tree, base, token_start_offset)
	if (type < 0): return -1
	ast_expression_advance(tree)
	int id = expression_ast_add(tree, 'Y', length, -1)
	if (id < 0): return -1
	tree.value[id] = base
	tree.result_type[id] = type
	return id


int ast_expression_unary(expression_ast* tree, int depth):
	if ((depth > 96) || (expr_nesting_depth + depth >= 1000)): return -1
	if (token_start_offset >= tree.end_offset): return -1
	if (ast_expression_accept(tree, c"sizeof")):
		if (ast_expression_accept(tree, c"(") == 0): return -1
		int sized = ast_expression_named_type(tree, 0, depth + 1)
		if ((sized < 0) || (ast_expression_accept(tree, c")") == 0)): return -1
		int id = expression_ast_add(tree, 'c', -1, -1)
		if (id >= 0): tree.value[id] = type_get_size(sized)
		return id
	if (ast_expression_accept(tree, c"new")):
		if ((nextc == '[') && (peek(c"map") || peek(c"set") || peek(c"list"))):
			int container = ast_expression_named_type(tree, 0, depth + 1)
			if ((container < 0) || peek(c"(")): return -1
			if ((type_is_list(container) || type_is_map(container) || type_is_set(container)) == 0): return -1
			char* helper = c"__w_list_new"
			if (type_is_map(container)): helper = c"__w_map_new"
			if (type_is_set(container)): helper = c"__w_set_new"
			if (sym_probe(helper) < 0): return -1
			int id = expression_ast_add(tree, 'V', -1, -1)
			if (id < 0): return -1
			tree.value[id] = container
			tree.result_type[id] = type_value(container)
			return id
		# Bare ordinary types and empty constructor parentheses.
		if ((nextc == '.') && (import_alias_lookup(token) >= 0)): return -1
		int base = type_lookup(token)
		if (base < 0): return -1
		int offset = token_start_offset
		ast_expression_advance(tree)
		if (peek(c"[")): return ast_expression_new_array(tree, base, depth)
		if (peek(c"(")): return ast_expression_constructor(tree, base, 1, depth)
		if (sym_probe(c"malloc") < 0): return -1
		int pointer = ast_expression_pointer_type(tree, base, offset)
		if (pointer < 0): return -1
		int id = expression_ast_add(tree, 'N', -1, -1)
		if (id < 0): return -1
		tree.value[id] = base
		tree.result_type[id] = type_value(pointer)
		return id
	if (ast_expression_accept(tree, c"cast")):
		if (ast_expression_accept(tree, c"(") == 0): return -1
		int want = ast_expression_named_type(tree, 1, depth + 1)
		if ((want < 0) || (ast_expression_accept(tree, c",") == 0)): return -1
		tree.cast_depth = tree.cast_depth + 1
		int child = ast_expression_assignment(tree, depth + 1)
		tree.cast_depth = tree.cast_depth - 1
		if ((child < 0) || (peek(c")") == 0)): return -1
		int child_type = tree.result_type[child]
		if ((ast_expression_scalar_value(child_type) || type_is_array(child_type) || type_is_slice(child_type)) == 0): return -1
		if (ast_expression_prepare_value(tree, child_type, token_start_offset) == 0): return -1
		int got = ast_expression_promoted_type(child_type)
		int buffer_value = type_get_kind(type_unqualified(got)) == type_kind_slice_value
		if (buffer_value && (type_get_pointer_level(type_unqualified(want)) > 0)):
			if (type_decays_to_pointer(want, got) == 0): return -1
		# coerce_explicit diagnoses truncating an address. Leave that at
		# the streaming parser's source location and diagnostic order.
		if (((got == 4) || (type_get_pointer_level(got) > 0) || buffer_value) && (type_get_pointer_level(want) == 0)):
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
			if (tree.op[child] == 'm'): return -1
			if (type_is_value(child_type) || (child_type == 3)): return -1
			return expression_ast_add(tree, op, child, -1)
		if (ast_expression_scalar_value(child_type) == 0): return -1
		if (op == 'd'):
			int element = 1
			if (type_get_pointer_level(child_type) > 0): element = type_lookup_previous_pointer(child_type)
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


# A template owns a sibling chain of raw chunks and value expressions.
# Resumed chunks retain the closing brace's source offset; replay uses
# that event to resume the template tokenizer at exactly the same byte.
int ast_expression_template(expression_ast* tree, int depth):
	int root = expression_ast_add(tree, 'E', -1, -1)
	if (root < 0): return -1
	tree.result_type[root] = string_literal_type
	int previous = -1
	int start = 2
	while (1):
		if (token_i == 0): return -1
		int final = token[token_i - 1] == 34
		if ((final == 0) && (token[token_i - 1] != '{')): return -1
		int chunk = expression_ast_add(tree, 't', -1, -1)
		if (chunk < 0): return -1
		tree.value[chunk] = start
		tree.high[chunk] = start == 0
		if (previous < 0): tree.left[root] = chunk
		else: tree.next_arg[previous] = chunk
		ast_expression_advance(tree)
		if (final): return root
		int value = ast_expression_assignment(tree, depth + 1)
		if ((value < 0) || (peek(c"}") == 0)): return -1
		int vc = value_class(ast_expression_promoted_type(tree.result_type[value]))
		if ((vc != VC_INT) && (vc != VC_CSTR) && (vc != VC_STRING) && (vc != VC_CHAR) && (vc != VC_F32) && (vc != VC_F64)): return -1
		tree.next_arg[chunk] = value
		previous = value
		get_token_template_chunk()
		start = 0
	return -1


int ast_expression_atom(expression_ast* tree, int depth):
	if ((token[0] == 'f') && (token[1] == 34)): return ast_expression_template(tree, depth)
	if (ast_expression_accept(tree, c"(")):
		int child = ast_expression_assignment(tree, depth + 1)
		if ((child < 0) || (peek(c")") == 0)): return -1
		if (token_start_offset >= tree.end_offset): return -1
		ast_expression_advance(tree)
		if (tree.op[child] == 'm'): tree.op[child] = 'q'
		return child
	if (token[0] == 39):
		int id = expression_ast_add(tree, 'h', -1, -1)
		if (id >= 0): ast_expression_advance(tree)
		return id
	if ((token[0] == '"') || (((token[0] == 'c') || (token[0] == 's')) && (token[1] == '"'))):
		int op = 'S'
		int type = string_literal_type
		int start = 1
		if ((token[0] != '"') && (token[1] == '"')):
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


int ast_expression_list_call(expression_ast* tree, int receiver, int depth):
	int method = 0
	if (peek(c"push")): method = 1
	if (peek(c"pop")): method = 2
	if (peek(c"insert")): method = 3
	if (peek(c"remove")): method = 4
	if (peek(c"clear")): method = 5
	if (peek(c"free")): method = 6
	if (method == 0): return -1
	int element = type_list_element_type(type_unqualified(tree.result_type[receiver]))
	if ((method == 2) && (ast_expression_data_value(element) == 0)): return -1
	int count = 0
	if ((method == 1) || (method == 4)): count = 1
	if (method == 3): count = 2
	int id = expression_ast_add(tree, 'M', receiver, -1)
	if (id < 0): return -1
	tree.high[id] = element
	tree.result_type[id] = type_value(0)
	if (method == 2): tree.result_type[id] = type_value(element)
	ast_expression_advance(tree)
	if (ast_expression_accept(tree, c"(") == 0): return -1
	int previous = -1
	for i in range(count):
		if (i && (ast_expression_accept(tree, c",") == 0)): return -1
		int arg = ast_expression_assignment(tree, depth + 1)
		if (arg < 0): return -1
		int type = tree.result_type[arg]
		int typed = (method == 1) || ((method == 3) && (i == 1))
		if (typed):
			if (ast_expression_data_value(type) == 0): return -1
			if (ast_expression_argument_compatible(tree, element, arg) == 0): return -1
			int got = ast_expression_promoted_type(type)
			if (type_is_string(element) && type_is_char_pointer(got)):
				if (sym_probe(c"str_from_cstr") < 0): return -1
			if ((type_num_args(element) > 0) && (type_num_args(got) > 0)): method = method + 128
		else if (ast_expression_scalar_value(type) == 0): return -1
		if (previous < 0): tree.right[id] = arg
		else: tree.next_arg[previous] = arg
		previous = arg
	if (ast_expression_accept(tree, c")") == 0): return -1
	if ((method == 2) && ast_expression_record_value(element)): method = method + 128
	if (sym_probe(ast_expression_method_helper(method)) < 0): return -1
	tree.value[id] = method
	return id


int ast_expression_hash_call(expression_ast* tree, int receiver, int depth):
	int container = type_unqualified(tree.result_type[receiver])
	int method = 0
	if (peek(c"remove")): method = 11
	if (peek(c"add") && type_is_set(container)): method = 12
	if (peek(c"free")): method = 13
	if (peek(c"get") && type_is_map(container)): method = 14
	if (method == 0): return -1
	int key_type = hash_container_key_type(container)
	int value_type = 0
	if (method == 14):
		value_type = type_map_value_type(container)
		if (ast_expression_data_value(value_type) == 0): return -1
	int id = expression_ast_add(tree, 'M', receiver, -1)
	if (id < 0): return -1
	tree.high[id] = key_type
	tree.symbol[id] = value_type
	tree.result_type[id] = type_value(0)
	if (method == 11): tree.result_type[id] = type_value(bool_type)
	if (method == 14):
		tree.result_type[id] = type_value(value_type)
		if (ast_expression_record_value(value_type)): tree.result_type[id] = type_canonical(value_type)
	ast_expression_advance(tree)
	if (ast_expression_accept(tree, c"(") == 0): return -1
	if (method != 13):
		int arg = ast_expression_assignment(tree, depth + 1)
		if (arg < 0): return -1
		if (ast_expression_data_value(tree.result_type[arg]) == 0): return -1
		if (ast_expression_prepare_value(tree, tree.result_type[arg], token_start_offset) == 0): return -1
		if (ast_expression_argument_compatible(tree, key_type, arg) == 0): return -1
		if (type_is_string(key_type) && type_is_char_pointer(ast_expression_promoted_type(tree.result_type[arg]))):
			if (sym_probe(c"str_from_cstr") < 0): return -1
		tree.right[id] = arg
		if ((method == 14) && ast_expression_accept(tree, c",")):
			int fallback = ast_expression_assignment(tree, depth + 1)
			if (fallback < 0): return -1
			if (ast_expression_data_value(tree.result_type[fallback]) == 0): return -1
			if (ast_expression_argument_compatible(tree, value_type, fallback) == 0): return -1
			if (type_is_string(value_type) && type_is_char_pointer(ast_expression_promoted_type(tree.result_type[fallback]))):
				if (sym_probe(c"str_from_cstr") < 0): return -1
			tree.next_arg[arg] = fallback
			method = 15
	if (ast_expression_accept(tree, c")") == 0): return -1
	if ((method >= 14) && ast_expression_record_value(value_type)): method = method + 128
	if (sym_probe(ast_expression_method_helper(method)) < 0): return -1
	tree.value[id] = method
	return id


# Keep an indexed map as its own node until assignment chooses a store.
# Parentheses finalize it to a read, just as expression() does in a group.
int ast_expression_map_index(expression_ast* tree, int receiver, int depth):
	int type = type_unqualified(tree.result_type[receiver])
	int element = type_map_value_type(type)
	int key_type = type_map_key_type(type)
	if (ast_expression_data_value(element) == 0): return -1
	int key = ast_expression_assignment(tree, depth + 1)
	if ((key < 0) || (peek(c"]") == 0)): return -1
	if (ast_expression_data_value(tree.result_type[key]) == 0): return -1
	if (ast_expression_argument_compatible(tree, key_type, key) == 0): return -1
	if (type_is_string(key_type) && type_is_char_pointer(ast_expression_promoted_type(tree.result_type[key]))):
		if (sym_probe(c"str_from_cstr") < 0): return -1
	ast_expression_advance(tree)
	int id = expression_ast_add(tree, 'm', receiver, key)
	if (id < 0): return -1
	tree.value[id] = type
	tree.result_type[id] = type_value(element)
	if (ast_expression_record_value(element)): tree.result_type[id] = type_canonical(element)
	return id


# The receiver and optional start have been parsed; ':' is consumed.
int ast_expression_slice(expression_ast* tree, int receiver, int start, int depth):
	if ((start >= 0) && (ast_expression_scalar_value(tree.result_type[start]) == 0)): return -1
	int end = -1
	if (peek(c"]") == 0):
		end = ast_expression_assignment(tree, depth + 1)
		if (end < 0): return -1
		if (ast_expression_scalar_value(tree.result_type[end]) == 0): return -1
	if (peek(c"]") == 0): return -1
	int type = tree.result_type[receiver]
	int result = string_value_type
	int op = 'Z'
	if (type_is_list(type)):
		if (sym_probe(c"__w_list_slice") < 0): return -1
		op = 'J'
		result = type_value(type_lookup_list(type_list_element_type(type)))
	else if (sym_probe(c"malloc") < 0): return -1
	else if (type_is_string(type) == 0):
		if (ast_expression_prepare_value(tree, type_real(type), token_start_offset) == 0): return -1
		result = type_lookup_slice_value(buffer_element_type(type))
		if (result < 0): return -1
	ast_expression_advance(tree)
	int id = expression_ast_add(tree, op, receiver, start)
	if (id < 0): return -1
	tree.high[id] = end
	tree.result_type[id] = result
	if (op == 'Z'): tree.readonly = 1
	return id


int ast_expression_postfix(expression_ast* tree, int depth):
	int left = ast_expression_atom(tree, depth)
	while (left >= 0):
		int type = tree.result_type[left]
		if (peek(c"(") && (token_start_offset < tree.end_offset)):
			left = ast_expression_indirect_call(tree, left, depth)
		else if (ast_expression_accept(tree, c"[")):
			tree.readonly = 0
			if (type_is_map(type)):
				left = ast_expression_map_index(tree, left, depth)
				continue
			if (type_is_set(type)): return -1
			int op = 'i'
			int element
			if (type_is_buffer(type)):
				op = 'I'
				element = buffer_element_type(type)
				if (ast_expression_prepare_value(tree, type, token_start_offset) == 0): return -1
			else if (type_is_list(type)):
				if (sym_probe(c"__w_list_addr") < 0): return -1
				op = 'j'
				element = type_list_element_type(type_unqualified(type))
			else:
				# Containers retain their pending-element machinery until
				# it has explicit AST nodes of its own.
				if (ast_expression_scalar_value(type) == 0): return -1
				if (type_float_kind(type)): return -1
				# Legacy untyped word addresses index bytes. Typed pointers
				# replace that default with their pointee's width and type.
				element = 2
				if (type_get_pointer_level(type) > 0): element = type_lookup_previous_pointer(type)
			if ((element < 0) || (ast_expression_storage_type(element) == 0)): return -1
			int index = -1
			if (((op != 'I') && (op != 'j')) || (peek(c":") == 0)):
				index = ast_expression_assignment(tree, depth + 1)
				if (index < 0): return -1
			if (((op == 'I') || (op == 'j')) && ast_expression_accept(tree, c":")):
				left = ast_expression_slice(tree, left, index, depth)
				continue
			if ((index < 0) || (peek(c"]") == 0)): return -1
			if (ast_expression_scalar_value(tree.result_type[index]) == 0): return -1
			ast_expression_advance(tree)
			# The streaming list helper retains the index expression's
			# readonly state; raw and buffer indexes explicitly clear it.
			if (op != 'j'): tree.readonly = 0
			left = expression_ast_add(tree, op, left, index)
			if (left < 0): return -1
			tree.result_type[left] = element
			tree.value[left] = type_get_size(element)
		else if (ast_expression_accept(tree, c".")):
			tree.readonly = 0
			int metadata = 0
			int field_type = 1
			int field_offset = word_size
			if ((type_is_buffer(type) || type_is_map(type) || type_is_set(type) || type_is_list(type)) && peek(c"length")): metadata = 1
			if (type_is_buffer(type) && peek(c"data")):
				metadata = 1
				field_offset = 0
			if (metadata):
				if (ast_expression_prepare_value(tree, type, token_start_offset) == 0): return -1
				if (field_offset == 0):
					field_type = ast_expression_pointer_type(tree, buffer_element_type(type), token_start_offset)
					if (field_type < 0): return -1
				ast_expression_advance(tree)
				left = expression_ast_add(tree, 'B', left, -1)
				if (left < 0): return -1
				tree.result_type[left] = field_type
				tree.value[left] = field_offset
				tree.readonly = 1
				continue
			if (type_is_list(type)):
				left = ast_expression_list_call(tree, left, depth)
				continue
			if (type_is_map(type) || type_is_set(type)):
				left = ast_expression_hash_call(tree, left, depth)
				continue
			int record = type
			int load_pointer = 0
			int return_words = 0
			if (type_is_value(type) && ast_expression_record_value(type)):
				# Only call results own the return buffer consumed by a
				# scalar field access. Other value-record forms still decline.
				if ((tree.op[left] != 'C') && (tree.op[left] != 'F') && (tree.op[left] != 'G') && (tree.op[left] != 'D')): return -1
				record = type_real(type)
				return_words = (type_get_size(record) + word_size - 1) >> word_size_log2
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
			if (return_words && (type_num_args(field) == 0)):
				if (ast_expression_scalar_type(field) == 0): return -1
				tree.high[left] = 0 - return_words
				tree.symbol[left] = field
				tree.result_type[left] = type_value(ast_expression_promoted_type(field))
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
		if (peek(c"*") && token_newline): return left
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
			if (peek(c"in")): op = 'H'
		if (op == 0): return left
		ast_expression_advance(tree)
		int right
		if (equality): right = ast_expression_compare(tree, depth, 0)
		else: right = ast_expression_shift(tree, depth)
		if (right < 0): return -1
		if ((ast_expression_scalar_value(tree.result_type[left]) && ast_expression_scalar_value(tree.result_type[right])) == 0): return -1
		int kind = 0
		if (op == 'H'):
			int container = type_unqualified(tree.result_type[right])
			int want = -1
			if (type_is_map(container)):
				want = type_map_key_type(container)
				kind = 1
			else if (type_is_set(container)):
				want = type_set_key_type(container)
				kind = 2
			else if (type_is_list(container)):
				want = type_list_element_type(container)
				if (ast_expression_scalar_type(want) == 0): return -1
				if (type_is_string(want)): return -1
				kind = 4
				if (hash_key_kind_for_type(want) == 2): kind = 3
			else: return -1
			if (ast_expression_argument_compatible(tree, want, left) == 0): return -1
			if (sym_probe(ast_expression_contains_helper(kind)) < 0): return -1
		left = expression_ast_add(tree, op, left, right)
		if (left < 0): return -1
		tree.value[left] = kind
		tree.result_type[left] = type_value(bool_type)
	return -1


# A definite call is enough to suppress the default bool-bitwise hint.
# Unknown implicit calls stay conservative; --bool-ops always uses the
# streaming diagnostic path. Count emitted calls, not runtime reachability,
# just as operand_is_pure does for a short-circuited operand.
int ast_expression_has_call(expression_ast* tree, int first, int end):
	for i in range(first, end):
		if ((tree.op[i] == 'C') || (tree.op[i] == 'F') || (tree.op[i] == 'P') || (tree.op[i] == 'j') || (tree.op[i] == 'N') || (tree.op[i] == 'V') || (tree.op[i] == 'M') || (tree.op[i] == 'm') || (tree.op[i] == 'q') || (tree.op[i] == 'w') || (tree.op[i] == 'H') || (tree.op[i] == 'E')): return 1
	return 0


int ast_expression_bitwise(expression_ast* tree, int depth, int level):
	int first_node = tree.count
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
	if (left < 0): return -1
	int chain_is_bool = operand_is_bool_condition(tree.result_type[left])
	int chain_has_call = ast_expression_has_call(tree, first_node, tree.count)
	while ((left >= 0) && ast_expression_accept(tree, spelling)):
		int right_first = tree.count
		int right
		if (level): right = ast_expression_bitwise(tree, depth, level - 1)
		else: right = ast_expression_compare(tree, depth, 1)
		if (right < 0): return -1
		int lt = tree.result_type[left]
		int rt = tree.result_type[right]
		if ((ast_expression_scalar_value(lt) && ast_expression_scalar_value(rt)) == 0): return -1
		int right_is_bool = operand_is_bool_condition(rt)
		int right_has_call = ast_expression_has_call(tree, right_first, tree.count)
		if (condition_context && (op != '^') && chain_is_bool && right_is_bool):
			if (check_bool_ops_mode || ((chain_has_call || right_has_call) == 0)): return -1
		chain_is_bool = chain_is_bool && right_is_bool
		chain_has_call = chain_has_call || right_has_call
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
	# Each entry corresponds to expression(), including groups, arguments,
	# indexes and assignment RHSs. The ternary else arm does not reset it.
	tree.readonly = 0
	int left = ast_expression_conditional(tree, depth)
	if (left < 0): return -1
	int op = compound_assign_op()
	if ((op == 0) && (peek(c"=") == 0)): return left
	if (lint_mode): return -1
	if (tree.readonly): return -1
	int lt = tree.result_type[left]
	int map_store = tree.op[left] == 'm'
	if (map_store): lt = type_map_value_type(tree.value[left])
	if (type_is_value(lt) || (lt == 3) || type_is_const(lt)): return -1
	if (ast_expression_data_value(lt) == 0): return -1
	if (type_is_array(lt)): return -1
	if (op && ast_expression_record_type(lt)): return -1
	if (op && type_is_buffer(type_canonical(lt))): return -1
	ast_expression_advance(tree)
	int right = ast_expression_assignment(tree, depth + 1)
	if (right < 0): return -1
	if (ast_expression_data_value(tree.result_type[right]) == 0): return -1
	if (op && (type_is_array(tree.result_type[right]) || type_is_slice(tree.result_type[right]))): return -1
	if (ast_expression_prepare_value(tree, tree.result_type[right], token_start_offset) == 0): return -1
	int rt = ast_expression_promoted_type(tree.result_type[right])
	if (ast_expression_record_type(lt) != ast_expression_record_value(rt)): return -1
	int result = rt
	if (op):
		int kind = binary_float_kind(ast_expression_promoted_type(lt), rt)
		if (kind && ((op != '+') && (op != '-') && (op != '*') && (op != '/'))): return -1
		result = 3
		if (kind): result = float_binary_result_type(kind)
	if (op):
		if (types_compatible_with_expression(lt, result) == 0): return -1
	else if (ast_expression_argument_compatible(tree, lt, right) == 0): return -1
	if (map_store && type_is_string(lt) && type_is_char_pointer(rt)):
		if (sym_probe(c"str_from_cstr") < 0): return -1
	int node_op = '='
	if (map_store): node_op = 'w'
	int id = expression_ast_add(tree, node_op, left, right)
	if (id < 0): return -1
	tree.value[id] = op
	tree.result_type[id] = type_value(lt)
	return id


int ast_expression_increment(expression_ast* tree, int child, int op):
	if (child < 0): return -1
	int type = tree.result_type[child]
	if (tree.readonly || type_is_value(type) || (type == 3) || (type == 4) || type_is_const(type)): return -1
	if (tree.op[child] == 'm'): return -1
	if (ast_expression_scalar_type(type) == 0): return -1
	if (type_is_buffer(type_canonical(type))): return -1
	int id = expression_ast_add(tree, 'U', child, -1)
	if (id < 0): return -1
	tree.value[id] = op
	tree.result_type[id] = type_value(type)
	return id


# Parallel assignment is admitted only by the whole statement entry.
# Pair nodes separate sibling links from any nested call's argument list.
int ast_expression_parallel(expression_ast* tree, int first):
	if (token_newline): return -1
	int head = -1
	int tail = -1
	int lhs = first
	while (1):
		int type = tree.result_type[lhs]
		if (tree.readonly || type_is_value(type) || (type == 3) || (type == 4) || type_is_const(type)): return -1
		if (tree.op[lhs] == 'm'): return -1
		if (ast_expression_scalar_type(type) == 0): return -1
		int pair = expression_ast_add(tree, 'T', lhs, -1)
		if (pair < 0): return -1
		if (head < 0): head = pair
		else: tree.next_arg[tail] = pair
		tail = pair
		if (ast_expression_accept(tree, c",") == 0): break
		tree.readonly = 0
		lhs = ast_expression_conditional(tree, 2)
		if (lhs < 0): return -1
	if (ast_expression_accept(tree, c"=") == 0): return -1
	int pair = head
	while (pair >= 0):
		int rhs = ast_expression_assignment(tree, 2)
		if (rhs < 0): return -1
		if (ast_expression_scalar_value(tree.result_type[rhs]) == 0): return -1
		int want = tree.result_type[tree.left[pair]]
		if (ast_expression_argument_compatible(tree, want, rhs) == 0): return -1
		if (type_is_string(want) && type_is_char_pointer(ast_expression_promoted_type(tree.result_type[rhs]))):
			if (sym_probe(c"str_from_cstr") < 0): return -1
		tree.right[pair] = rhs
		pair = tree.next_arg[pair]
		if (pair >= 0):
			if (ast_expression_accept(tree, c",") == 0): return -1
		else if (peek(c",")): return -1
	int id = expression_ast_add(tree, 'A', head, -1)
	if (id < 0): return -1
	tree.result_type[id] = type_value(tree.result_type[lhs])
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
	int end = ast_expression_boundary(group_offset, whole)
	if (end < 0): return -1
	expression_ast tree
	tree.count = 0
	tree.text_used = 0
	tree.types_base = type_count()
	tree.types_count = 0
	tree.pending_buffer_types = 0
	tree.readonly = 0
	tree.whole_expression = whole
	tree.end_offset = end
	tree.cast_depth = cast_context
	char* saved = generic_reparse_save()
	int serial = token_serial
	int root = -1
	int prefix = 0
	if (whole > 1): prefix = increment_op()
	if (prefix):
		ast_expression_advance(&tree)
		int child = ast_expression_unary(&tree, 1)
		root = ast_expression_increment(&tree, child, prefix)
	else:
		root = ast_expression_assignment(&tree, 1)
		if ((root >= 0) && (whole > 1) && (token_newline == 0)):
			int postfix = increment_op()
			if (postfix):
				ast_expression_advance(&tree)
				root = ast_expression_increment(&tree, root, postfix)
	if ((root >= 0) && (whole > 1) && peek(c",")): root = ast_expression_parallel(&tree, root)
	int accepted = (root >= 0) && (token_start_offset == end)
	if (whole == 0): accepted = accepted && peek(c")")
	if (accepted): accepted = ast_expression_data_value(tree.result_type[root]) || (tree.result_type[root] == type_value(0))
	ast_expression_restore_types(&tree)
	getchar_seek(file, load_ptr(saved + 7 * __word_size__))
	generic_reparse_restore(saved)
	token_serial = serial
	if (accepted == 0): return -1
	while (token_start_offset < end):
		for i in range(tree.types_count):
			if (tree.pointer_offsets[i] == token_start_offset): ast_expression_commit_pointer(&tree, i)
		for id in range(tree.count):
			if ((tree.op[id] == 'G') && (tree.generic_offset[id] == token_start_offset)): ast_expression_commit_generic(&tree, id)
			if ((tree.op[id] == 't') && (tree.offset[id] == token_start_offset)):
				if (tree.high[id]): get_token_template_chunk()
				int length = template_process_chunk(tree.value[id])
				if (length):
					validate_utf8_literal(length)
					token[length] = 0
				assert1(tree.text_used + length + 1 <= 4096)
				for j in range(length): tree.text[tree.text_used + j] = token[j]
				tree.text[tree.text_used + length] = 0
				tree.value[id] = tree.text_used
				tree.high[id] = length
				tree.text_used = tree.text_used + length + 1
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
	for i in range(tree.types_count):
		if (tree.pointer_offsets[i] == end): ast_expression_commit_pointer(&tree, i)
	emit_expression_ast(&tree, root)
	expression_lhs_readonly = tree.readonly
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
