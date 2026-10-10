# Record-only entry for main AST whole functions. No tile grammar, symbol
# declarations, stack allocation, or backend calls participate in this parse.
function_node_ast* function_record_node(int kind):
	function_node_ast* node = cast(function_node_ast*, function_record_alloc(sizeof(function_node_ast)))
	node.kind = kind
	node.line = diag_token_line
	node.column = diag_token_column
	node.start = token_start_offset
	node.retained_id = -1
	return node

function_local_ast* function_record_lookup(function_body_ast* body, char* name):
	function_local_ast* found = 0
	function_local_ast* binding = body.bindings
	while (binding != 0):
		if (binding.active && (strcmp(binding.name, name) == 0)): found = binding
		binding = binding.next
	return found

function_local_ast* function_record_binding(function_body_ast* body, char* name, int parameter):
	function_local_ast* previous = function_record_lookup(body, name)
	if ((previous != 0) && (previous.scope == body.scope)): error(c"duplicate recorded scalar binding")
	function_local_ast* binding = cast(function_local_ast*, function_record_alloc(sizeof(function_local_ast)))
	binding.name = retained_text_copy(name, strlen(name))
	binding.scope = body.scope
	binding.active = 1
	binding.parameter = parameter
	if (parameter):
		body.parameter_count = body.parameter_count + 1
		binding.id = body.parameter_count
	else:
		binding.id = body.local_count
		body.local_count = body.local_count + 1
	if (body.bindings_tail == 0): body.bindings = binding
	else: body.bindings_tail.next = binding
	body.bindings_tail = binding
	return binding

int function_record_op():
	if (peek(c"+")): return '+'
	if (peek(c"-")): return '-'
	if (peek(c"*")): return '*'
	if (peek(c"/")): return '/'
	if (peek(c"%")): return '%'
	if (peek(c"<")): return '<'
	if (peek(c">")): return '>'
	if (peek(c"==")): return function_record_eq
	if (peek(c"!=")): return function_record_ne
	if (peek(c"<=")): return function_record_le
	if (peek(c">=")): return function_record_ge
	if (peek(c"&&")): return function_record_and
	if (peek(c"||")): return function_record_or
	return 0

int function_record_precedence(int op):
	if (op == function_record_or): return 1
	if (op == function_record_and): return 2
	if ((op == function_record_eq) || (op == function_record_ne)): return 3
	if ((op == '<') || (op == '>') || (op == function_record_le) || (op == function_record_ge)): return 4
	if ((op == '+') || (op == '-')): return 5
	if ((op == '*') || (op == '/') || (op == '%')): return 6
	return 0

function_node_ast* function_record_expression(function_body_ast* body, int minimum, int depth);

function_node_ast* function_record_primary(function_body_ast* body, int depth):
	if (depth > 100): error(c"recorded scalar expression nesting too deep")
	function_node_ast* node = function_record_node(function_record_literal)
	if (peek(c"+") || peek(c"-") || peek(c"!")):
		node.kind = function_record_unary
		node.op = token[0]
		get_token()
		node.left = function_record_primary(body, depth + 1)
	else if (accept(c"(")):
		node = function_record_expression(body, 1, depth + 1)
		expect(c")")
	else if (peek(c"true") || peek(c"false")):
		node.value = peek(c"true")
		get_token()
	else if ((token[0] >= '0') && (token[0] <= '9')):
		# Decimal constants deliberately share W's signed 32-bit spelling
		# limit, even when the generated function uses 64-bit int words.
		int value = 0
		for i in range(strlen(token)):
			int digit = token[i] - '0'
			if ((digit < 0) || (digit > 9)): error(c"recorded scalar literals must be decimal integers")
			if ((value > 214748364) || ((value == 214748364) && (digit > 7))): error(c"recorded scalar literal is too large")
			value = value * 10 + digit
		node.value = value
		get_token()
	else if (is_ident_start_byte(token[0])):
		node.kind = function_record_reference
		node.binding = function_record_lookup(body, token)
		if (node.binding == 0): error(c"unknown recorded scalar binding")
		get_token()
	else: error(c"expected recorded scalar expression")
	node.end = token_start_offset
	return node

function_node_ast* function_record_expression(function_body_ast* body, int minimum, int depth):
	function_node_ast* left = function_record_primary(body, depth)
	while (token_newline == 0):
		int op = function_record_op()
		int precedence = function_record_precedence(op)
		if (precedence < minimum): break
		function_node_ast* node = function_record_node(function_record_binary)
		node.op = op
		get_token()
		node.left = left
		node.right = function_record_expression(body, precedence + 1, depth + 1)
		node.end = token_start_offset
		left = node
	return left

function_node_ast* function_record_statement(function_body_ast* body, int depth);

function_node_ast* function_record_block(function_body_ast* body, int owner_indent, int depth):
	if (depth > 100): error(c"recorded scalar body nesting too deep")
	int brace = accept(c"{")
	if (brace == 0): expect(c":")
	int single = (brace == 0) && (token_newline == 0)
	if ((brace == 0) && (single == 0) && ((token[0] == 0) || (tab_level <= owner_indent))): error(c"expected indented recorded scalar body")
	int indent = tab_level
	body.scope = body.scope + 1
	function_node_ast* first = 0
	function_node_ast* tail = 0
	while (token[0] != 0):
		if (brace && peek(c"}")): break
		if ((brace == 0) && (tab_level < indent)): break
		if ((brace == 0) && (single == 0) && (tab_level != indent)): error(c"unexpected indentation in recorded scalar body")
		function_node_ast* node = function_record_statement(body, depth + 1)
		if (tail == 0): first = node
		else: tail.next = node
		tail = node
		if (single): break
	if (brace): expect(c"}")
	function_local_ast* binding = body.bindings
	while (binding != 0):
		if (binding.scope == body.scope): binding.active = 0
		binding = binding.next
	body.scope = body.scope - 1
	return first

void function_record_terminator():
	if (token_newline || (token[0] == 0) || peek(c"}")): return
	error(c"unsupported syntax after recorded scalar statement")

function_node_ast* function_record_statement(function_body_ast* body, int depth):
	function_node_ast* node = function_record_node(function_record_assign)
	int indent = tab_level
	if (accept(c"if")):
		node.kind = function_record_if
		node.left = function_record_expression(body, 1, 0)
		node.body = function_record_block(body, indent, depth)
		if ((tab_level == indent) && accept(c"else")): node.otherwise = function_record_block(body, indent, depth)
	else if (accept(c"while")):
		node.kind = function_record_while
		node.left = function_record_expression(body, 1, 0)
		node.body = function_record_block(body, indent, depth)
	else if (accept(c"for")):
		node.kind = function_record_for
		expect(c"int")
		if (is_ident_start_byte(token[0]) == 0): error(c"expected recorded scalar loop name")
		char* name = retained_text_copy(token, strlen(token))
		get_token()
		expect(c"in")
		expect(c"range")
		expect(c"(")
		node.right = function_record_expression(body, 1, 0)
		node.left = function_record_node(function_record_literal)
		if (accept(c",")):
			node.left = node.right
			node.right = function_record_expression(body, 1, 0)
		expect(c")")
		body.scope = body.scope + 1
		node.binding = function_record_binding(body, name, 0)
		# An owned anonymous local stores the once-evaluated range bound.
		node.value = body.local_count
		body.local_count = body.local_count + 1
		node.body = function_record_block(body, indent, depth)
		node.binding.active = 0
		body.scope = body.scope - 1
	else if (accept(c"return")):
		node.kind = function_record_return
		node.left = function_record_expression(body, 1, 0)
		function_record_terminator()
	else if (accept(c"int")):
		node.kind = function_record_local
		if (is_ident_start_byte(token[0]) == 0): error(c"expected recorded scalar local name")
		char* name = retained_text_copy(token, strlen(token))
		get_token()
		expect(c"=")
		node.left = function_record_expression(body, 1, 0)
		node.binding = function_record_binding(body, name, 0)
		function_record_terminator()
	else:
		node.binding = function_record_lookup(body, token)
		if (node.binding == 0): error(c"unsupported recorded scalar statement")
		get_token()
		if (peek(c"+=") || peek(c"-=") || peek(c"*=")):
			node.op = token[0]
			get_token()
		else: expect(c"=")
		node.left = function_record_expression(body, 1, 0)
		function_record_terminator()
	node.end = token_start_offset
	return node

# Bound every recursive consumer, including flat left-associative chains.
void function_record_retain(function_body_ast* body, function_node_ast* first, int parent, int depth):
	function_node_ast* node = first
	while (node != 0):
		if (depth > 100): error(c"recorded scalar tree nesting too deep")
		int id = parent
		if (body.retained_id >= 0):
			int kind = retained_statement
			if (node.kind <= function_record_unary): kind = retained_function_expression
			id = retained_add(kind, parent, retained_source_id(body.source_file), node.start, node.line, node.column, c"recorded scalar")
			node.retained_id = id
			retained_record_at(id).end = node.end
		function_record_retain(body, node.left, id, depth + 1)
		function_record_retain(body, node.right, id, depth + 1)
		function_record_retain(body, node.body, id, depth + 1)
		function_record_retain(body, node.otherwise, id, depth + 1)
		node = node.next

# Explicit compiler API for the restricted slice. Ordinary function syntax
# stays in the main AST; unsupported features never invoke an emitter here.
function_ast* ast_record_scalar_function():
	function_ast* recorded = cast(function_ast*, function_record_alloc(sizeof(function_ast)))
	function_body_ast* body = cast(function_body_ast*, function_record_alloc(sizeof(function_body_ast)))
	recorded.owned_body = body
	recorded.kind = ast_function_native
	recorded.binding = -1
	recorded.source_file = -1
	recorded.start_offset = token_start_offset
	body.source_file = retained_text_copy(filename, strlen(filename))
	int indent = tab_level
	int line = diag_token_line
	int column = diag_token_column
	expect(c"int")
	if (is_ident_start_byte(token[0]) == 0): error(c"expected recorded scalar function name")
	recorded.name = retained_text_copy(token, strlen(token))
	get_token()
	expect(c"(")
	if (peek(c")") == 0):
		while (1):
			expect(c"int")
			if (is_ident_start_byte(token[0]) == 0): error(c"expected recorded scalar parameter name")
			function_record_binding(body, token, 1)
			get_token()
			if (accept(c",") == 0): break
	expect(c")")
	body.retained_id = retained_enter(retained_function, body.source_file, recorded.start_offset, line, column, recorded.name)
	body.statements = function_record_block(body, indent, 0)
	recorded.end_offset = token_start_offset
	recorded.argument_words = body.parameter_count
	recorded.parameter_count = body.parameter_count
	function_record_retain(body, body.statements, body.retained_id, 0)
	if (body.retained_id >= 0): retained_record_at(body.retained_id).function_payload = cast(char*, recorded)
	retained_leave(body.retained_id, recorded.end_offset)
	return recorded
