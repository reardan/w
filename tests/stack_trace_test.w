/*
End-to-end test for lib/stack_trace.w: unwind our own call chain and
check the symbolized frames against the known layout of this file.
stack_trace_collect stores pc values pointing inside each calling
statement, so the expected lines below are the lines of the call
statements themselves. Line numbers are asserted exactly: editing this
file means updating the expectations in main.
*/
import lib.lib
import lib.assert
import lib.stack_trace


char* frames
int frame_count


void st_test_deepest():
	frame_count = stack_trace_collect(frames, 16)


void st_test_middle():
	st_test_deepest()


void st_test_outer():
	st_test_middle()


int frame_at(int index):
	return load_word(frames + index * __word_size__)


int main(int argc, int argv):
	frames = malloc(16 * __word_size__)
	st_test_outer()

	asserts(c"collected at least four frames", frame_count >= 4)

	# The recovered chain, most recent call first
	assert_strings_equal(c"st_test_deepest", stack_trace_symbol(frame_at(0)))
	assert_strings_equal(c"st_test_middle", stack_trace_symbol(frame_at(1)))
	assert_strings_equal(c"st_test_outer", stack_trace_symbol(frame_at(2)))
	assert_strings_equal(c"main", stack_trace_symbol(frame_at(3)))

	# Every frame's pc maps back to the call statement in this file
	assert_equal(19, stack_trace_line(frame_at(0)))
	assert_equal(23, stack_trace_line(frame_at(1)))
	assert_equal(27, stack_trace_line(frame_at(2)))
	assert_equal(36, stack_trace_line(frame_at(3)))

	# Lookups outside any function stay empty instead of trapping
	asserts(c"no symbol for a null pc", stack_trace_symbol(0) == 0)
	assert_equal(0, stack_trace_line(0))

	# Exercise the printer once; the trace lands in the test log
	print_stack_trace()

	println(c"stack_trace_test passed")
	return 0
