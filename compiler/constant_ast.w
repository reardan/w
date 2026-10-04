# Constant expressions use bounded, stack-owned operator nodes. The parser
# folds each completed operator before consuming the following operator,
# preserving diagnostic order and normalizing its subtree to a literal.
# Child pointers remain valid only for that fold; no lexer state is needed
# by the visitor, which can also evaluate a retained nested node tree.
struct constant_ast:
	int op
	int value
	constant_ast* left
	constant_ast* right
	int start_offset
	int end_offset


int ast_constants_folded


constant_ast constant_ast_literal(int value, int start, int end):
	constant_ast node
	node.op = 0
	node.value = value
	node.left = 0
	node.right = 0
	node.start_offset = start
	node.end_offset = end
	return node


int constant_ast_fold(constant_ast* node):
	if (node.op == 0): return node.value
	int a = constant_ast_fold(node.left)
	if (node.right == 0):
		if (node.op == '-'): return const_checked(0 - a, (a != 0) && (a == 0 - a))
		if (node.op == '+'): return a
		return ~a
	int b = constant_ast_fold(node.right)
	int r
	if (node.op == '*'):
		r = a * b
		int overflowed = 0
		if (a != 0):
			if (((a == -1) && (b == const_min32())) || ((b == -1) && (a == const_min32()))):
				overflowed = 1
			else: overflowed = r / a != b
		return const_checked(r, overflowed)
	if (node.op == '/'):
		if (b == 0): const_error(c"division by zero in constant expression")
		return const_checked(a / b, (a == const_min32()) && (b == -1))
	if (node.op == '%'):
		if (b == 0): const_error(c"division by zero in constant expression")
		if (b == -1): return 0
		return a % b
	if (node.op == '+'):
		r = a + b
		return const_checked(r, ((a ^ r) & (b ^ r)) < 0)
	if (node.op == '-'):
		r = a - b
		return const_checked(r, ((a ^ b) & (a ^ r)) < 0)
	if ((node.op == '<') || (node.op == '>')):
		if ((b < 0) || (b > 31)): const_error(c"shift count must be 0..31 in a constant expression")
		if (node.op == '>'): return a >> b
		r = a << b
		return const_checked(r, (r >> b) != a)
	if (node.op == '&'): return a & b
	if (node.op == '^'): return a ^ b
	return a | b


constant_ast constant_ast_operator(int op, int start, constant_ast* left, constant_ast* right):
	constant_ast node
	node.op = op
	node.value = 0
	node.left = left
	node.right = right
	node.start_offset = start
	node.end_offset = left.end_offset
	if (right): node.end_offset = right.end_offset
	return constant_ast_literal(constant_ast_fold(&node), start, node.end_offset)
