# Shared differential input for the production x64 backend and wllvm:
# slices and slice values (ranges over arrays, slices and strings, array
# decay to slices and pointers, slice cursor loops), parallel assignment
# and enum_name. Output and exit status must match exactly.
import lib.lib

enum shade:
	shade_dark = 3
	shade_light = 5
	shade_bright = 5


struct spot:
	int x
	int y


type sum_callback = fn(int*, int) -> int


int sum_pointer(int* values, int n):
	int total = 0
	for i in range(n): total = total + values[i]
	return total


int sum_slice(int[] values):
	int total = 0
	for x in values: total = total + x
	return total * 10 + values.length


int[] pass_slice(int[] values): return values


void check(char* label, int value):
	print(label)
	print(c" ")
	println(value)


int main():
	int[5] values
	for i in range(5): values[i] = i + 10
	int[] all = values
	int[] middle = values[1:4]
	int[] tail = all[2:]
	int[] head = values[:2]
	check(c"lengths", all.length * 1000 + middle.length * 100 + tail.length * 10 + head.length)
	check(c"elements", middle[0] * 100 + tail[2])
	check(c"sums", sum_slice(values) + sum_slice(middle))
	check(c"value slice", sum_slice(values[3:]) + values[1:][1:3][0])
	middle[0] = 21
	check(c"aliasing", values[1])
	int* data = values
	check(c"decay", data[1] + sum_pointer(values, 2) + sum_pointer(middle, 2))
	int* window = cast(int*, values[2:4])
	check(c"cast", window[0] + (cast(int, values) == cast(int, all.data)))
	sum_callback* callback = sum_pointer
	check(c"indirect", callback(values, 3))
	check(c"returned", pass_slice(tail)[0])
	int seen = 0
	for x in values[1:3]: seen = seen * 100 + x
	check(c"value loop", seen)
	char[4] letters
	letters[0] = 'w'
	letters[1] = 'x'
	letters[2] = 'y'
	letters[3] = 'z'
	char[] some = letters[1:]
	check(c"char slice", some[0] * 1000 + some.length)
	string text = "abcdef"
	string part = text[1:4]
	check(c"string slice", part.length * 1000 + part[0] * 10 + (text[4:][1] == 'f'))
	println(text[2:5])
	check(c"len", len(values) * 10 + len(values[1:]))

	int a = 1
	int b = 2
	a, b = b, a
	check(c"swap", a * 10 + b)
	spot s
	s.x = 3
	values[0] = 7
	values[0], s.x, a = s.x, values[0], a + b
	check(c"parallel", values[0] * 100 + s.x * 10 + a)
	int f = 0
	int g = 1
	for i in range(10): f, g = g, f + g
	check(c"fibonacci", f)

	println(enum_name(shade_dark))
	println(enum_name(shade_bright))
	println(enum_name(cast(shade, -7)))
	shade picked = shade_light
	string name = enum_name(picked)
	check(c"enum length", name.length)
	return a + f % 7
