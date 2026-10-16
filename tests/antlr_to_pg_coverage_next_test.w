# wbuild: target=antlr_to_pg_coverage_next_test tag=tests dep=antlr_to_pg
# wbuild: step="bin/antlr_to_pg tests/grammars/antlr_coverage_next/tinyc.g4 -o bin/antlr_coverage_next_tinyc.pg --parser-name coverage_next_tinyc --matchers bin/antlr_coverage_next_tinyc_matchers.w"
# wbuild: step="bin/parser_generator_grammars bin/antlr_coverage_next_tinyc.pg -o bin/antlr_coverage_next_tinyc_parser.w"
# wbuild: step="bin/antlr_to_pg tests/grammars/antlr_coverage_next/microc.g4 -o bin/antlr_coverage_next_microc.pg --parser-name coverage_next_microc --matchers bin/antlr_coverage_next_microc_matchers.w"
# wbuild: step="bin/parser_generator_grammars bin/antlr_coverage_next_microc.pg -o bin/antlr_coverage_next_microc_parser.w"
# wbuild: step="bin/antlr_to_pg tests/grammars/antlr_coverage_next/arithmetic.g4 -o bin/antlr_coverage_next_arithmetic.pg --parser-name coverage_next_arithmetic --matchers bin/antlr_coverage_next_arithmetic_matchers.w"
# wbuild: step="bin/parser_generator_grammars bin/antlr_coverage_next_arithmetic.pg -o bin/antlr_coverage_next_arithmetic_parser.w"
# wbuild: step="bin/wv2 tests/antlr_to_pg_coverage_next_test.w -o bin/antlr_to_pg_coverage_next_test"
# wbuild: step="bin/antlr_to_pg_coverage_next_test"
import lib.assert
import libs.extras.grammars.matchers
import bin.antlr_coverage_next_tinyc_matchers
import bin.antlr_coverage_next_tinyc_parser
import bin.antlr_coverage_next_microc_matchers
import bin.antlr_coverage_next_microc_parser
import bin.antlr_coverage_next_arithmetic_matchers
import bin.antlr_coverage_next_arithmetic_parser


# Exercise unmodified, hash-pinned grammars from the measured corpus through
# the same permissive translation path as its compile coverage sweep. These
# runtime assertions do not waive the separate strict-mode semantic warnings.
pg_ast_node* coverage_next_parse(char* input, int grammar, int success):
	pg_diagnostics* diagnostics = pg_diagnostics_new()
	pg_ast_node* root = 0
	if (grammar == 0): root = coverage_next_tinyc_parse(input, c"tinyc.txt", diagnostics)
	else if (grammar == 1): root = coverage_next_microc_parse(input, c"microc.txt", diagnostics)
	else: root = coverage_next_arithmetic_parse(input, c"arithmetic.txt", diagnostics)
	int accepted = (root != 0) && (pg_diagnostics_count(diagnostics) == 0)
	if (accepted != success): println(input)
	assert_equal(success, accepted)
	return root


pg_ast_node* coverage_next_find(pg_ast_node* node, char* name):
	if ((node.name != 0) && (strcmp(node.name, name) == 0)): return node
	for pg_ast_node* child in node.children:
		pg_ast_node* found = coverage_next_find(child, name)
		if (found != 0): return found
	return 0


char* coverage_next_operator(pg_ast_node* node):
	if (node.text != 0): return node.text
	assert_equal(1, node.children.length)
	return coverage_next_operator(node.children[0])


int coverage_next_value(pg_ast_node* node):
	if (node.token != 0): return atoi(node.text)
	assert1(node.children.length > 0)
	if (strcmp(node.name, c"paren_expr") == 0): return coverage_next_value(node.children[1])
	if (strcmp(node.name, c"expression_primary") == 0):
		pg_ast_node* first = node.children[0]
		if ((first.text != 0) && (strcmp(first.text, c"(") == 0)):
			assert_equal(3, node.children.length)
			return coverage_next_value(node.children[1])
		# The upstream compound base keeps every prefix sign before atom.
		int result = coverage_next_value(node.children[node.children.length - 1])
		int i = 0
		while (i < node.children.length - 1):
			if (strcmp(coverage_next_operator(node.children[i]), c"-") == 0): result = -result
			i = i + 1
		return result
	int result = coverage_next_value(node.children[0])
	int i = 1
	while (i < node.children.length):
		pg_ast_node* tail = node.children[i]
		assert_equal(2, tail.children.length)
		char* op = coverage_next_operator(tail.children[0])
		int rhs = coverage_next_value(tail.children[1])
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


void coverage_next_equation(char* input, int expected):
	pg_ast_node* root = coverage_next_parse(input, 2, 1)
	pg_ast_node* equation = coverage_next_find(root, c"equation")
	assert1(equation != 0)
	assert_equal(3, equation.children.length)
	assert_equal(expected, coverage_next_value(equation.children[0]))
	assert_strings_equal(c"=", coverage_next_operator(equation.children[1]))
	assert_equal(expected, coverage_next_value(equation.children[2]))


int main():
	for grammar in range(2):
		pg_ast_node* root = coverage_next_parse(c"9-(2+1)-3;", grammar, 1)
		assert_strings_equal(c"program", root.name)
		pg_ast_node* sum = coverage_next_find(root, c"sum_")
		assert1(sum != 0)
		assert_equal(3, sum.children.length)
		assert_strings_equal(c"term", sum.children[0].name)
		assert_strings_equal(c"sum__g1", sum.children[1].name)
		assert_equal(3, coverage_next_value(sum))
		coverage_next_parse(c"{ 1; while(a) { a+(2-1); } }", grammar, 1)
		coverage_next_parse(c"if((1+2)) (3-1);", grammar, 1)
		coverage_next_parse(c"(1+(2-(3+4)));", grammar, 1)
		coverage_next_parse(c"{}", grammar, 1)
		coverage_next_parse(c"", grammar, 0)
		coverage_next_parse(c"1+;", grammar, 0)
		coverage_next_parse(c"(1+2;", grammar, 0)
		coverage_next_parse(c"1", grammar, 0)
		coverage_next_parse(c"1;}", grammar, 0)
		coverage_next_parse(c"{1;", grammar, 0)
		coverage_next_parse(c"while(1+) 2;", grammar, 0)
		coverage_next_parse(c"1; b=;", grammar, 0)
	coverage_next_parse(c"do { a-1; } while(a);", 0, 1)
	coverage_next_parse(c";", 0, 1)
	coverage_next_parse(c";", 1, 0)
	coverage_next_parse(c"do 1; while(a<3);", 1, 0)

	coverage_next_equation(c"1+2*3=7", 7)
	coverage_next_equation(c"(1+2)*3=9", 9)
	coverage_next_equation(c"8-3-1=4", 4)
	# No assoc=right annotation: the upstream POW alternative is left-associative.
	coverage_next_equation(c"2^3^2=64", 64)
	coverage_next_equation(c"2^(3^2)=512", 512)
	coverage_next_equation(c"--2*+-3=-6", -6)
	coverage_next_equation(c"12/3/2=2", 2)
	coverage_next_parse(c"x_1+2.5E-3=y\n2<3\n4>1", 2, 1)
	coverage_next_parse(c"", 2, 1)
	coverage_next_parse(c"1+=2", 2, 0)
	coverage_next_parse(c"1+2", 2, 0)
	coverage_next_parse(c"(1+2=3", 2, 0)
	coverage_next_parse(c"1=2)", 2, 0)
	coverage_next_parse(c"1=2 3", 2, 0)
	coverage_next_parse(c"2^^3=8", 2, 0)
	coverage_next_parse(c"1=2+", 2, 0)
	println(c"pinned tinyc, microc and arithmetic parser execution and AST semantics passed")
	return 0
