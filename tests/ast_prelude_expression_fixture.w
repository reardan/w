import lib.utf8

enum ast_prelude_color:
	ast_prelude_red = 3
	ast_prelude_blue = 5
	ast_prelude_alias = 5

int ast_prelude_order
int ast_prelude_mark(int value):
	ast_prelude_order = ast_prelude_order * 10 + value
	return value

int ast_prelude_shadow();
int main():
	if (max(ast_prelude_mark(1), ast_prelude_mark(2)) != 2): return 1
	if (ast_prelude_order != 12): return 2
	if (min(abs(-8), max(2, 4)) != 4): return 3
	if (max(true, false) != 1): return 4
	char letter = 'A'
	if (abs(letter) != 65): return 5
	if (len(c"abc") != 3 || len(s"hello") != 5): return 6
	int[3] array
	if (len(array) != 3 || len(array[1:]) != 2): return 7
	list[int] values = list[int]{0, 2, 3}
	if (len(values) != 3 || any(values) != 1 || all(values) != 0): return 8
	if (any(list[int]{}) != 0 || all(list[bool]{}) != 1): return 9
	if (len(map[int, int]{1: 2}) != 1 || len(set[int]{1, 2}) != 2): return 10
	list[char*] pieces = split(c"one two  three")
	if (len(pieces) != 3): return 11
	string joined = join(pieces, s"-")
	if (joined != s"one-two-three"): return 12
	list[char*] fields = split(s"a,b,c", ',')
	if (len(fields) != 3): return 13
	list[string] strings = list[string]{s"x", s"y"}
	string combined = join(strings, c"+")
	if (combined != s"x+y"): return 14
	string red = enum_name(ast_prelude_red)
	string blue = enum_name(ast_prelude_alias)
	string unknown = enum_name(cast(ast_prelude_color, -7))
	if (red != s"ast_prelude_red" || blue != s"ast_prelude_blue" || unknown != s"-7"): return 15
	println(values)
	println(pieces)
	println(strings)
	if (ast_prelude_shadow() != 90): return 16
	values.free()
	pieces.free()
	fields.free()
	strings.free()
	return 0

int max(int a, int b): return 90
int ast_prelude_shadow(): return max(1, 2)
