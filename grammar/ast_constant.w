# Build and immediately fold constant operator nodes, so errors occur at
# the same token as the streaming evaluator. Normalized child nodes are
# local values; even a long flat expression needs no arena or allocation.
constant_ast ast_const_or();


constant_ast ast_const_primary():
	int start = token_start_offset
	int value = 0
	if (accept(c"(")):
		const_paren_depth = const_paren_depth + 1
		constant_ast group = ast_const_or()
		value = group.value
		const_paren_depth = const_paren_depth - 1
		if (peek(c")") == 0): const_error(c"')' expected in constant expression")
	else if (accept(c"sizeof")):
		expect(c"(")
		value = type_get_size(type_name())
		if (peek(c")") == 0): const_error(c"')' expected after sizeof type")
	else if (peek(c"__word_size__")): value = word_size
	else if (peek(c"true")): value = 1
	else if (peek(c"false")): value = 0
	# char literal e.g. 'c', '\n' or '\x41'; grammar/string_literal.w
	# decodes and validates the token
	else if (token[0] == 39): value = char_literal_value()
	else if ((token[0] == '0') && ((token[1] == 'x') || (token[1] == 'b'))):
		int_literal_width_check()
		if (token[1] == 'x'): value = from_hex(token + 2)
		else:
			int i = 2
			while (token[i]):
				value = (value << 1) + token[i] - '0'
				i = i + 1
		value = int_literal_wrap32(value)
	else if (('0' <= token[0]) && (token[0] <= '9')):
		int_literal_decimal_check()
		value = int_literal_wrap32(atoi(token))
	else: value = const_symbol_value(sym_lookup(token))
	int end = token_start_offset + token_i
	get_token()
	return constant_ast_literal(value, start, end)


constant_ast ast_const_unary():
	int start = token_start_offset
	int op = 0
	if (accept(c"-")): op = '-'
	else if (accept(c"+")): op = '+'
	else if (accept(c"~")): op = '~'
	if (op):
		constant_ast child = ast_const_unary()
		return constant_ast_operator(op, start, &child, 0)
	return ast_const_primary()


constant_ast ast_const_mul():
	constant_ast a = ast_const_unary()
	while (1):
		int op = 0
		if (const_binary(c"*")): op = '*'
		else if (const_binary(c"/")): op = '/'
		else if (const_binary(c"%")): op = '%'
		else: return a
		constant_ast b = ast_const_unary()
		a = constant_ast_operator(op, a.start_offset, &a, &b)


constant_ast ast_const_add():
	constant_ast a = ast_const_mul()
	while (1):
		int op = 0
		if (const_binary(c"+")): op = '+'
		else if (const_binary(c"-")): op = '-'
		else: return a
		constant_ast b = ast_const_mul()
		a = constant_ast_operator(op, a.start_offset, &a, &b)


constant_ast ast_const_shift():
	constant_ast a = ast_const_add()
	while (1):
		int op = 0
		if (const_binary(c"<<")): op = '<'
		else if (const_binary(c">>")): op = '>'
		else: return a
		constant_ast b = ast_const_add()
		a = constant_ast_operator(op, a.start_offset, &a, &b)


constant_ast ast_const_and():
	constant_ast a = ast_const_shift()
	while (1):
		int op = 0
		if (const_binary(c"&")): op = '&'
		else: return a
		constant_ast b = ast_const_shift()
		a = constant_ast_operator(op, a.start_offset, &a, &b)


constant_ast ast_const_xor():
	constant_ast a = ast_const_and()
	while (1):
		int op = 0
		if (const_binary(c"^")): op = '^'
		else: return a
		constant_ast b = ast_const_and()
		a = constant_ast_operator(op, a.start_offset, &a, &b)


constant_ast ast_const_or():
	constant_ast a = ast_const_xor()
	while (1):
		int op = 0
		if (const_binary(c"|")): op = '|'
		else: return a
		constant_ast b = ast_const_xor()
		a = constant_ast_operator(op, a.start_offset, &a, &b)
