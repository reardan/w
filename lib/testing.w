import lib.lib
import lib.assert
import lib.crash
import lib.format


# Floats within 0.0001 of each other.
void assert_near(float want, float got):
	float diff = want - got
	if (diff < 0.0): diff = 0.0 - diff
	if (diff > 0.0001):
		print2(c"Assertion failed. wanted float(")
		print2(ftoa(want))
		print2(c") got float(")
		print2(ftoa(got))
		println2(c")")
		print_stack_trace()
		exit(1)


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
	# A test that dies of SIGSEGV/SIGBUS/SIGFPE/SIGILL reports a
	# symbolized stack trace before the unchanged signal death
	# (lib/crash.w; no-op off Linux x86/x64).
	crash_handler_install()
	execute_tests()
	println(c"")
	println(c"All tests passed!")
	return 0
