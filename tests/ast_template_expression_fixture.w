int ast_template_order
int ast_template_mark(int n):
	ast_template_order = ast_template_order * 10 + n
	return n

int ast_template_c_length(char* text):
	int n = 0
	while (text[n]): n++
	return n

char* ast_template_c_return(int n): return (f"n={n}")

int main():
	string empty = (f"")
	if (empty.length != 0): return 1
	string plain = (f"plain")
	if (plain != s"plain"): return 2
	int n = 21
	string text = (f"answer={n * 2}!")
	if (text != s"answer=42!"): return 3
	string adjacent = (f"{ast_template_mark(1)}{ast_template_mark(2)}")
	if (adjacent != s"12" || ast_template_order != 12): return 4
	string nested = (f"outer[{f"inner={n}"}]")
	if (nested != s"outer[inner=21]"): return 5
	string literal = (f"{c"C"}/{s"W"}")
	if (literal != s"C/W"): return 6
	string braces = (f"{{x}}={n} {{}}")
	if (braces != s"{x}=21 {}"): return 7
	string escaped = (f"a\0b{n}\n\t\u00e9")
	if (escaped.length != 9): return 8
	if (escaped.data[0] != 'a' || escaped.data[1] != 0 || escaped.data[2] != 'b'): return 9
	if (escaped.data[5] != 10 || escaped.data[6] != 9): return 10
	char letter = 'A'
	bool flag = true
	string scalar = (f"{letter}/{flag}/{-7}")
	if (scalar != s"65/1/-7"): return 11
	float32 real = 1.5
	string decimal = (f"{real}")
	if (decimal != s"1.5"): return 12
	if ((f"{n}".length) != 2): return 13
	char* raw = (f"n={n}")
	if (ast_template_c_length(raw) != 4): return 14
	if ((ast_template_c_length(f"{n} and {n}")) != 9): return 15
	if (ast_template_c_length(ast_template_c_return(n)) != 4): return 16
	if 1: (raw = f"{n}")
	if (ast_template_c_length(raw) != 2): return 17
	return 0
