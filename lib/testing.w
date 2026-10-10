/*
Test runner for `test_*` functions (docs/testing.md).

A program that imports lib.testing gets this file's main(): the
compiler synthesizes __w_test_main, which calls __w_run_tests(name, fn)
once per zero-argument test_* function in definition order, and
__w_run_tests runs each one. A failing assertion (lib/assert.w) prints
its message and a stack trace, reports the completed tests in a
summary, and exits 1 at once.

Controls, all optional and off by default (output without them is the
historical format, plus one "Summary:" line before "All tests passed!"):

  W_TEST_FILTER=sub[,sub...]   run only tests whose name contains one of
  --filter sub[,sub...]        the comma-separated substrings; the others
  --filter=sub[,sub...]        are counted as skipped. A filter that
                               matches no test fails the run (a typo
                               must not pass silently). The argv form
                               wins over the environment.
  --shard I/N                  run definition indices congruent to I modulo N
  --shard=I/N                  (zero-based, before filtering). Empty shards fail.
  --list                       print the test names (after filtering),
                               one per line, and run nothing.
  W_TEST_LEAKS=1               leak check: run under the guard-page debug
                               allocator (lib/memory_debug.w) and fail a
                               test that returns with heap blocks it
                               allocated still live. The remaining tests
                               still run; the summary names the leakers.
                               W_DEBUG_ALLOC=1 alone keeps its old meaning
                               (overflow/use-after-free trapping, no leak
                               verdict).

Arguments other than --filter/--shard/--list are left alone, so tests that read
their own argv (x25519_test's --iterated-1000) keep working.
*/
import lib.lib
import lib.assert
import lib.crash
import lib.format
import lib.env


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
		assert_failure_exit()


# Synthesized by the compiler at the end of every batch compilation that
# defines __w_run_tests below: one __w_run_tests(name, fn) call per
# defined zero-argument test_* function, in definition order
# (compiler/test_registry.w, issue #147). No binary introspection is
# involved, so discovery works identically on ELF, Mach-O, and PE
# output and survives stripped binaries.
void __w_test_main();


char* testing_filter        # comma-separated substrings, 0 = run all
int testing_shard_count     # 0 = unsharded; positive N from --shard I/N
int testing_shard_index     # zero-based I
int testing_test_index      # definition ordinal, including filtered tests
int testing_list_only       # --list: print names, run nothing
int testing_leak_check      # W_TEST_LEAKS: per-test leak verdicts
int testing_passed
int testing_skipped
int testing_leaked          # tests that failed the leak check
int testing_assert_failed
char* testing_current_test
char* testing_leakers       # their names, ", "-joined (0 when none)


# Does name contain needle[0..needle_len)?
int testing_contains(char* name, char* needle, int needle_len):
	if (needle_len == 0): return 1
	int i = 0
	while (name[i] != 0):
		int j = 0
		while ((j < needle_len) && (name[i + j] != 0) && (name[i + j] == needle[j])): j = j + 1
		if (j == needle_len): return 1
		i = i + 1
	return 0


int testing_has_prefix(char* s, char* prefix):
	int i = 0
	while (prefix[i] != 0):
		if (s[i] != prefix[i]): return 0
		i = i + 1
	return 1


# Parse strictly, with the same limit on every target. Do not let overflowing
# shard counts wrap into a valid selection on 32-bit hosts.
int testing_parse_shard(char* value):
	int[2] parts
	int pos = 0
	for part in range(2):
		int start = pos
		int number = 0
		while (value[pos] >= '0' && value[pos] <= '9'):
			int digit = value[pos] - '0'
			if (number > 214748364 || (number == 214748364 && digit > 7)): return 0
			number = number * 10 + digit
			pos = pos + 1
		if (pos == start): return 0
		parts[part] = number
		if (part == 0):
			if (value[pos] != '/'): return 0
			pos = pos + 1
	if (value[pos] != 0 || parts[1] == 0 || parts[0] >= parts[1]): return 0
	testing_shard_index = parts[0]
	testing_shard_count = parts[1]
	return 1


# Does name match the filter (any comma-separated piece; empty pieces
# are ignored, so "a,,b" and a trailing comma are harmless)?
int testing_selected(char* name):
	if (testing_filter == 0): return 1
	char* f = testing_filter
	int start = 0
	int i = 0
	int any_piece = 0
	while (1):
		if ((f[i] == ',') || (f[i] == 0)):
			int len = i - start
			if (len > 0):
				any_piece = 1
				if (testing_contains(name, &f[start], len)): return 1
			if (f[i] == 0):
				# A filter made only of commas selects everything.
				return any_piece == 0
			start = i + 1
		i = i + 1
	return 0


/* Leak check. Reads lib/memory_debug.w's bookkeeping table directly:
debug_alloc_report_leaks() prints every live block, which cannot tell
a test's own leaks from blocks allocated before it started. Entries
are appended in allocation order and never removed, so the blocks a
test allocated are exactly the entries from its starting count on;
any still marked live (freed == 0) when it returns are its leaks. */

int testing_live_between(int first, int last):
	int n = 0
	for i in range(first, last):
		if (debug_tbl_freed[i] == 0): n = n + 1
	return n


# last is the table length snapshotted when the test returned: printing
# below allocates (itoa), and those blocks are not the test's.
void testing_report_leaks(char* name, int first, int last):
	int blocks = 0
	int bytes = 0
	for i in range(first, last):
		if (debug_tbl_freed[i] == 0):
			blocks = blocks + 1
			bytes = bytes + debug_tbl_size[i]
	print(c"LEAK: '")
	print(name)
	print(c"()' returned with ")
	print(itoa(blocks))
	print(c" heap block(s), ")
	print(itoa(bytes))
	println(c" byte(s) still allocated:")
	int shown = 0
	for i in range(first, last):
		if ((debug_tbl_freed[i] == 0) && (shown < 10)):
			print(c"  ")
			print(itoa(debug_tbl_size[i]))
			print(c" byte(s) at ")
			println(hex(debug_tbl_ptr[i]))
			shown = shown + 1
	if (blocks > shown): println(c"  ...")


void testing_note_leaker(char* name):
	testing_leaked = testing_leaked + 1
	if (testing_leakers == 0):
		testing_leakers = name
		return
	char* a = strjoin(testing_leakers, c", ")
	testing_leakers = strjoin(a, name)


# Called by the synthesized __w_test_main for each discovered test.
void __w_run_tests(char* name, int fn):
	int index = testing_test_index
	testing_test_index = testing_test_index + 1
	if (testing_shard_count > 0 && index % testing_shard_count != testing_shard_index):
		testing_skipped = testing_skipped + 1
		return
	if (testing_selected(name) == 0):
		testing_skipped = testing_skipped + 1
		return
	if (testing_list_only):
		println(name)
		testing_passed = testing_passed + 1
		return
	println(c"")
	print(c"Run: '")
	print(name)
	print(c"()' -> ")
	print(hex(fn))
	println(c"")
	print_hex(c"test_func: ", fn)

	int first = debug_tbl_count
	int* test_func = cast(int*, fn)
	testing_current_test = name
	test_func()
	testing_current_test = 0

	int last = debug_tbl_count
	if (testing_leak_check && (testing_live_between(first, last) > 0)):
		testing_report_leaks(name, first, last)
		testing_note_leaker(name)
		return
	testing_passed = testing_passed + 1
	print(c"Test '")
	print(name)
	println(c"()' passed!")


void execute_tests():
	if (testing_list_only == 0): println(c"Running 'test_*' functions.")
	__w_test_main()


# Reads --filter/--shard/--list from argv and W_TEST_FILTER/W_TEST_LEAKS from the
# environment. argv is the kernel's word-sized char* vector.
void testing_configure(int argc, int argv):
	char* env_filter = env_get(c"W_TEST_FILTER")
	if ((env_filter != 0) && (env_filter[0] != 0)): testing_filter = env_filter
	char** args = cast(char**, argv)
	int i = 1
	while ((args != 0) && (i < argc)):
		char* a = env_entry_at(args, i)
		if (strcmp(a, c"--list") == 0): testing_list_only = 1
		elif (strcmp(a, c"--filter") == 0):
			if (i + 1 >= argc):
				println2(c"--filter requires a value")
				exit(2)
			i = i + 1
			testing_filter = env_entry_at(args, i)
		elif (testing_has_prefix(a, c"--filter=")): testing_filter = &a[9]
		elif (strcmp(a, c"--shard") == 0 || testing_has_prefix(a, c"--shard=")):
			char* value = &a[8]
			if (strcmp(a, c"--shard") == 0):
				if (i + 1 >= argc):
					println2(c"--shard requires I/N (zero-based index, positive count)")
					exit(2)
				i = i + 1
				value = env_entry_at(args, i)
			if (testing_parse_shard(value) == 0):
				println2(c"--shard requires I/N with 0 <= I < N <= 2147483647")
				exit(2)
		i = i + 1
	char* leaks = env_get(c"W_TEST_LEAKS")
	if ((leaks != 0) && (leaks[0] != 0) && (strcmp(leaks, c"0") != 0)):
		# The backend is fixed on the first allocation; before it, the
		# runner can still pick the debug one itself.
		if (malloc_mode_determined == 0): malloc_force_debug_mode()
		if (malloc_debug_mode == 0):
			println2(c"W_TEST_LEAKS: the heap was already in use before main(); also set W_DEBUG_ALLOC=1")
			exit(2)
		testing_leak_check = 1


void testing_print_summary():
	print(c"Summary: ")
	print(itoa(testing_passed))
	print(c" passed, ")
	print(itoa(testing_leaked + testing_assert_failed))
	print(c" failed, ")
	print(itoa(testing_skipped))
	print(c" skipped")
	if (testing_filter != 0):
		print(c" (filter '")
		print(testing_filter)
		print(c"')")
	if (testing_shard_count > 0):
		print(c" [shard ")
		print(itoa(testing_shard_index))
		print(c"/")
		print(itoa(testing_shard_count))
		print(c"]")
	if (testing_leak_check): print(c" [leak check]")
	println(c"")
	if (testing_leakers != 0):
		print(c"Leaked: ")
		println(testing_leakers)


# Called after the assertion's normal stderr diagnostic. Later tests
# remain unrun (not mislabeled as filtered/skipped); fail-fast is unchanged.
void testing_assertion_failed():
	if (testing_current_test == 0): return
	testing_assert_failed = testing_assert_failed + 1
	println(c"")
	testing_print_summary()
	print(c"Tests FAILED: assertion in '")
	print(testing_current_test)
	println(c"()'.")


int main(int argc, int argv):
	# First, so W_TEST_LEAKS can still choose the allocator backend.
	testing_configure(argc, argv)
	# A test that dies of SIGSEGV/SIGBUS/SIGFPE/SIGILL reports a
	# symbolized stack trace before the unchanged signal death
	# (lib/crash.w; no-op off Linux x86/x64).
	crash_handler_install()
	assert_failure_hook = testing_assertion_failed
	execute_tests()
	if (testing_list_only):
		if (testing_shard_count > 0 && testing_passed == 0):
			println2(c"Tests FAILED: the shard selected no test (after filtering).")
			return 1
		if ((testing_filter != 0) && (testing_passed == 0)):
			println2(c"Tests FAILED: the filter matched no test.")
			return 1
		return 0
	println(c"")
	testing_print_summary()
	if (testing_leaked > 0):
		println(c"Tests FAILED: leak check.")
		return 1
	if (testing_shard_count > 0 && testing_passed == 0):
		println(c"Tests FAILED: the shard selected no test (after filtering).")
		return 1
	if ((testing_filter != 0) && (testing_passed == 0)):
		println(c"Tests FAILED: the filter matched no test.")
		return 1
	println(c"All tests passed!")
	return 0
