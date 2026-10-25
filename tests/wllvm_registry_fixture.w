# Differential fixture for tests/wllvm_test.w: the compiler synthesizes
# __w_test_main for a program defining __w_run_tests (as lib/testing.w
# does), and bin/wllvm rebuilds it from the retained forest: the same
# zero-argument test_* functions, in definition order. Not a standalone
# test (no wbuild directive).
void __w_test_main();


int registry_order


void __w_run_tests(char* name, int fn):
	println(name)
	int* test_func = cast(int*, fn)
	test_func()


void test_first():
	registry_order = registry_order * 10 + 1


# Takes an argument, so it is not a test.
void test_with_argument(int n):
	registry_order = registry_order * 10 + n


void test_second():
	registry_order = registry_order * 10 + 2


int main():
	__w_test_main()
	return registry_order
