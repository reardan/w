/*
Fixture for dwarf_variables_test (issue #536): the build target compiles
this for x86 and x64 and runs both, then the test walks their
.debug_info / .debug_abbrev / .debug_frame. The shapes it asserts:
scale's parameters and locals (one in a nested block), a pointer to a
struct with two members, a T[N] descriptor, a void function, and
accumulate's loop locals, which register promotion (unit R2,
compiler/regalloc_scan.w) keeps in callee-saved registers: their
locations are DW_OP_reg<n>, and the FDE records the saved registers.
scale and accumulate call fixture_tick inside a loop, which keeps both
off the x64 function region (unit O2; a call outside the loops would
only spill the region around itself); leaf_sum is on it, so its pointer
argument and locals live in caller-saved registers there (DW_OP_reg4/5
are rsi/rdi in the DWARF numbering, r8-r11 keep their numbers).
*/
import lib.lib


struct point:
	int x
	int y


int fixture_ticks


# It calls (itself), so no call of it is a leaf the scan could inline.
void fixture_tick(int depth):
	fixture_ticks = fixture_ticks + 1
	if (depth > 0): fixture_tick(depth - 1)


int scale(point* p, int factor):
	while (fixture_ticks < 1): fixture_tick(0)
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
		fixture_tick(0)
		i = i + 1
	return total


int leaf_sum(point* q, int n):
	int acc = 0
	int k = 0
	while (k < n):
		acc = acc + q.x + q.y
		acc += k
		k = k + 1
	return acc


int main():
	point pt
	pt.x = 3
	pt.y = 4
	int total = scale(&pt, 5)
	report(total)
	if (accumulate(5) != 10): println(c"wrong sum")
	if (leaf_sum(&pt, 3) != 24): println(c"wrong leaf sum")
	println(c"hello from dwarf variables fixture")
	return 0
