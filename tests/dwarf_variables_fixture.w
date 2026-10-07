/*
Fixture for dwarf_variables_test (issue #536): the build target compiles
this for x86 and x64 and runs both, then the test walks their
.debug_info / .debug_abbrev / .debug_frame. The shapes it asserts:
scale's parameters and locals (one in a nested block), a pointer to a
struct with two members, a T[N] descriptor, a void function, and
accumulate's loop locals, which register promotion (unit R2,
compiler/regalloc_scan.w) keeps in callee-saved registers: their
locations are DW_OP_reg<n>, and the FDE records the saved registers.
*/
import lib.lib


struct point:
	int x
	int y


int scale(point* p, int factor):
	int sx = p.x * factor
	int sy = p.y * factor
	if (sx > 0):
		int inner = sx + sy
		return inner
	return sx


void report(int value):
	int[3] digits
	digits[0] = value
	if (digits[0] != 35):
		println(c"wrong value")


int accumulate(int n):
	int i = 0
	int total = 0
	while (i < n):
		total = total + i
		i = i + 1
	return total


int main():
	point pt
	pt.x = 3
	pt.y = 4
	int total = scale(&pt, 5)
	report(total)
	if (accumulate(5) != 10): println(c"wrong sum")
	println(c"hello from dwarf variables fixture")
	return 0
