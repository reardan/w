import lib.assert
import libs.extras.grammars.matchers
import bin.antlr_nested_lists_matchers
import bin.antlr_nested_lists_parser
import bin.antlr_empty_lists_matchers
import bin.antlr_empty_lists_parser


pg_ast_node* nested_lists_input(char* input, int success):
	pg_diagnostics* diagnostics = pg_diagnostics_new()
	pg_ast_node* root = nested_lists_parse(input, c"nested.txt", diagnostics)
	assert_equal(success, (root != 0) && (pg_diagnostics_count(diagnostics) == 0))
	return root


pg_ast_node* empty_lists_input(char* input, int success):
	pg_diagnostics* diagnostics = pg_diagnostics_new()
	pg_ast_node* root = empty_lists_parse(input, c"empty.txt", diagnostics)
	assert_equal(success, (root != 0) && (pg_diagnostics_count(diagnostics) == 0))
	return root


int main():
	nested_lists_input(c"a", 1)
	nested_lists_input(c"((a))", 1)
	nested_lists_input(c"[{(a+b).c}]-d", 1)
	pg_ast_node* root = nested_lists_input(c"a+(b-c).d-e", 1)
	pg_ast_node* expr = root.children[0]
	assert_strings_equal(c"expr", expr.name)
	assert_equal(3, expr.children.length)
	assert_strings_equal(c"term", expr.children[0].name)
	assert_strings_equal(c"+", expr.children[1].children[0].text)
	assert_strings_equal(c"-", expr.children[2].children[0].text)
	pg_ast_node* postfix = expr.children[1].children[1].children[0]
	assert_strings_equal(c"postfix", postfix.name)
	assert_equal(2, postfix.children.length)
	assert_strings_equal(c".", postfix.children[1].children[0].text)
	assert_strings_equal(c"d", postfix.children[1].children[1].text)
	pg_ast_node* atom = postfix.children[0]
	assert_strings_equal(c"atom", atom.name)
	assert_strings_equal(c"(", atom.children[0].text)
	pg_ast_node* inside = atom.children[1]
	assert_strings_equal(c"expr", inside.name)
	assert_equal(2, inside.children.length)
	assert_strings_equal(c"-", inside.children[1].children[0].text)
	assert_strings_equal(c")", atom.children[2].text)
	nested_lists_input(c"", 0)
	nested_lists_input(c"()", 0)
	nested_lists_input(c"a+", 0)
	nested_lists_input(c"a++b", 0)
	nested_lists_input(c"a+(b", 0)
	nested_lists_input(c"a+(b]", 0)
	nested_lists_input(c"a+(b)-", 0)
	nested_lists_input(c"a.(b)", 0)
	nested_lists_input(c"(a+b).", 0)
	nested_lists_input(c"a b", 0)
	nested_lists_input(c"a)", 0)
	root = empty_lists_input(c"[]", 1)
	assert_strings_equal(c"values", root.children[1].name)
	assert_equal(0, root.children[1].children.length)
	root = empty_lists_input(c"[a]", 1)
	assert_equal(1, root.children[1].children.length)
	root = empty_lists_input(c"[aa(a())a]", 1)
	assert_equal(4, root.children[1].children.length)
	empty_lists_input(c"[()]", 1)
	empty_lists_input(c"", 0)
	empty_lists_input(c"[", 0)
	empty_lists_input(c"[a", 0)
	empty_lists_input(c"[a(]", 0)
	empty_lists_input(c"[a)]", 0)
	empty_lists_input(c"[]a", 0)
	empty_lists_input(c"[b]", 0)
	println(c"antlr nested postfix/list and nullable-base parser runtime passed")
	return 0
