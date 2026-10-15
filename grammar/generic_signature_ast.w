int safe_qualifier_ahead();  # grammar/type_name.w

# Unbound generic signature syntax. Capture never looks up or interns a
# type: definitions can mention parameters and types declared later.
# Unsupported shapes leave the ordinary instantiation parser in charge.
struct generic_type_ast:
	char* name
	int stars
	int application  # 0 named/builtin, 1 generic struct, 2 slice
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
	node.application = 0
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


generic_type_ast* generic_type_ast_slice(generic_type_ast* element):
	generic_type_ast* node = generic_type_ast_new(c"", 0)
	node.application = 2
	node.first = element
	return node


# Track consumed brackets so a failed shape capture can finish the
# original balanced header scan without rewinding or lexing twice.
void generic_type_ast_advance(int* brackets):
	if (peek(c"[")): *brackets = *brackets + 1
	if (peek(c"]")): *brackets = *brackets - 1
	get_token()


int generic_type_ast_accept(int* brackets, char* spelling):
	if (peek(spelling) == 0): return 0
	generic_type_ast_advance(brackets)
	return 1


generic_type_ast* generic_type_ast_capture_at(int depth, int* brackets, int with_suffix):
	if (depth > 32): return 0
	if (is_ident_start_byte(token[0]) == 0): return 0
	if (peek(c"const") || peek(c"gpu") || safe_qualifier_ahead()): return 0
	int container = 0
	if (nextc == '['):
		container = 3
		if (peek(c"map")): container = 2
		if (peek(c"set") || peek(c"list")): container = 1
	generic_type_ast* node = generic_type_ast_new(token, 0)
	generic_type_ast_advance(brackets)
	if (container):
		if (generic_type_ast_accept(brackets, c"[") == 0):
			generic_type_ast_free(node)
			return 0
		if ((container == 3) && generic_type_ast_accept(brackets, c"]")):
			node = generic_type_ast_slice(node)
		else:
			node.first = generic_type_ast_capture_at(depth + 1, brackets, 1)
			if (node.first == 0):
				generic_type_ast_free(node)
				return 0
			if (container == 2):
				if (generic_type_ast_accept(brackets, c",") == 0):
					generic_type_ast_free(node)
					return 0
				node.second = generic_type_ast_capture_at(depth + 1, brackets, 1)
				if (node.second == 0):
					generic_type_ast_free(node)
					return 0
			if (container == 3):
				node.application = 1
				generic_type_ast* tail = node.first
				int count = 1
				while (generic_type_ast_accept(brackets, c",")):
					if (count == 8):
						generic_type_ast_free(node)
						return 0
					tail.next = generic_type_ast_capture_at(depth + 1, brackets, 1)
					if (tail.next == 0):
						generic_type_ast_free(node)
						return 0
					tail = tail.next
					count = count + 1
			if (generic_type_ast_accept(brackets, c"]") == 0):
				generic_type_ast_free(node)
				return 0
	if (node.application != 2):
		while (generic_type_ast_accept(brackets, c"*")): node.stars = node.stars + 1
	while (with_suffix && generic_type_ast_accept(brackets, c"[")):
		if (generic_type_ast_accept(brackets, c"]") == 0):
			generic_type_ast_free(node)
			return 0
		node = generic_type_ast_slice(node)
	return node


generic_type_ast* generic_type_ast_capture(int depth):
	int brackets = 0
	return generic_type_ast_capture_at(depth, &brackets, 1)


# The declaration lookahead only skips the first balanced application
# and trailing stars; keep that boundary even for unsupported shapes.
generic_type_ast* generic_type_ast_capture_return():
	int brackets = 0
	generic_type_ast* result = generic_type_ast_capture_at(0, &brackets, 0)
	if (result == 0):
		while ((brackets > 0) && (token[0] != 0)): generic_type_ast_advance(&brackets)
	while (peek(c"*")):
		generic_type_ast_free(result)
		result = 0
		get_token()
	return result


# Current token is '('. Takes ownership of the captured return shape;
# a null shape leaves the ordinary instantiation parser in charge.
generic_signature_ast* generic_signature_ast_capture_result(generic_type_ast* result):
	if (result == 0): return 0
	if (accept(c"(") == 0):
		generic_type_ast_free(result)
		return 0
	generic_signature_ast* signature = new generic_signature_ast
	signature.result = result
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


generic_signature_ast* generic_signature_ast_capture(char* result_name, int stars):
	if (result_name == 0): return 0
	return generic_signature_ast_capture_result(generic_type_ast_new(result_name, stars))
