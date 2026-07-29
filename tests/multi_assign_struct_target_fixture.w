# A whole-struct target in a parallel assignment is rejected (v1,
# grammar/multi_assign.w): a struct's "value" is its address, so the
# parked temporary would alias instead of swap. Scalar and pointer
# fields work (tests/multi_assign_test.w).
# expect_fail
# expect_stderr: multi-assignment does not support struct values
struct ms_pair:
	int a
	int b


int main():
	ms_pair p
	ms_pair q
	p, q = q, p
	return 0
