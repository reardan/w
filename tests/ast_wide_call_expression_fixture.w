int ast_wide_order
int ast_wide_mark(int n):
	ast_wide_order = ast_wide_order + 1
	return n * ast_wide_order

int ast_wide_sum(int a, int b, int c, int d, int e, int f, int g, int h, int i, int j, int k, int l):
	return a + b + c + d + e + f + g + h + i + j + k + l

int main():
	if ((ast_wide_sum(1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12)) != 78): return 1
	if ((ast_wide_sum(ast_wide_mark(1), ast_wide_mark(2), ast_wide_mark(3), ast_wide_mark(4), ast_wide_mark(5), ast_wide_mark(6), ast_wide_mark(7), ast_wide_mark(8), ast_wide_mark(9), ast_wide_mark(10), ast_wide_mark(11), ast_wide_mark(12))) != 650): return 2
	if (ast_wide_order != 12): return 3
	ast_wide_order = 0
	# Signatures currently hold at most ten parameters; explicitly erase
	# this twelve-argument code pointer.
	void* callback = cast(void*, ast_wide_sum)
	if ((callback(ast_wide_mark(1), ast_wide_mark(2), ast_wide_mark(3), ast_wide_mark(4), ast_wide_mark(5), ast_wide_mark(6), ast_wide_mark(7), ast_wide_mark(8), ast_wide_mark(9), ast_wide_mark(10), ast_wide_mark(11), ast_wide_mark(12))) != 650): return 4
	if (ast_wide_order != 12): return 5
	return 0
