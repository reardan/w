import lib.assert
import libs.extras.grammars.matchers
import bin.antlr_safety_precedence_matchers
import bin.antlr_safety_precedence_parser


char* safety_operator(pg_ast_node* node):
	if (node.text != 0): return node.text
	assert_equal(1, node.children.length)
	return safety_operator(node.children[0])


int safety_evaluate(pg_ast_node* node):
	if (node.token != 0): return atoi(node.text)
	if (strcmp(node.name, c"expr_primary") == 0):
		if (node.children.length == 3): return safety_evaluate(node.children[1])
		if (node.children.length == 2):
			int value = safety_evaluate(node.children[1])
			if (strcmp(safety_operator(node.children[0]), c"-") == 0): return -value
			return value
	assert1(node.children.length > 0)
	int result = safety_evaluate(node.children[0])
	int i = 1
	while (i < node.children.length):
		pg_ast_node* tail = node.children[i]
		assert_equal(2, tail.children.length)
		char* op = safety_operator(tail.children[0])
		int rhs = safety_evaluate(tail.children[1])
		if (strcmp(op, c"+") == 0): result = result + rhs
		else if (strcmp(op, c"-") == 0): result = result - rhs
		else if (strcmp(op, c"*") == 0): result = result * rhs
		else if (strcmp(op, c"/") == 0): result = result / rhs
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


void safety_expression(char* source, int expected):
	pg_diagnostics* diagnostics = pg_diagnostics_new()
	pg_ast_node* root = safety_precedence_parse(source, c"expression.txt", diagnostics)
	assert1(root != 0)
	assert_equal(0, pg_diagnostics_count(diagnostics))
	assert_strings_equal(c"expr", root.children[0].name)
	assert_strings_equal(c"expr_prec2", root.children[0].children[0].name)
	assert_equal(expected, safety_evaluate(root.children[0]))


void safety_expression_reject(char* source):
	pg_diagnostics* diagnostics = pg_diagnostics_new()
	pg_ast_node* root = safety_precedence_parse(source, c"expression.txt", diagnostics)
	assert1((root == 0) || (pg_diagnostics_count(diagnostics) > 0))


int main():
	safety_expression(c"1+2*3", 7)
	safety_expression(c"8-3-1", 4)
	safety_expression(c"8-3+1", 6)
	safety_expression(c"2^3^2", 512)
	safety_expression(c"(2^3)^2", 64)
	safety_expression(c"2^(1+2)", 8)
	safety_expression(c"-(1+2)*3", -9)
	safety_expression(c"--2", 2)
	safety_expression(c"+2*-3", -6)
	# Prefix alternatives precede all binaries, so unary binds more tightly
	# than exponentiation in this explicitly admitted grammar slice.
	safety_expression(c"-2^2", 4)
	safety_expression(c"12/3/2", 2)
	safety_expression_reject(c"1+")
	safety_expression_reject(c"2^^3")
	safety_expression_reject(c"(1+2")
	safety_expression_reject(c"1 2")
	safety_expression_reject(c"")
	println(c"antlr precedence, associativity, unary and parenthesis evaluation passed")
	return 0
