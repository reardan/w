# Exercise lazy runtime import: do not import structures.w_dynamic here.
int ast_var_order
var ast_var_mark(int value):
	ast_var_order = ast_var_order * 10 + value
	return value

T ast_var_identity[T](T value): return value
var ast_var_twice(var value): return value + value

int main():
	var a = 12
	var b = 3
	if (a + b != 15 || a - b != 9): return 1
	if (a * b != 36 || a / b != 4): return 2
	if (2 + b != 5 || 15 - b != 12): return 3
	if (a <= b || a < b || b >= a || b > a): return 4
	if (ast_var_mark(1) + ast_var_mark(2) != 3): return 5
	if (ast_var_order != 12): return 6
	if (ast_var_twice(7) != 14): return 7
	var copy = ast_var_identity(a)
	if (copy != 12): return 8
	if (cast(int, a) != 12 || cast(char, a) != 12): return 9
	if (cast(bool, a) != true): return 10
	void* raw = cast(void*, a)
	if (raw == 0): return 11
	var boxed = cast(var, 65)
	if (boxed != 65): return 12
	var selected = true ? a : 7
	if (selected != 12): return 13
	selected = false ? a : 7
	if (selected != 7): return 14
	var text = c"hello"
	text = text + s" world"
	if (text != s"hello world"): return 15
	string rendered = f"{a}:{text}"
	if (rendered != s"12:hello world"): return 16
	string unboxed = cast(string, text)
	if (unboxed != s"hello world"): return 17
	char* ctext = cast(char*, text)
	if (ctext[0] != 'h'): return 18
	if (true & (a == 12)):
		if (false | cast(bool, b)):
			print(a)
			println(text)
			return 0
	return 19
