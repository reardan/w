# wbuild: x64
/*
lib/crash.w control test: installing the fatal-signal reporter must not
disturb a program that does not crash - it exits 0 with no report -
and the stack-trace machinery still works normally afterwards. The
deliberately-crashing side lives in tests/crash_null_deref_fixture.w
and tests/crash_div_zero_fixture.w, run by the hand-written
crash_trace_test / crash_trace_x64_test targets with expect_fail.
*/
import lib.lib
import lib.assert
import lib.crash


char* ci_frames
int ci_count


void ci_collect():
	ci_count = stack_trace_collect(ci_frames, 8)


int main(int argc, int argv):
	crash_handler_install()
	asserts(c"install marked the handler active", crash_installed == 1)
	# Installing twice stays a quiet no-op
	crash_handler_install()

	# Ordinary work is unaffected
	int total = 0
	int i = 0
	while (i < 1000):
		total = total + i
		i = i + 1
	assert_equal(499500, total)

	# The shared symbolization machinery still resolves this call chain
	ci_frames = malloc(8 * __word_size__)
	ci_collect()
	asserts(c"collected at least two frames", ci_count >= 2)
	assert_strings_equal(c"ci_collect", stack_trace_symbol(load_word(ci_frames)))

	println(c"crash_install_test passed")
	return 0
