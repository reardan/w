# wbuild: x64 arch=arm64
/*
Frame-pointer unwinding (lib/stack_trace.w st_chain, issue #378): a
deep, alternating recursion must come back from stack_trace_collect as
exactly the call path - every frame, in order, ending at main - with no
stale frames even when a local on the stack holds a value that looks
exactly like a live return address (the heuristic return-address scan
reports such a decoy as a frame; the chain walk never looks at it).
*/
import lib.lib
import lib.assert
import lib.stack_trace


char* frames
int frame_count
int decoy_return  /* a real return address, captured from decoy_caller */


void decoy_leaf():
	char* buf = malloc(4 * __word_size__)
	int n = stack_trace_collect(buf, 4)
	asserts(c"decoy path collected", n >= 1)
	# stack_trace_collect stores return address - 1
	decoy_return = load_word(buf) + 1
	free(buf)


void decoy_caller():
	decoy_leaf()


void chain_leaf():
	# A live local holding a genuine return address into decoy_caller:
	# a stack scan would take it for a frame.
	int decoy = decoy_return
	frame_count = stack_trace_collect(frames, 256)
	asserts(c"decoy stays live", decoy == decoy_return)


void chain_b(int n);


void chain_a(int n):
	if (n == 0):
		chain_leaf()
	else:
		chain_b(n)


void chain_b(int n):
	chain_a(n - 1)


int frame_at(int index):
	return load_word(frames + index * __word_size__)


int main(int argc, int argv):
	frames = malloc(256 * __word_size__)
	decoy_caller()
	asserts(c"decoy captured", decoy_return != 0)
	int depth = 20
	chain_a(depth)

	# chain_leaf, then chain_a(0), then (chain_b, chain_a) per level, then main
	int expected = 1 + 1 + 2 * depth + 1
	assert_equal(expected, frame_count)
	asserts(c"the trace came from the frame-pointer chain", st_unwind_exact == 1)
	assert_strings_equal(c"chain_leaf", stack_trace_symbol(frame_at(0)))
	assert_strings_equal(c"chain_a", stack_trace_symbol(frame_at(1)))
	for k in range(depth):
		assert_strings_equal(c"chain_b", stack_trace_symbol(frame_at(2 + 2 * k)))
		assert_strings_equal(c"chain_a", stack_trace_symbol(frame_at(3 + 2 * k)))
	assert_strings_equal(c"main", stack_trace_symbol(frame_at(expected - 1)))
	# the call statements: chain_a's leaf and recursive calls, chain_b's call
	assert_equal(46, stack_trace_line(frame_at(1)))
	assert_equal(52, stack_trace_line(frame_at(2)))
	assert_equal(48, stack_trace_line(frame_at(3)))
	assert_equal(64, stack_trace_line(frame_at(expected - 1)))
	println(c"stack_trace_chain_test passed")
	return 0
