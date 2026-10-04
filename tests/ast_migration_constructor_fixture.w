import lib.lib

struct ast_ctor_pair:
	int left
	int right

struct ast_ctor_widths:
	char tag
	int16 small
	float32 value
	string text

struct ast_ctor_outer:
	ast_ctor_pair child
	int tag

int ast_ctor_sum(ast_ctor_pair value): return value.left + value.right

ast_ctor_pair ast_ctor_return(int n): return ast_ctor_pair(n, n + 1)

int ast_ctor_order

int ast_ctor_mark(int digit):
	ast_ctor_order = ast_ctor_order * 10 + digit
	return digit

int main():
	ast_ctor_pair* pair = (new ast_ctor_pair(ast_ctor_mark(1), ast_ctor_mark(2)))
	if (ast_ctor_order != 12): return 1
	if (pair.left != 1 || pair.right != 2): return 2
	ast_ctor_pair* named = (new ast_ctor_pair(right: ast_ctor_mark(3), left: ast_ctor_mark(4)))
	if (ast_ctor_order != 1234): return 3
	if (named.left != 4 || named.right != 3): return 4
	ast_ctor_pair* partial = (new ast_ctor_pair(right: 42))
	if (partial.left != 0 || partial.right != 42): return 5
	ast_ctor_pair* duplicate = (new ast_ctor_pair(left: 1, left: 42))
	if (duplicate.left != 42 || duplicate.right != 0): return 6
	ast_ctor_widths* widths = (new ast_ctor_widths('a', 300, 1.5, c"text"))
	if (widths.tag != 'a' || widths.small != 300 || widths.value != 1.5): return 7
	if (widths.text != s"text"): return 8
	ast_ctor_pair value = (ast_ctor_pair(20, 22))
	if (ast_ctor_sum(value) != 42): return 9
	if ((ast_ctor_sum(ast_ctor_pair(1, 2))) != 3): return 10
	value = (ast_ctor_pair(right: 40, left: 2))
	if (value.left != 2 || value.right != 40): return 11
	if ((ast_ctor_pair(42, 0).left) != 42): return 12
	ast_ctor_outer* outer = (new ast_ctor_outer(ast_ctor_pair(19, 23), 7))
	if (outer.child.left != 19 || outer.child.right != 23 || outer.tag != 7): return 13
	ast_ctor_outer nested = (ast_ctor_outer(ast_ctor_return(20), 8))
	if (nested.child.left != 20 || nested.child.right != 21 || nested.tag != 8): return 14
	ast_ctor_pair empty = (ast_ctor_pair())
	ast_ctor_pair* heap = (new ast_ctor_pair(ast_ctor_return(1).left, 42))
	if (heap.left != 1 || heap.right != 42): return 15
	return 0
