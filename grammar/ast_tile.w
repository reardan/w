# A restricted device region is recorded in full before analysis or emission.
# This parser deliberately never calls statement(), expression(), or a backend
# helper: those entry points retain incremental emission dependencies.

tile_node* tile_node_new(int kind):
	tile_node* node = cast(tile_node*, tile_owned_zero(sizeof(tile_node)))
	node.kind = kind
	node.retained_id = -1
	node.source_file = retained_intern(filename)
	node.type = -1
	node.line = diag_token_line
	node.column = diag_token_column
	node.start = token_start_offset
	node.end = token_start_offset + strlen(token)
	return node


tile_binding* tile_binding_new(tile_program* program, char* name, int kind, int type):
	tile_binding* binding = cast(tile_binding*, tile_owned_zero(sizeof(tile_binding)))
	binding.id = program.binding_count
	program.binding_count = program.binding_count + 1
	binding.name = retained_text_copy(name, strlen(name))
	binding.kind = kind
	binding.type = type
	binding.declared_type = type
	binding.host_symbol = -1
	binding.capture_slot = -1
	binding.scope = program.scope
	binding.active = 1
	binding.storage_slot = -1
	if (program.bindings_tail == 0): program.bindings = binding
	else: program.bindings_tail.next = binding
	program.bindings_tail = binding
	return binding


tile_binding* tile_find_binding(tile_program* program, char* name):
	tile_binding* found = 0
	tile_binding* binding = program.bindings
	while (binding != 0):
		if (binding.active && (strcmp(binding.name, name) == 0)): found = binding
		binding = binding.next
	return found


void tile_scope_end(tile_program* program):
	tile_binding* binding = program.bindings
	while (binding != 0):
		if ((binding.kind != tile_binding_capture) && (binding.scope == program.scope)): binding.active = 0
		binding = binding.next
	program.scope = program.scope - 1


tile_binding* tile_capture(tile_program* program, tile_node* node):
	char* name = node.name
	int symbol = sym_lookup(name)
	if (symbol < 0):
		line_number = node.line - 1
		column_number = node.column - 1
		diag_token_line = node.line
		diag_token_column = node.column
		token_start_offset = node.start
		tokenizer_set_token_text(name, strlen(name))
		sym_not_found_error(name)
	if (load_int(table + symbol + 10) == 2): tile_error_at(node, c"tile bodies cannot call host functions")
	char scope = table[symbol + 1]
	if ((scope != 'L') && (scope != 'A')): tile_error_at(node, c"tile captures must be enclosing local variables or parameters")
	int type = load_int(table + symbol + 6)
	if (program.capture_count >= 32): tile_error_at(node, c"too many tile captures")
	tile_binding* binding = tile_binding_new(program, name, tile_binding_capture, type)
	binding.host_symbol = symbol
	binding.capture_slot = program.capture_count
	binding.scope = 0
	binding.initialized = 1
	program.capture_count = program.capture_count + 1
	return binding


int tile_decimal():
	int value = 0
	int length = strlen(token)
	if (length == 0): error(c"expected tile integer literal")
	for i in range(length):
		int digit = token[i] - '0'
		if ((digit < 0) || (digit > 9)): error(c"tile literals must be decimal integers")
		if ((value > 214748364) || ((value == 214748364) && (digit > 7))): error(c"tile integer literal is too large")
		value = value * 10 + digit
	get_token()
	return value


int tile_binary_op():
	if (peek(c"+")): return '+'
	if (peek(c"-")): return '-'
	if (peek(c"*")): return '*'
	if (peek(c"/")): return '/'
	if (peek(c"%")): return '%'
	if (peek(c"<")): return '<'
	if (peek(c">")): return '>'
	if (peek(c"==")): return tile_op_eq
	if (peek(c"!=")): return tile_op_ne
	if (peek(c"<=")): return tile_op_le
	if (peek(c">=")): return tile_op_ge
	if (peek(c"&&")): return tile_op_and
	if (peek(c"||")): return tile_op_or
	return 0


int tile_precedence(int op):
	if (op == tile_op_or): return 1
	if (op == tile_op_and): return 2
	if ((op == tile_op_eq) || (op == tile_op_ne)): return 3
	if ((op == '<') || (op == '>') || (op == tile_op_le) || (op == tile_op_ge)): return 4
	if ((op == '+') || (op == '-')): return 5
	if ((op == '*') || (op == '/') || (op == '%')): return 6
	return 0


tile_node* tile_parse_expression(tile_program* program, int minimum, int depth);


tile_node* tile_parse_primary(tile_program* program, int depth):
	if (depth > 128): error(c"tile expression nesting too deep")
	tile_node* node = 0
	if (peek(c"-") || peek(c"+") || peek(c"!")):
		node = tile_node_new(tile_unary)
		node.op = token[0]
		get_token()
		node.left = tile_parse_primary(program, depth + 1)
	else if (accept(c"(")):
		node = tile_parse_expression(program, 1, depth + 1)
		expect(c")")
	else if ((token[0] >= '0') && (token[0] <= '9')):
		node = tile_node_new(tile_literal)
		if (token_is_float_literal()):
			node.type = float32_type
			node.value = float32_bits_from_token()
			get_token()
		else: node.value = tile_decimal()
	else if (peek(c"true") || peek(c"false")):
		node = tile_node_new(tile_literal)
		node.value = peek(c"true")
		get_token()
	else if (is_ident_start_byte(token[0])):
		int kind = 0
		if (peek(c"tile_load")): kind = tile_load
		else if (peek(c"tile_store")): kind = tile_store
		else if (peek(c"dot")): kind = tile_dot
		else if (peek(c"tile_program_id")): kind = tile_program_id
		else if (peek(c"tile_zero")): kind = tile_zero
		node = tile_node_new(tile_reference)
		node.name = retained_text_copy(token, strlen(token))
		get_token()
		if (kind && peek(c"(")):
			node.kind = kind
			get_token()
			tile_node* tail = 0
			if (peek(c")") == 0):
				while (1):
					tile_node* arg = tile_parse_expression(program, 1, depth + 1)
					if (tail == 0): node.args = arg
					else: tail.next = arg
					tail = arg
					if (accept(c",") == 0): break
			expect(c")")
		else:
			if (peek(c"(")): tile_error_at(node, c"tile bodies support only tile builtins, not function calls")
			node.binding = tile_find_binding(program, node.name)
			if (node.binding == 0): node.binding = tile_capture(program, node)
	else: error(c"expected tile expression")
	while ((token_newline == 0) && accept(c"[")):
		tile_node* indexed = tile_node_new(tile_index)
		indexed.left = node
		indexed.right = tile_parse_expression(program, 1, depth + 1)
		expect(c"]")
		node = indexed
	node.end = token_start_offset
	return node


tile_node* tile_parse_expression(tile_program* program, int minimum, int depth):
	tile_node* left = tile_parse_primary(program, depth)
	while (token_newline == 0):
		int op = tile_binary_op()
		int precedence = tile_precedence(op)
		if (precedence < minimum): break
		tile_node* node = tile_node_new(tile_binary)
		node.op = op
		node.name = retained_text_copy(token, strlen(token))
		get_token()
		node.left = left
		node.right = tile_parse_expression(program, precedence + 1, depth + 1)
		node.end = token_start_offset
		left = node
	return left


tile_node* tile_parse_statement(tile_program* program, int depth);


tile_node* tile_parse_block(tile_program* program, int owner_indent, int depth):
	if (depth > 100): error(c"tile statement nesting too deep")
	int brace = accept(c"{")
	if (brace == 0): expect(c":")
	int single = (brace == 0) && (token_newline == 0)
	if ((brace == 0) && (single == 0) && ((token[0] == 0) || (tab_level <= owner_indent))): error(c"expected indented tile body")
	int indent = tab_level
	program.scope = program.scope + 1
	tile_node* first = 0
	tile_node* tail = 0
	while (token[0] != 0):
		if (brace && peek(c"}")): break
		if ((brace == 0) && (tab_level < indent)): break
		if ((brace == 0) && (single == 0) && (tab_level != indent)): error(c"unexpected indentation in tile body")
		tile_node* node = tile_parse_statement(program, depth + 1)
		if (tail == 0): first = node
		else: tail.next = node
		tail = node
		if (single): break
	if (brace): expect(c"}")
	tile_scope_end(program)
	return first


void tile_statement_end():
	if (token_newline || (token[0] == 0) || peek(c"}")): return
	error(c"unexpected token after tile statement")


int tile_inferred_start():
	if (is_ident_start_byte(token[0]) == 0): return 0
	char* saved = generic_reparse_save()
	get_token()
	int inferred = (token_newline == 0) && peek(c":=")
	getchar_seek(file, load_ptr(saved + 7 * __word_size__))
	generic_reparse_restore(saved)
	return inferred


tile_node* tile_parse_statement(tile_program* program, int depth):
	int indent = tab_level
	int inferred = tile_inferred_start()
	tile_node* node = 0
	if (peek(c"if")):
		node = tile_node_new(tile_if)
		get_token()
		node.left = tile_parse_expression(program, 1, 0)
		node.body = tile_parse_block(program, indent, depth)
		if ((tab_level == indent) && accept(c"else")):
			node.otherwise = tile_parse_block(program, indent, depth)
	else if (peek(c"for")):
		node = tile_node_new(tile_for)
		get_token()
		accept(c"int")
		if (is_ident_start_byte(token[0]) == 0): error(c"expected tile loop variable")
		char* name = retained_text_copy(token, strlen(token))
		get_token()
		expect(c"in")
		expect(c"range")
		expect(c"(")
		tile_node* first = tile_parse_expression(program, 1, 0)
		if (accept(c",")):
			node.left = first
			node.right = tile_parse_expression(program, 1, 0)
		else:
			node.left = tile_node_new(tile_literal)
			node.left.value = 0
			node.right = first
		expect(c")")
		program.scope = program.scope + 1
		node.binding = tile_binding_new(program, name, tile_binding_loop, type_lookup(c"int"))
		node.body = tile_parse_block(program, indent, depth)
		tile_scope_end(program)
	else if (peek(c"int") || peek(c"float32") || inferred):
		node = tile_node_new(tile_declare)
		int declared = -1
		if (inferred == 0):
			declared = type_lookup(token)
			get_token()
		if (is_ident_start_byte(token[0]) == 0): error(c"expected tile local name")
		char* name = retained_text_copy(token, strlen(token))
		tile_binding* old = tile_find_binding(program, name)
		if (old != 0):
			if ((old.kind != tile_binding_capture) && (old.scope == program.scope)): error(c"duplicate tile local")
		get_token()
		if (inferred): expect(c":=")
		else: expect(c"=")
		node.left = tile_parse_expression(program, 1, 0)
		node.binding = tile_binding_new(program, name, tile_binding_local, declared)
		node.type = declared
		tile_statement_end()
	else:
		tile_node* left = tile_parse_expression(program, 1, 0)
		if (left.kind == tile_store):
			node = left
		else:
			node = tile_node_new(tile_assign)
			node.left = left
			if (accept(c"=")): node.op = 0
			else if (accept(c"+=")): node.op = '+'
			else if (accept(c"-=")): node.op = '-'
			else if (accept(c"*=")): node.op = '*'
			else: error(c"expected tile assignment or tile_store")
			node.right = tile_parse_expression(program, 1, 0)
		tile_statement_end()
	node.end = token_start_offset
	return node


# Parsing a flat operator chain does not recurse, but later syntax walkers
# do. Bound the owned tree before entering any recursive consumer, including
# the streaming frontend where query-visible records are disabled.
void tile_validate_depth(tile_node* first, int depth):
	tile_node* node = first
	while (node != 0):
		if (depth > 128): tile_error_at(node, c"tile expression or body tree nesting too deep")
		tile_validate_depth(node.left, depth + 1)
		tile_validate_depth(node.right, depth + 1)
		tile_validate_depth(node.third, depth + 1)
		tile_validate_depth(node.args, depth + 1)
		tile_validate_depth(node.body, depth + 1)
		tile_validate_depth(node.otherwise, depth + 1)
		node = node.next


# Query-visible records point into the same retained ownership hierarchy as
# the complete syntax payload. Expression nodes are distinct from ordinary
# retained expression operands, whose columnar encoding is backend specific.
void tile_retain_nodes(tile_program* program, tile_node* first, int parent);


void tile_retain_one(tile_program* program, tile_node* node, int parent):
	if (node == 0): return
	int kind = retained_tile_expression
	char* name = node.name
	if (name == 0): name = c"tile expression"
	if (node.kind == tile_declare): name = c"tile local"
	else if (node.kind == tile_assign): name = c"tile assignment"
	else if (node.kind == tile_if): name = c"tile if"
	else if (node.kind == tile_for): name = c"tile for"
	if ((node.kind >= tile_declare) && (node.kind <= tile_store)): kind = retained_tile_statement
	int source = retained_source_id(program.source_file)
	int id = retained_add(kind, parent, source, node.start, node.line, node.column, name)
	node.retained_id = id
	retained_record_at(id).end = node.end
	tile_retain_one(program, node.left, id)
	tile_retain_one(program, node.right, id)
	tile_retain_one(program, node.third, id)
	tile_retain_nodes(program, node.args, id)
	tile_retain_nodes(program, node.body, id)
	tile_retain_nodes(program, node.otherwise, id)


void tile_retain_nodes(tile_program* program, tile_node* first, int parent):
	tile_node* node = first
	while (node != 0):
		tile_retain_one(program, node, parent)
		node = node.next


# Public record-only entry point. Tests can inspect the complete region here
# and assert that host bytes, PTX buffers and backend stacks are untouched.
tile_program* tile_parse_program():
	tile_program* program = cast(tile_program*, tile_owned_zero(sizeof(tile_program)))
	program.capture_count = 1
	program.retained_owner = retained_parent
	program.source_file = retained_text_copy(filename, strlen(filename))
	int indent = tab_level
	expect(c"gpu")
	expect(c"[")
	program.width = tile_decimal()
	expect(c"]")
	expect(c"for")
	if (is_ident_start_byte(token[0]) == 0): error(c"expected tile index name")
	char* name = retained_text_copy(token, strlen(token))
	get_token()
	expect(c"in")
	expect(c"range")
	expect(c"(")
	program.bound = tile_parse_expression(program, 1, 0)
	expect(c")")
	program.tile_binding = tile_binding_new(program, name, tile_binding_index, type_lookup(c"int"))
	program.body = tile_parse_block(program, indent, 0)
	tile_validate_depth(program.bound, 0)
	tile_validate_depth(program.body, 0)
	char* kernel = gpu_for_kernel_name()
	program.kernel_name = retained_text_copy(kernel, strlen(kernel))
	free(kernel)
	if (program.retained_owner >= 0):
		retained_record_at(program.retained_owner).tile_payload = cast(char*, program)
		tile_retain_one(program, program.bound, program.retained_owner)
		tile_retain_nodes(program, program.body, program.retained_owner)
	return program


void tile_analyze(tile_program* program);
void tile_emit_program(tile_program* program);


# The same record/analyze/emit route is used by both front ends. Contextual
# lookahead does not reparse the body and does not change expression syntax.
int ast_tile_statement():
	if (peek(c"gpu") == 0): return 0
	if ((sym_probe(c"gpu") >= 0) || (type_lookup(c"gpu") >= 0)): return 0
	char* save = generic_reparse_save()
	get_token()
	int is_tile = peek(c"[")
	getchar_seek(file, load_ptr(save + 7 * __word_size__))
	generic_reparse_restore(save)
	if (is_tile == 0): return 0
	if (target_isa == 3): error(c"tile programs cannot nest inside gpu code")
	gpu_target_check()
	if (sym_lookup(c"__w_gpu_launch_tiles") < 0): error(c"tile programs require 'import lib.cuda'")
	tile_program* program = tile_parse_program()
	tile_analyze(program)
	tile_emit_program(program)
	return 1
