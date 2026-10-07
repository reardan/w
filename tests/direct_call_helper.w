# Companion module of tests/direct_call_test.w: one half of a mutual
# recursion that crosses an import boundary. dc_even is defined in the
# test itself, after this module is compiled, so the call below is a
# forward reference whose displacement the definition patches.
int dc_even(int n);


int dc_helper_odd(int n):
	if (n == 0): return 0
	return dc_even(n - 1)


# A helper that takes a struct by value, as the compiler's own
# f-string consumers do (the f-string's result is a struct-returning
# call whose stack base equals the enclosing call's).
struct dc_box:
	int lo
	int hi


int dc_box_sum(dc_box b):
	return b.lo + b.hi
