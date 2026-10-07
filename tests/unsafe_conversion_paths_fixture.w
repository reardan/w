# expect_fail
# Issue #532's conversion checks (grammar/type_check.w) on every
# conversion site the streaming grammar checks: assignments, sign and
# grouping of literals, call and method-receiver arguments, calls
# through function pointers, explicit and inferred generic calls, map
# stores, keys and method arguments, parallel assignment, list methods
# and literals, and '=='/'!=' on struct values. The AST front end
# (grammar/ast_expression.w) records each as an event and replays it,
# so the required-mode suite (ast_expression_suite) asserts the same
# errors. The former lint-only rules on the last functions are covered by
# tests/type_check_lint_fixture.w.
# expect_stderr: error: assignment narrows constant -300 to 'char' (stored as -44); use cast() if the truncation is intended
# expect_stderr: error: assignment narrows constant 300 to 'char' (stored as 44); use cast() if the truncation is intended
# expect_stderr: error: function 'take_char' argument 1 narrows constant -1000 to 'char' (stored as 24); use cast() if the truncation is intended
# expect_stderr: error: map assignment narrows constant 300 to 'char' (stored as 44); use cast() if the truncation is intended
# expect_stderr: error: map key converts '1' to enum 'color' implicitly; use cast(color, ...)
# expect_stderr: error: map add key converts '1' to enum 'color' implicitly; use cast(color, ...)
# expect_stderr: error: map get key converts '1' to enum 'color' implicitly; use cast(color, ...)
# expect_stderr: error: set add key converts '1' to enum 'color' implicitly; use cast(color, ...)
# expect_stderr: error: container remove key converts '0' to enum 'color' implicitly; use cast(color, ...)
# expect_stderr: error: assignment narrows constant 400 to 'char' (stored as -112); use cast() if the truncation is intended
# expect_stderr: error: assignment converts 'int' to enum 'color' implicitly; use cast(color, ...)
# expect_stderr: error: function 'first_of$char' argument 1 narrows constant 300 to 'char' (stored as 44); use cast() if the truncation is intended
# expect_stderr: error: function 'point_tag' argument 2 narrows constant 1000 to 'char' (stored as -24); use cast() if the truncation is intended
# expect_stderr: error: list push narrows constant 300 to 'char' (stored as 44); use cast() if the truncation is intended
# expect_stderr: error: list literal element converts '1' to enum 'color' implicitly; use cast(color, ...)
# expect_stderr: error: list literal element converts '2' to enum 'color' implicitly; use cast(color, ...)
# expect_stderr: error: function 'function pointer' argument 1 narrows constant 300 to 'char' (stored as 44); use cast() if the truncation is intended
# expect_stderr: error: '==' and '!=' on struct values compare their addresses, not their fields; compare the fields, or take '&' of both sides to compare addresses
# reject_stderr: argument 1 narrows constant 1000
# reject_stderr: function 'pick
# expect_stderr: error: initialization converts 'void*' to 'int*' without cast() [void-pointer-conversion]
# wbuild: fixture_group=warning_test
import lib.lib


enum color:
	red
	green


struct point:
	int x
	int y


type char_cb = fn(char) -> int


void take_char(char c):
	pass


void take_color(color c):
	pass


void take_ints(int* p):
	pass


T first_of[T](T a, T b):
	return a


T pick[T](T a, char tag):
	return a


void point_tag(point* p, char c):
	pass


int narrow_paths():
	char c = 'A'
	c = (300)
	c = -300
	c = +300
	take_char(-1000)
	take_char((1000))
	map[int, char] m = new map[int, char]
	m[1] = 300
	map[color, int] by_color = new map[color, int]
	by_color[1] = 2
	by_color.add(1)
	int got = by_color.get(1, 3)
	set[color] colors = new set[color]
	colors.add(1)
	colors.remove(0)
	char a
	char b
	a, b = 300, 400
	color k
	int i = 1
	k, i = i, 2
	char x = first_of[char](300, 2)
	char y = pick(300, 1000)
	point p
	p.tag(1000)
	list[char] chars = new list[char]
	chars.push(300)
	list[color] cl = list[color]{1, 2}
	return got + x + y


int callbacks(int f, char_cb* g):
	g(300)
	return f(1000)



int compare_structs(point a, point b):
	int r = 0
	if (a != b): r = 1
	if ((a == b) && (r == 0)): r = 2
	return r


void pointers(void* raw):
	int* ints = raw
	char* chars
	chars = raw
	take_ints(raw)
	map[int, int*] m = new map[int, int*]
	m[1] = raw


int main():
	narrow_paths()
	pointers(malloc(8))
	return 0
