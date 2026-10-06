/*
Fixture for dwarf_variables_test: the build target compiles this with
-g for x86, x64 and arm64 and the test walks the emitted
.debug_abbrev/.debug_info. probe() prints the runtime layout of its own
frame (argument and local addresses relative to x, and the words above
x) so the test can check the DW_OP_fbreg locations against the running
code, not only against the compiler's own arithmetic.
*/
import lib.lib


struct dwarf_pair:
	int first
	char* second


enum dwarf_color:
	dwarf_red
	dwarf_green = 5


type dwarf_number = int


int probe(int a, int b):
	int x = a + b
	if (x > 0):
		int y = x * 2
		int base = cast(int, &x)
		println(itoa(cast(int, &a) - base))
		println(itoa(cast(int, &b) - base))
		println(itoa(cast(int, &y) - base))
		int* words = cast(int*, base)
		for k in range(1, 5): println(itoa(words[k]))
		return y
	return 0


int shapes(dwarf_pair* pair, dwarf_color color):
	dwarf_number n = 3
	int[4] items
	items[3] = n
	return pair.first + color + items[3]


int main():
	dwarf_pair pair
	pair.first = 1
	pair.second = c"one"
	int total = probe(3, 4) + shapes(&pair, dwarf_green)
	println(itoa(total))
	return 0
