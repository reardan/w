# Issue #532: unsafe conversions and control-flow defects the type
# checks used to accept silently (grammar/type_check.w). Each construct
# below triggers exactly the warning listed; the warning_test target
# compiles this file with bin/wfixture. Under --strict every one of
# them fails the build (unsafe_conversion_strict_fixture.w).
# expect_stderr: warning: return narrows constant 65536 to 'uint16' (stored as 0); use cast() if the truncation is intended
# expect_stderr: warning: initialization narrows constant 300 to 'char' (stored as 44); use cast() if the truncation is intended
# expect_stderr: warning: initialization narrows constant -200 to 'int8' (stored as 56); use cast() if the truncation is intended
# expect_stderr: warning: initialization narrows constant 256 to 'uint8' (stored as 0); use cast() if the truncation is intended
# expect_stderr: warning: initialization narrows constant 70000 to 'int16' (stored as 4464); use cast() if the truncation is intended
# expect_stderr: warning: assignment narrows constant 400 to 'char' (stored as -112); use cast() if the truncation is intended
# expect_stderr: warning: function 'take_char' argument 1 narrows constant 1000 to 'char' (stored as -24); use cast() if the truncation is intended
# expect_stderr: warning: initialization converts '5' to enum 'color' implicitly; use cast(color, ...)
# expect_stderr: warning: assignment converts 'int' to enum 'color' implicitly; use cast(color, ...)
# expect_stderr: warning: function 'take_color' argument 1 converts '1' to enum 'color' implicitly; use cast(color, ...)
# expect_stderr: warning: '==' and '!=' on struct values compare their addresses, not their fields; compare the fields, or take '&' of both sides to compare addresses
# expect_stderr: warning: function 'falls_off' can reach the end of its body without returning a value
# expect_stderr: warning: function 'if_without_else' can reach the end of its body without returning a value
# expect_stderr: warning: function 'loop_with_break' can reach the end of its body without returning a value
# expect_stderr: warning: duplicate case value 2 in switch; only the first matching case runs
# expect_stderr: warning: duplicate case value -1 in switch; only the first matching case runs
# expect_stderr: warning: duplicate case value 65 in switch; only the first matching case runs
# expect_stderr: warning: duplicate case value 0 in switch; only the first matching case runs
# expect_stderr: warning: return with a value in a void function
# reject_stderr: 'all_paths_return'
# reject_stderr: 'ends_in_loop'
# reject_stderr: 'ends_in_switch'
# reject_stderr: 'ends_in_exit'
# reject_stderr: 'ends_in_die'
# reject_stderr: 'ends_in_goto'
# reject_stderr: narrows constant 200
# reject_stderr: narrows constant 255
# reject_stderr: narrows constant -1
# reject_stderr: narrows constant 7 to
# reject_stderr: converts 'color'
# reject_stderr: converts '7'
# wbuild: fixture_group=warning_test
import lib.lib


enum color:
	red
	green


struct point:
	int x
	int y


void take_char(char c):
	pass


void take_color(color c):
	pass


uint16 wide_return():
	return 65536


void narrowing():
	char c = 300
	int8 small = -200
	uint8 b = 256
	int16 s = 70000
	c = 400
	take_char(1000)
	# in range for the type's signed or unsigned reading: no warning
	char high = 200
	uint8 all_ones = 255
	uint8 minus_one = -1
	char explicit = cast(char, 7)


void enums():
	color c = 5
	int i = 1
	c = i
	take_color(1)
	# enum to enum, enum to int and cast() stay quiet
	c = red
	int back = c
	color d = cast(color, 7)


int struct_compare(point a, point b):
	if (a == b): return 1
	# pointer comparison is an address comparison by design
	if (&a == &b): return 2
	return 0


int falls_off(int x):
	if (x): return 1


int if_without_else(int x):
	if (x > 0): return 1
	elif (x < 0): return 2


int loop_with_break(int x):
	while (1):
		if (x): break
		return 3


int all_paths_return(int x):
	if (x > 0): return 1
	elif (x < 0): return 2
	else: return 0


int ends_in_loop(int x):
	while (true):
		x = x + 1
		if (x > 10): return x


int ends_in_switch(int x):
	switch x:
		case 1:
			return 10
		default:
			return 20


int ends_in_exit(int x):
	if (x): return 1
	exit(1)


void die(char* message):
	println(message)
	exit(2)


int ends_in_die(int x):
	if (x): return 1
	die(c"bad x")


int ends_in_goto(int x):
	again:
	if (x > 3): return x
	x = x + 1
	goto again


int duplicate_cases(int x):
	switch x:
		case 1, 2:
			return 1
		case (2):
			return 2
		case -1:
			return 3
		case 3, -1:
			return 4
		case 65:
			return 5
		case 'A':
			return 6
	color c = green
	switch c:
		case red:
			return 7
		case green, red:
			return 8
	return 0


void void_returns_value():
	return 5


void void_returns_void():
	return void_returns_value()


int main():
	narrowing()
	enums()
	return 0
