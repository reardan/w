int ast_comment_add(int a, int b): return (a /* left */ + b /* right */)

int main():
	int answer = 42 /* constant */
	answer = answer /* receiver */ + 1 /* final */
	if ((answer /* " ) [ # ? : */ + 1) != 44): return 1
	if ((ast_comment_add(20 /* first */, 22 /* second */)) != 42): return 2
	if ((8 / /* divisor */ 2) != 4): return 3
	if ((2 /* one *//* two */ * 3) != 6): return 4
	/* A boundary comment may span
	   multiple lines; it is not speculatively tokenized. */
	if ((c"/* text */"[0]) != '/'): return 5
	return 0 /* trailing comment */
