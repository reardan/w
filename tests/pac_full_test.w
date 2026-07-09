# End-to-end fixture for --pac=full on arm64 targets: every W code
# pointer is signed at materialization (paciza, IA key, zero
# discriminator) and authenticated at the indirect call (blraaz), so
# this exercises each way a function's address becomes a value and is
# consumed: direct calls, function-pointer variables, pointers passed
# as arguments, callbacks captured by the list runtime, generator
# resume addresses crossing gen_switch, and function-pointer equality
# (signing is deterministic, so two materializations still compare
# equal). The source runs unchanged at --pac=off/ret and on every
# target; pac_flag_test reuses the same binary for its byte-pattern
# assertions.
import lib.lib
import lib.assert
import lib.generator


type pac_binop = fn(int, int) -> int


int pac_add(int a, int b):
	return a + b


int pac_desc(int a, int b):
	return b - a


generator int pac_counter(int n):
	int i = 0
	while (i < n):
		yield i
		i = i + 1


int pac_apply(pac_binop* f, int a, int b):
	return f(a, b)


int main(int argc, int argv):
	# direct call: materialize (signed) + blraaz
	assert_equal(7, pac_add(3, 4))

	# call through a function-pointer variable (signed value at rest)
	pac_binop* f = pac_add
	assert_equal(12, f(5, 7))

	# signed pointer passed as an argument and called in the callee
	assert_equal(9, pac_apply(pac_add, 4, 5))

	# deterministic signing: a second materialization compares equal
	pac_binop* g = pac_add
	assert_equal(cast(int, f), cast(int, g))

	# callback stored by the list runtime and invoked from w_list code
	list[int] l = list[int]{3, 1, 4, 1, 5}
	l.sort_by(pac_desc)
	assert_equal(5, l[0])
	assert_equal(1, l[4])

	# generator: resume addresses cross gen_switch signed (zero
	# discriminator, matching the seeded entry from __w_gen_create)
	int sum = 0
	generator* c = pac_counter(5)
	while (gen_next(c)):
		sum = sum + gen_value(c)
	gen_free(c)
	assert_equal(10, sum)

	println(c"pac full OK")
	return 0
