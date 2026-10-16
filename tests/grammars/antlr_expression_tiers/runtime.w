import lib.assert
import libs.extras.grammars.matchers
import bin.antlr_expression_tiers_matchers
import bin.antlr_expression_tiers_parser


char* tier_text(pg_ast_node* node):
	if (node.text != 0): return node.text
	assert_equal(1, node.children.length)
	return tier_text(node.children[0])


int tier_evaluate(pg_ast_node* node):
	if (node.token != 0): return atoi(node.text)
	if (strcmp(node.name, c"functionbase") == 0): return tier_evaluate(node.children[1])
	if (strcmp(node.name, c"body") == 0): return tier_evaluate(node.children[0])
	if (strcmp(node.name, c"expr_primary") == 0):
		if (strcmp(node.children[0].name, c"functionbase") == 0): return tier_evaluate(node.children[0])
		char* first = tier_text(node.children[0])
		if (strcmp(first, c"(") == 0): return tier_evaluate(node.children[1])
		if (strcmp(first, c"[") == 0): return tier_evaluate(node.children[1]) + tier_evaluate(node.children[3])
		if ((strcmp(first, c"!") == 0) || (strcmp(first, c"-") == 0)): return -tier_evaluate(node.children[1])
		if (strcmp(first, c"forall") == 0):
			assert_equal(4, node.children.length)
			assert_strings_equal(c":", tier_text(node.children[2]))
			return 100 + tier_evaluate(node.children[3])
		return tier_evaluate(node.children[0])
	assert1(node.children.length > 0)
	int result = tier_evaluate(node.children[0])
	int i = 1
	while (i < node.children.length):
		pg_ast_node* tail = node.children[i]
		char* op = tier_text(tail.children[0])
		if (strcmp(op, c".") == 0):
			char* member = tier_text(tail.children[1])
			assert1((strcmp(member, c"a") == 0) || (strcmp(member, c"b") == 0))
			result = result + 10
			if (strcmp(member, c"b") == 0): result = result + 10
		else:
			int rhs = tier_evaluate(tail.children[1])
			if ((strcmp(op, c"+") == 0) || (strcmp(op, c"[") == 0)): result = result + rhs
			else if ((strcmp(op, c"*") == 0) || (strcmp(op, c"(") == 0)): result = result * rhs
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


void tier_accept(char* input, int expected):
	pg_diagnostics* diagnostics = pg_diagnostics_new()
	pg_ast_node* root = expression_tiers_parse(input, c"tiers.txt", diagnostics)
	assert1(root != 0)
	assert_equal(0, pg_diagnostics_count(diagnostics))
	assert_equal(expected, tier_evaluate(root.children[0]))


void tier_reject(char* input):
	pg_diagnostics* diagnostics = pg_diagnostics_new()
	pg_ast_node* root = expression_tiers_parse(input, c"tiers.txt", diagnostics)
	assert1((root == 0) || (pg_diagnostics_count(diagnostics) > 0))


int main():
	# The shared suffix tier accepts every interleaving, rather than imposing
	# source-alternative order on successive index/member/call operations.
	tier_accept(c"2[3].a[4](2)", 38)
	tier_accept(c"2(3)[4].b", 30)
	tier_accept(c"2.a.b[3]", 35)
	tier_accept(c"2[3]^2+1", 26)
	tier_accept(c"2+3[4]*2", 16)
	tier_accept(c"2^3^2", 512)
	# Prefixes before the suffix tier exclude it; those after admit it.
	tier_accept(c"!2[3]", 1)
	tier_accept(c"!(2[3])", -5)
	tier_accept(c"-2[3]^2+1", -24)
	tier_accept(c"forall a:1+2", 103)
	tier_accept(c"1+forall b:2*3+4", 111)
	tier_accept(c"(forall a:1)+2", 103)
	# Indirect bases invoke the complete expression rule after consuming
	# their own prefix, including keyword boundaries split across rules.
	tier_accept(c"fn 1+2*3 end", 7)
	tier_accept(c"2*fn 1+2 end", 6)
	tier_accept(c"fn fn 1 end+2 end[3]", 6)
	tier_accept(c"[1+2,3*4][5]", 20)
	tier_accept(c"2[fn 1+2 end]", 5)
	tier_reject(c"")
	tier_reject(c"2[")
	tier_reject(c"2[]")
	tier_reject(c"2[3)")
	tier_reject(c"2.")
	tier_reject(c"2(3")
	tier_reject(c"2(3))")
	tier_reject(c"2[3]+")
	tier_reject(c"2[3]4")
	tier_reject(c"forall a:")
	tier_reject(c"forall a 1")
	tier_reject(c"fn 1+2")
	tier_reject(c"fn end")
	tier_reject(c"fn 1 end end")
	tier_reject(c"[1,2,3]")
	println(c"antlr postfix interleaving, compound prefixes and recursive bases passed")
	return 0
