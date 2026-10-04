int ast_multiline_add(int a, int b): return a + b

int main():
	int a = (1 +
		2 + # line comment inside the group
		3)
	if (a != 6): return 1
	int b = (ast_multiline_add(
		a,
		36))
	if (b != 42): return 2
	int c = (b /* multi-line comment
 spaces here belong to the comment */ + 1)
	if (c != 43): return 3
	int d = 10
		+ 32
	if (d != 42): return 4
	int* p = &a
	a = 0
	*p = 7
	if (a != 7): return 5
	a = 10
	++a
	--a
	if (a != 10): return 6
	if (((a > 0) &&
		(b == 42) &&
		(c == 43)) == false): return 7
	return 0
