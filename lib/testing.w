import lib.lib
import lib.assert


# Synthesized by the compiler at the end of every batch compilation that
# defines __w_run_tests below: one __w_run_tests(name, fn) call per
# defined zero-argument test_* function, in definition order
# (compiler/test_registry.w, issue #147). No binary introspection is
# involved, so discovery works identically on ELF, Mach-O, and PE
# output and survives stripped binaries.
void __w_test_main();


# Called by the synthesized __w_test_main for each discovered test.
void __w_run_tests(char* name, int fn):
	println(c"")
	print(c"Run: '")
	print(name)
	print(c"()' -> ")
	print(hex(fn))
	println(c"")
	print_hex(c"test_func: ", fn)

	int* test_func = cast(int*, fn)
	test_func()

	print(c"Test '")
	print(name)
	println(c"()' passed!")


void execute_tests():
	println(c"Running 'test_*' functions.")
	__w_test_main()


int main(int argc, int argv):
	execute_tests()
	println(c"")
	println(c"All tests passed!")
	return 0
