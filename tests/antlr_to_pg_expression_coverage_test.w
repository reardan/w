# wbuild: target=antlr_to_pg_expression_coverage_test tag=tests dep=antlr_to_pg
# wbuild: step="bin/antlr_to_pg tests/grammars/antlr_expression_coverage/LuaLexer.g4 tests/grammars/antlr_expression_coverage/LuaParser.g4 -o bin/antlr_expression_coverage_lua.pg --parser-name expression_coverage_lua --matchers bin/antlr_expression_coverage_lua_matchers.w"
# wbuild: step="bin/parser_generator_grammars bin/antlr_expression_coverage_lua.pg -o bin/antlr_expression_coverage_lua_parser.w"
# wbuild: step="bin/antlr_to_pg tests/grammars/antlr_expression_coverage/tnt.g4 -o bin/antlr_expression_coverage_tnt.pg --parser-name expression_coverage_tnt --matchers bin/antlr_expression_coverage_tnt_matchers.w"
# wbuild: step="bin/parser_generator_grammars bin/antlr_expression_coverage_tnt.pg -o bin/antlr_expression_coverage_tnt_parser.w"
# wbuild: step="bin/wv2 tests/antlr_to_pg_expression_coverage_test.w -o bin/antlr_to_pg_expression_coverage_test"
# wbuild: step="bin/antlr_to_pg_expression_coverage_test"
import lib.assert
import libs.extras.grammars.matchers
import bin.antlr_expression_coverage_lua_matchers
import bin.antlr_expression_coverage_lua_parser
import bin.antlr_expression_coverage_tnt_matchers
import bin.antlr_expression_coverage_tnt_parser


# Unmodified corpus inputs exercise the same permissive pipeline as the
# compile sweep. See the fixture README for unimplemented upstream behavior.
pg_ast_node* expression_coverage_parse(char* source, int success):
	pg_diagnostics* diagnostics = pg_diagnostics_new()
	pg_ast_node* root = expression_coverage_lua_parse(source, c"lua.txt", diagnostics)
	int accepted = (root != 0) && (pg_diagnostics_count(diagnostics) == 0)
	if (accepted != success): println(source)
	assert_equal(success, accepted)
	return root


pg_ast_node* expression_coverage_tnt_input(char* source, int success):
	pg_diagnostics* diagnostics = pg_diagnostics_new()
	pg_ast_node* root = expression_coverage_tnt_parse(source, c"tnt.txt", diagnostics)
	int accepted = (root != 0) && (pg_diagnostics_count(diagnostics) == 0)
	if (accepted != success): println(source)
	assert_equal(success, accepted)
	return root


pg_ast_node* expression_coverage_find(pg_ast_node* node, char* name):
	if ((node.name != 0) && (strcmp(node.name, name) == 0)): return node
	for pg_ast_node* child in node.children:
		pg_ast_node* found = expression_coverage_find(child, name)
		if (found != 0): return found
	return 0


char* expression_coverage_operator(pg_ast_node* node):
	if (node.text != 0): return node.text
	assert_equal(1, node.children.length)
	return expression_coverage_operator(node.children[0])


int expression_coverage_value(pg_ast_node* node):
	if (node.token != 0): return atoi(node.text)
	assert1(node.children.length > 0)
	if ((strcmp(node.name, c"number") == 0) && (strcmp(node.children[node.children.length - 1].name, c"ZERO") == 0)):
		return node.children.length - 1
	if (((strcmp(node.name, c"prefixexp") == 0) || (strcmp(node.name, c"expression_primary") == 0)) && (node.children.length == 3)):
		assert_strings_equal(c"(", node.children[0].text)
		assert_strings_equal(c")", node.children[2].text)
		return expression_coverage_value(node.children[1])
	if ((strcmp(node.name, c"exp_primary") == 0) && (node.children.length == 2)):
		assert_strings_equal(c"-", expression_coverage_operator(node.children[0]))
		return -expression_coverage_value(node.children[1])
	int result = expression_coverage_value(node.children[0])
	int i = 1
	while (i < node.children.length):
		pg_ast_node* tail = node.children[i]
		assert_equal(2, tail.children.length)
		char* op = expression_coverage_operator(tail.children[0])
		int rhs = expression_coverage_value(tail.children[1])
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


void expression_coverage_numeric(char* source, int expected):
	pg_ast_node* root = expression_coverage_parse(source, 1)
	assert_strings_equal(c"start_", root.name)
	pg_ast_node* expr = expression_coverage_find(root, c"exp")
	assert1(expr != 0)
	assert_equal(expected, expression_coverage_value(expr))


int main():
	expression_coverage_numeric(c"return 1+2*3", 7)
	expression_coverage_numeric(c"return (1+2)*3", 9)
	expression_coverage_numeric(c"return 8-3-1", 4)
	expression_coverage_numeric(c"return 12/3/2", 2)
	expression_coverage_numeric(c"return -2^2", -4)
	expression_coverage_numeric(c"return (-2)^2", 4)
	expression_coverage_numeric(c"return 2^3^2", 512)
	expression_coverage_numeric(c"return (2^3)^2", 64)
	expression_coverage_numeric(c"return - -2*3", 6)
	expression_coverage_numeric(c"return 1+(2-(3+4))", -4)
	pg_ast_node* root = expression_coverage_parse(c"return {1, 2+3, [4]=5}", 1)
	assert1(expression_coverage_find(root, c"tableconstructor") != 0)
	root = expression_coverage_parse(c"return function(a) return a+1 end", 1)
	assert1(expression_coverage_find(root, c"functiondef") != 0)
	root = expression_coverage_parse(c"return (1+2)[3+4]", 1)
	assert1(expression_coverage_find(root, c"prefixexp_g3") != 0)
	expression_coverage_parse(c"local x=1+2; while x<5 do x=x+1 end; return x", 1)
	expression_coverage_parse(c"if 1<2 then return 3 else return 4 end", 1)
	expression_coverage_parse(c"", 1)
	expression_coverage_parse(c"return 1+", 0)
	expression_coverage_parse(c"return (1+2", 0)
	expression_coverage_parse(c"return 1+2)", 0)
	expression_coverage_parse(c"return 1 2", 0)
	expression_coverage_parse(c"return 2^^3", 0)
	expression_coverage_parse(c"return {1,", 0)
	expression_coverage_parse(c"return function(a) return a+1", 0)
	expression_coverage_parse(c"return (1+2)[3+4", 0)
	expression_coverage_parse(c"while 1 do return 2", 0)

	# TNT's source puts '+' before '*': preserve that unusual precedence.
	root = expression_coverage_tnt_input(c"S0+SS0*SSS0=0", 1)
	assert_equal(9, expression_coverage_value(root.children[0]))
	root = expression_coverage_tnt_input(c"SS0*(S0+SSS0)=0", 1)
	assert_equal(8, expression_coverage_value(root.children[0]))
	root = expression_coverage_tnt_input(c"Aa:S0+SS0*SSS0=0", 1)
	pg_ast_node* primary = expression_coverage_find(root, c"expression_primary")
	assert1(primary != 0)
	assert_equal(2, primary.children.length)
	assert_strings_equal(c"forevery", primary.children[0].name)
	assert_equal(3, primary.children[0].children.length)
	assert_strings_equal(c":", primary.children[0].children[2].text)
	assert_strings_equal(c"expression_prec1", primary.children[1].name)
	assert_equal(9, expression_coverage_value(primary.children[1]))
	root = expression_coverage_tnt_input(c"Ea':S0+SS0=SSS0", 1)
	primary = expression_coverage_find(root, c"expression_primary")
	assert_strings_equal(c"exists", primary.children[0].name)
	assert_equal(3, expression_coverage_value(primary.children[1]))
	expression_coverage_tnt_input(c"Aa:Ea':S0=0", 1)
	expression_coverage_tnt_input(c"~S0+SS0=0", 1)
	expression_coverage_tnt_input(c"", 0)
	expression_coverage_tnt_input(c"AaS0=0", 0)
	expression_coverage_tnt_input(c"Aa:=0", 0)
	expression_coverage_tnt_input(c"S0+=0", 0)
	expression_coverage_tnt_input(c"S0+SS0", 0)
	expression_coverage_tnt_input(c"(S0+SS0=0", 0)
	expression_coverage_tnt_input(c"S0=0)", 0)
	expression_coverage_tnt_input(c"S0=0 S0", 0)
	println(c"pinned Lua and TNT expression precedence, nested bases and compound prefix checks passed")
	return 0
