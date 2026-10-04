import tools.wc2.ast


int wc2_rule(pg_ast_node* node, char* name):
	return (node != 0) && (strcmp(node.name, name) == 0)


pg_ast_node* wc2_part(pg_ast_node* node, char* name):
	if (node == 0): return 0
	for pg_ast_node* child in node.children:
		if (wc2_rule(child, name)): return child
	return 0


int wc2_precedence(char* op):
	if (strcmp(op, c"||") == 0): return 1
	if (strcmp(op, c"&&") == 0): return 2
	if (strcmp(op, c"|") == 0): return 3
	if (strcmp(op, c"^") == 0): return 4
	if (strcmp(op, c"&") == 0): return 5
	if ((strcmp(op, c"==") == 0) || (strcmp(op, c"!=") == 0)): return 6
	if ((strcmp(op, c"<") == 0) || (strcmp(op, c"<=") == 0) || (strcmp(op, c">") == 0) || (strcmp(op, c">=") == 0)): return 7
	if ((strcmp(op, c"<<") == 0) || (strcmp(op, c">>") == 0)): return 8
	if ((strcmp(op, c"+") == 0) || (strcmp(op, c"-") == 0)): return 9
	if ((strcmp(op, c"*") == 0) || (strcmp(op, c"/") == 0) || (strcmp(op, c"%") == 0)): return 10
	return 0


# Keep the spelling, not a host-sized decoded value. Literal width and
# sign extension belong to the target-aware semantic/codegen pass.
int wc2_integer_spelling(char* text):
	int base = 10
	int i = 0
	if ((text[0] == '0') && (text[1] == 'x')):
		base = 16
		i = 2
	else if ((text[0] == '0') && (text[1] == 'b')):
		base = 2
		i = 2
	if (text[i] == 0): return 0
	while (text[i]):
		int digit = text[i] - '0'
		if ((text[i] >= 'a') && (text[i] <= 'f')): digit = text[i] - 'a' + 10
		if ((text[i] >= 'A') && (text[i] <= 'F')): digit = text[i] - 'A' + 10
		if ((digit < 0) || (digit >= base)): return 0
		i = i + 1
	return 1


wc2_node* wc2_lower_expression(wc2_module* m, pg_ast_node* syntax, int scope, int depth);


wc2_node* wc2_join(wc2_module* m, int kind, int scope, pg_token* op, wc2_node* left, wc2_node* right):
	if ((left == 0) || (right == 0)): return 0
	wc2_node* node = wc2_node_new(m, kind, scope, op, op, op.text)
	node.start = left.start
	node.line = left.line
	node.column = left.column
	wc2_add(node, left)
	wc2_add(node, right)
	return node


# w.pg's binary_expr is a flat list. Fold equal precedence to the left;
# recurse only for tighter operators. Logical nodes retain short-circuit
# intent, independently of any later instruction selection.
wc2_node* wc2_binary_tail(wc2_module* m, pg_ast_node* syntax, int scope, wc2_node* left, int minimum, int* index, int depth):
	while (*index < syntax.children.length):
		pg_ast_node* tail = syntax.children[*index]
		pg_token* op = wc2_part(tail, c"binary_op").first_token
		int precedence = wc2_precedence(op.text)
		if (precedence == 0):
			wc2_error(m, op, c"wc2: unsupported binary operator")
			return 0
		if (precedence < minimum): return left
		*index = *index + 1
		wc2_node* right = wc2_lower_expression(m, wc2_part(tail, c"unary_expr"), scope, depth + 1)
		if (right == 0): return 0
		right = wc2_binary_tail(m, syntax, scope, right, precedence + 1, index, depth + 1)
		int kind = wc2_binary_kind
		if (precedence <= 2): kind = wc2_logical_kind
		left = wc2_join(m, kind, scope, op, left, right)
		if (left == 0): return 0
	return left


void wc2_lower_arguments(wc2_module* m, pg_ast_node* syntax, int scope, wc2_node* call, int depth):
	if (wc2_rule(syntax, c"call_arg")):
		if (syntax.children.length != 1):
			wc2_error(m, syntax.first_token, c"wc2: named arguments are not supported yet")
			return
		wc2_add(call, wc2_lower_expression(m, syntax.children[0], scope, depth + 1))
		return
	for pg_ast_node* child in syntax.children:
		if (wc2_rule(child, c"call_arg") || wc2_rule(child, c"arg_tail")):
			wc2_lower_arguments(m, child, scope, call, depth + 1)


wc2_node* wc2_lower_expression(wc2_module* m, pg_ast_node* syntax, int scope, int depth):
	if ((syntax == 0) || (syntax.first_token == 0)): return 0
	pg_token* first = syntax.first_token
	pg_token* last = syntax.last_token
	if (depth > 200):
		wc2_error(m, first, c"wc2: expression nesting limit exceeded")
		return 0
	# The validation grammar allows newlines where the compiler does not.
	# Fail explicitly until continuation-sensitive lowering is implemented.
	if (first.line != last.line):
		wc2_error(m, first, c"wc2: multiline expressions are not supported yet")
		return 0
	if (wc2_rule(syntax, c"NUMBER")):
		if (wc2_integer_spelling(first.text) == 0):
			wc2_error(m, first, c"wc2: expected an integer literal")
			return 0
		wc2_node* literal = wc2_node_new(m, wc2_integer_kind, scope, first, last, first.text)
		literal.type_id = wc2_integer_literal_type
		return literal
	if (wc2_rule(syntax, c"name_token")):
		int kind = wc2_name_kind
		int type_id = wc2_unresolved_type
		if ((strcmp(first.text, c"true") == 0) || (strcmp(first.text, c"false") == 0)):
			kind = wc2_integer_kind
			type_id = wc2_bool_type
		wc2_node* name = wc2_node_new(m, kind, scope, first, last, first.text)
		name.type_id = type_id
		return name
	if (wc2_rule(syntax, c"grouped_expr") || wc2_rule(syntax, c"paren_expression_opt")):
		wc2_node* grouped = wc2_lower_expression(m, wc2_part(syntax, c"expression"), scope, depth + 1)
		if (grouped != 0):
			grouped.start = first.offset
			grouped.end = last.offset + last.length
			grouped.line = first.line
			grouped.column = first.column
		return grouped
	if (wc2_rule(syntax, c"binary_expr")):
		wc2_node* left = wc2_lower_expression(m, syntax.children[0], scope, depth + 1)
		if (left == 0): return 0
		int index = 1
		return wc2_binary_tail(m, syntax, scope, left, 1, &index, depth + 1)
	if (wc2_rule(syntax, c"assignment")):
		wc2_node* left = wc2_lower_expression(m, syntax.children[0], scope, depth + 1)
		for i in range(1, syntax.children.length):
			pg_ast_node* tail = syntax.children[i]
			pg_token* op = wc2_part(tail, c"assign_op").first_token
			if (left == 0): return 0
			if ((left.kind != wc2_name_kind) && (left.kind != wc2_member_kind)):
				wc2_error(m, op, c"wc2: assignment requires a variable or field target")
				return 0
			wc2_node* right = wc2_lower_expression(m, wc2_part(tail, c"assignment"), scope, depth + 1)
			left = wc2_join(m, wc2_assignment_kind, scope, op, left, right)
		return left
	if (wc2_rule(syntax, c"unary_expr") && (syntax.children.length == 2)):
		char* op = first.text
		if ((strcmp(op, c"+") != 0) && (strcmp(op, c"-") != 0) && (strcmp(op, c"!") != 0) && (strcmp(op, c"~") != 0)):
			wc2_error(m, first, c"wc2: unsupported unary operator")
			return 0
		wc2_node* operand = wc2_lower_expression(m, syntax.children[1], scope, depth + 1)
		if (operand == 0): return 0
		wc2_node* unary = wc2_node_new(m, wc2_unary_kind, scope, first, last, op)
		wc2_add(unary, operand)
		return unary
	if (wc2_rule(syntax, c"postfix_expr")):
		wc2_node* value = wc2_lower_expression(m, syntax.children[0], scope, depth + 1)
		for i in range(1, syntax.children.length):
			pg_ast_node* tail = syntax.children[i]
			pg_ast_node* args = wc2_part(tail, c"arg_list")
			if (strcmp(tail.first_token.text, c".") == 0):
				if (value == 0): return 0
				wc2_node* member = wc2_node_new(m, wc2_member_kind, scope, first, tail.last_token, tail.last_token.text)
				wc2_add(member, value)
				value = member
				continue
			if (args == 0):
				wc2_error(m, tail.first_token, c"wc2: only calls are supported as postfix expressions")
				return 0
			if (value == 0): return 0
			wc2_node* call = wc2_node_new(m, wc2_call_kind, scope, first, tail.last_token, c"")
			wc2_add(call, value)
			wc2_lower_arguments(m, args, scope, call, depth + 1)
			value = call
		return value
	if (wc2_rule(syntax, c"expression") || wc2_rule(syntax, c"expression_opt") || wc2_rule(syntax, c"primary_expr") || wc2_rule(syntax, c"unary_expr")):
		return wc2_lower_expression(m, syntax.children[0], scope, depth + 1)
	wc2_error(m, first, c"wc2: unsupported expression")
	return 0
