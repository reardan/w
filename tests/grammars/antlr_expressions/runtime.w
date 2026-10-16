import lib.assert
import libs.extras.grammars.matchers
import bin.antlr_expressions_matchers
import bin.antlr_expressions_parser


char* expression_operator(pg_ast_node* node):
	if (node.text != 0): return node.text
	assert_equal(1, node.children.length)
	return expression_operator(node.children[0])


int expression_evaluate(pg_ast_node* node):
	if (node.token != 0): return atoi(node.text)
	if (strcmp(node.name, c"expr_primary") == 0):
		char* first = expression_operator(node.children[0])
		if (strcmp(first, c"(") == 0): return expression_evaluate(node.children[1])
		if (strcmp(first, c"[") == 0): return expression_evaluate(node.children[1]) + expression_evaluate(node.children[3])
		if ((strcmp(first, c"+") == 0) || (strcmp(first, c"-") == 0) || (strcmp(first, c"!") == 0)):
			int value = expression_evaluate(node.children[1])
			if (strcmp(first, c"+") == 0): return value
			return -value
		if (node.children.length == 2):
			pg_ast_node* suffix = node.children[1]
			assert_equal(2, suffix.children.length)
			return 10 * expression_evaluate(node.children[0]) + expression_evaluate(suffix.children[1])
		return expression_evaluate(node.children[0])
	assert1(node.children.length > 0)
	int result = expression_evaluate(node.children[0])
	int i = 1
	while (i < node.children.length):
		pg_ast_node* tail = node.children[i]
		assert_equal(2, tail.children.length)
		char* op = expression_operator(tail.children[0])
		int rhs = expression_evaluate(tail.children[1])
		if (strcmp(op, c"+") == 0): result = result + rhs
		else if (strcmp(op, c"*") == 0): result = result * rhs
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


void expression_accept(char* source, int expected):
	pg_diagnostics* diagnostics = pg_diagnostics_new()
	pg_ast_node* root = expressions_parse(source, c"expression.txt", diagnostics)
	assert1(root != 0)
	assert_equal(0, pg_diagnostics_count(diagnostics))
	assert_equal(expected, expression_evaluate(root.children[0]))


void expression_reject(char* source):
	pg_diagnostics* diagnostics = pg_diagnostics_new()
	pg_ast_node* root = expressions_parse(source, c"expression.txt", diagnostics)
	assert1((root == 0) || (pg_diagnostics_count(diagnostics) > 0))


int main():
	# Prefix binding follows alternative position, including middle and low
	# binding powers; parentheses reset to the complete expression rule.
	expression_accept(c"1+2*3", 7)
	expression_accept(c"2^3^2", 512)
	expression_accept(c"(2^3)^2", 64)
	expression_accept(c"+2^3", 8)
	expression_accept(c"-2^2", -4)
	expression_accept(c"-2*3+4", -2)
	expression_accept(c"!2+3", -5)
	expression_accept(c"(!2)+3", 1)
	expression_accept(c"1+!2+3", -4)
	expression_accept(c"1+-2*3+4", -1)
	expression_accept(c"!!2+3", 5)
	expression_accept(c"2:3*2", 46)
	expression_accept(c"[2,3]*4", 20)
	expression_accept(c"([2,3]+2:3)*2", 56)
	expression_reject(c"1+")
	expression_reject(c"2^^3")
	expression_reject(c"(1+2")
	expression_reject(c"1 2")
	expression_reject(c"2:")
	expression_reject(c"[1,2")
	expression_reject(c"[1 2]")
	expression_reject(c"!")
	expression_reject(c"")
	println(c"antlr token operators, compound bases and prefix binding passed")
	return 0
