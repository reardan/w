# wbuild: x64
import lib.testing

# Top-level declarations may carry a compile-time constant initializer
# ('int x = 5' at file scope), stored straight into the global's
# reserved bytes like C does -- no init code runs before main. This
# exists so a REPL session's own spelling round-trips: ':save' writes
# the entries verbatim and the saved file has to compile standalone
# (grammar/program.w's global_initializer).


enum color:
	red
	green
	blue


int plain = 5
int negated = -3
int hexed = 0x1f
char lettered = 'A'
char escaped = '\n'
int enumed = blue
int8 narrow = 100
int16 wider = 3000
int32 widest = 70000
bool flagged = 1
int zeroed = 0

# Source order is declaration order; every value below is independent
# storage, so a later declaration of the same shape does not disturb it.
int first = 11
int second = 22


void test_integer_initializers():
	assert_equal(5, plain)
	assert_equal(-3, negated)
	assert_equal(31, hexed)
	assert_equal(0, zeroed)


void test_char_initializers():
	assert_equal(65, lettered)
	assert_equal(10, escaped)


void test_enum_initializer():
	assert_equal(2, enumed)


void test_narrow_width_initializers():
	# Each width stores only its own bytes; the neighbours stay intact.
	assert_equal(100, narrow)
	assert_equal(3000, wider)
	assert_equal(70000, widest)
	assert_equal(1, flagged)


void test_globals_stay_mutable():
	# A constant initializer is a starting value, not a constant binding.
	plain = plain + 1
	assert_equal(6, plain)
	plain = 5
	assert_equal(5, plain)


void test_independent_storage():
	assert_equal(11, first)
	assert_equal(22, second)
	first = 99
	assert_equal(99, first)
	assert_equal(22, second)
	first = 11
