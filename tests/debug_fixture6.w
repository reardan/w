# Debuggee for wdbg on a leaf function (debug_test / debug_test_x64): on
# x64, register promotion gives a leaf's whole body to the function
# region (unit O2, compiler/regalloc_scan.w), so the parameter limit and
# the locals k and acc live in caller-saved registers (rsi, rdi, r8-r11)
# rather than callee-saved ones; conditional breakpoints and print must
# still find and read them (debugger/locals.w). main makes its calls
# outside any loop, so it is on the region too: on x64 spin sits in a
# caller-saved register that the call to leaf_count spills to spin's
# stack word, which is where 'up' then 'p spin' must read it (base
# takes a callee-saved one).
import lib.lib


int leaf_count(int limit):
	int k = 0
	int acc = 0
	while (k < limit):
		acc = acc + k
		k = k + 1
	return acc


int main(int argc, int argv):
	int base = argc + 40
	int spin = 0
	while (spin < base): spin = spin + 1
	int total = leaf_count(6) + base
	println(c"leaf done")
	return total - spin
