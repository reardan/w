# Unbound generic signature syntax. Capture never looks up or interns a
# type: definitions can mention parameters and types declared later.
# Unsupported shapes leave the ordinary instantiation parser in charge.
struct generic_type_ast:
	char* name
	int stars
	generic_type_ast* first
	generic_type_ast* second
	generic_type_ast* next


struct generic_signature_ast:
	generic_type_ast* result
	generic_type_ast* parameters
	int count


generic_type_ast* generic_type_ast_new(char* name, int stars):
	generic_type_ast* node = new generic_type_ast
	node.name = strclone(name)
	node.stars = stars
	node.first = 0
	node.second = 0
	node.next = 0
	return node


void generic_type_ast_free(generic_type_ast* node):
	if (node == 0): return
	generic_type_ast_free(node.first)
	generic_type_ast_free(node.second)
	generic_type_ast_free(node.next)
	free(node.name)
	free(cast(char*, node))


void generic_signature_ast_free(generic_signature_ast* signature):
	if (signature == 0): return
	generic_type_ast_free(signature.result)
	generic_type_ast_free(signature.parameters)
	free(cast(char*, signature))


generic_type_ast* generic_type_ast_capture(int depth):
	if (depth > 32): return 0
	if (is_ident_start_byte(token[0]) == 0): return 0
	if (peek(c"const") || peek(c"gpu")): return 0
	int container = 0
	if (nextc == '['):
		if (peek(c"map")): container = 2
		if (peek(c"set") || peek(c"list")): container = 1
		if (container == 0): return 0
	generic_type_ast* node = generic_type_ast_new(token, 0)
	get_token()
	if (container):
		if (accept(c"[") == 0):
			generic_type_ast_free(node)
			return 0
		node.first = generic_type_ast_capture(depth + 1)
		if (node.first == 0):
			generic_type_ast_free(node)
			return 0
		if (container == 2):
			if (accept(c",") == 0):
				generic_type_ast_free(node)
				return 0
			node.second = generic_type_ast_capture(depth + 1)
			if (node.second == 0):
				generic_type_ast_free(node)
				return 0
		if (accept(c"]") == 0):
			generic_type_ast_free(node)
			return 0
	while (accept(c"*")): node.stars = node.stars + 1
	return node


# Current token is '('. Return spelling was consumed by the declaration
# scan; null means a complex return type which it only skipped.
generic_signature_ast* generic_signature_ast_capture(char* result_name, int stars):
	if (result_name == 0): return 0
	if (accept(c"(") == 0): return 0
	generic_signature_ast* signature = new generic_signature_ast
	signature.result = generic_type_ast_new(result_name, stars)
	signature.parameters = 0
	signature.count = 0
	generic_type_ast* tail = 0
	while (peek(c")") == 0):
		if (signature.count == 128):
			generic_signature_ast_free(signature)
			return 0
		generic_type_ast* parameter = generic_type_ast_capture(0)
		if (parameter == 0):
			generic_signature_ast_free(signature)
			return 0
		if (tail == 0): signature.parameters = parameter
		else: tail.next = parameter
		tail = parameter
		signature.count = signature.count + 1
		if (is_ident_start_byte(token[0])): get_token()
		if (peek(c")")): break
		if (accept(c",") == 0):
			generic_signature_ast_free(signature)
			return 0
	get_token()
	return signature
