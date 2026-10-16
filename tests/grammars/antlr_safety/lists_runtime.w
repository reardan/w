import lib.assert
import libs.extras.grammars.matchers
import bin.antlr_safety_lists_matchers
import bin.antlr_safety_lists_parser
import bin.antlr_safety_nullable_matchers
import bin.antlr_safety_nullable_parser


void safety_lists_reject(char* input):
	pg_diagnostics* diagnostics = pg_diagnostics_new()
	pg_ast_node* root = safety_lists_parse(input, c"lists.txt", diagnostics)
	assert1((root == 0) || (pg_diagnostics_count(diagnostics) > 0))


void safety_nullable_input(char* input, int success):
	pg_diagnostics* diagnostics = pg_diagnostics_new()
	pg_ast_node* root = safety_nullable_parse(input, c"nullable.txt", diagnostics)
	assert_equal(success, (root != 0) && (pg_diagnostics_count(diagnostics) == 0))


int main():
	safety_nullable_input(c"a", 1)
	safety_nullable_input(c"ab", 1)
	safety_nullable_input(c"", 0)
	safety_nullable_input(c"b", 0)
	safety_nullable_input(c"abb", 0)
	pg_diagnostics* diagnostics = pg_diagnostics_new()
	pg_ast_node* root = safety_lists_parse(c"[a,b,a]p.x.x", c"lists.txt", diagnostics)
	assert1(root != 0)
	assert_equal(0, pg_diagnostics_count(diagnostics))
	assert_strings_equal(c"root", root.name)
	assert_equal(5, root.children.length)
	pg_ast_node* values = root.children[1]
	assert_strings_equal(c"values", values.name)
	assert_equal(3, values.children.length)
	assert_strings_equal(c"item", values.children[0].name)
	assert_strings_equal(c"a", values.children[0].children[0].text)
	assert_strings_equal(c"values_g1", values.children[1].name)
	assert_strings_equal(c",", values.children[1].children[0].text)
	assert_strings_equal(c"b", values.children[1].children[1].children[0].text)
	assert_strings_equal(c"a", values.children[2].children[1].children[0].text)
	pg_ast_node* postfix = root.children[3]
	assert_strings_equal(c"postfix", postfix.name)
	assert_equal(3, postfix.children.length)
	assert_strings_equal(c"postfix_g1", postfix.children[0].name)
	assert_strings_equal(c"p", postfix.children[0].children[0].text)
	assert_strings_equal(c"postfix_g2", postfix.children[1].name)
	assert_strings_equal(c".", postfix.children[1].children[0].text)
	assert_strings_equal(c"x", postfix.children[2].children[1].text)
	diagnostics = pg_diagnostics_new()
	assert1(safety_lists_parse(c"[b]q", c"lists.txt", diagnostics) != 0)
	assert_equal(0, pg_diagnostics_count(diagnostics))
	safety_lists_reject(c"[]p")
	safety_lists_reject(c"[a,]p")
	safety_lists_reject(c"[a]p.")
	safety_lists_reject(c"[a]p.x.xa")
	safety_lists_reject(c"")
	println(c"antlr normalized list/postfix parsing and AST contract passed")
	return 0
