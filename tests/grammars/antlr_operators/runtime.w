import lib.assert
import libs.extras.grammars.matchers
import bin.antlr_operators_matchers
import bin.antlr_operators_parser


char* operator_text(pg_ast_node* node):
	if (node.text != 0): return node.text
	assert_equal(1, node.children.length)
	return operator_text(node.children[0])


int operator_evaluate(pg_ast_node* node):
	if (node.token != 0): return atoi(node.text)
	if (strcmp(node.name, c"expr_primary") == 0):
		if (node.children.length == 3): return operator_evaluate(node.children[1])
		if (node.children.length == 2):
			int value = operator_evaluate(node.children[1])
			if (strcmp(operator_text(node.children[0]), c"-") == 0): return -value
			return value
	assert1(node.children.length > 0)
	int result = operator_evaluate(node.children[0])
	int i = 1
	while (i < node.children.length):
		pg_ast_node* tail = node.children[i]
		assert_equal(2, tail.children.length)
		char* op = operator_text(tail.children[0])
		int rhs = operator_evaluate(tail.children[1])
		if (strcmp(op, c"+") == 0): result = result + rhs
		else if (strcmp(op, c"-") == 0): result = result - rhs
		else if (strcmp(op, c"*") == 0): result = result * rhs
		else if ((strcmp(op, c"/") == 0) || (strcmp(op, c"//") == 0)): result = result / rhs
		else if (strcmp(op, c"%") == 0): result = result % rhs
		else:
			assert_strings_equal(c"^", op)
			assert1(rhs >= 0)
			int power = 1
			while (rhs > 0):
				power = power * result
				rhs = rhs - 1
			result = power
		i = i + 1
	return result


void operator_accept(char* source, int expected):
	pg_diagnostics* diagnostics = pg_diagnostics_new()
	pg_ast_node* root = operators_parse(source, c"expression.txt", diagnostics)
	assert1(root != 0)
	assert_equal(0, pg_diagnostics_count(diagnostics))
	assert_strings_equal(c"expr", root.children[0].name)
	assert_strings_equal(c"expr_prec2", root.children[0].children[0].name)
	assert_equal(expected, operator_evaluate(root.children[0]))


void operator_reject(char* source):
	pg_diagnostics* diagnostics = pg_diagnostics_new()
	pg_ast_node* root = operators_parse(source, c"expression.txt", diagnostics)
	assert1((root == 0) || (pg_diagnostics_count(diagnostics) > 0))


int main():
	operator_accept(c"1+2*3", 7)
	operator_accept(c"8-3-1", 4)
	operator_accept(c"8-3+1", 6)
	operator_accept(c"2^3^2", 512)
	operator_accept(c"(2^3)^2", 64)
	operator_accept(c"2^(1+2)", 8)
	operator_accept(c"-(1+2)*3", -9)
	operator_accept(c"--2", 2)
	operator_accept(c"+2*-3", -6)
	# Prefix alternatives precede all binaries, so unary binds more tightly
	# than exponentiation in this explicitly admitted grammar slice.
	operator_accept(c"-2^2", 4)
	operator_accept(c"12/3/2", 2)
	operator_accept(c"7%4+2", 5)
	operator_accept(c"8//2+1", 5)
	# The original operator aliases remain in the generated AST.
	pg_diagnostics* diagnostics = pg_diagnostics_new()
	pg_ast_node* root = operators_parse(c"1+2", c"aliases.txt", diagnostics)
	assert1(root != 0)
	assert_equal(0, pg_diagnostics_count(diagnostics))
	pg_ast_node* tail = root.children[0].children[0].children[1]
	assert_strings_equal(c"sum", tail.children[0].name)
	assert_strings_equal(c"addAlias", tail.children[0].children[0].name)
	assert_strings_equal(c"ADD", tail.children[0].children[0].children[0].name)
	assert_strings_equal(c"+", operator_text(tail.children[0]))
	operator_reject(c"1+")
	operator_reject(c"1//")
	operator_reject(c"2^^3")
	operator_reject(c"(1+2")
	operator_reject(c"1 2")
	operator_reject(c"")
	println(c"antlr finite operator aliases and source AST evaluation passed")
	return 0
