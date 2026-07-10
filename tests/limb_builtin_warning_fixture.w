# The limb intrinsics (grammar/limb_builtin.w, #213) check their
# arguments like ordinary function calls: int operands, and an int*
# result pointer for mul_wide/add_carry.
# expect_stderr: warning: function 'mul_hi' argument 1 type mismatch: expected 'int', got 'char*'
# expect_stderr: warning: function 'mul_wide' argument 3 type mismatch: expected 'int*', got 'char*'
# expect_stderr: warning: function 'add_carry' argument 3 type mismatch: expected 'int*', got 'int'
import lib.lib


int main(int argc, int argv):
	int hi = 0
	int lo = mul_hi(c"oops", 3)
	lo = mul_wide(2, 3, c"oops")
	lo = add_carry(lo, 5, hi)
	return lo
