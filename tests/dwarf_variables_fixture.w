/*
Fixture for dwarf_variables_test (issue #536): the build target compiles
this for x86 and x64 and runs both, then the test walks their
.debug_info / .debug_abbrev / .debug_frame. The shapes it asserts:
scale's parameters and locals (one in a nested block), a pointer to a
struct with two members, a T[N] descriptor, and a void function.
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


int main():
	point pt
	pt.x = 3
	pt.y = 4
	int total = scale(&pt, 5)
	report(total)
	println(c"hello from dwarf variables fixture")
	return 0
