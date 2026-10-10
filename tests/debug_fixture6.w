# Debuggee for wdbg on a leaf function (debug_test / debug_test_x64): on
# x64, register promotion gives a leaf's whole body to the function
# region (unit O2, compiler/regalloc_scan.w), so the parameter limit and
# the locals k and acc live in caller-saved registers (rsi, rdi, r8-r11)
# rather than callee-saved ones; conditional breakpoints and print must
# still find and read them (debugger/locals.w).
import lib.lib


int leaf_count(int limit):
	int k = 0
	int acc = 0
	while (k < limit):
		acc = acc + k
		k = k + 1
	return acc


int main(int argc, int argv):
	int total = leaf_count(6)
	println(c"leaf done")
	return total
