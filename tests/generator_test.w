# wbuild: x64
import lib.testing
import lib.generator


generator int counter(int n):
	int i = 0
	while (i < n):
		yield i
		i = i + 1


generator int from_to(int start, int end):
	int i = start
	while (i < end):
		yield i
		i = i + 1


generator int empty():
	return


generator int stops_early(int n):
	int i = 0
	while (i < n):
		if (i == 3):
			return
		yield i
		i = i + 1


# A generator consuming another generator: doubles each value of an
# inner counter.
generator int doubled(int n):
	generator* inner = counter(n)
	while (gen_next(inner)):
		yield gen_value(inner) * 2
	gen_free(inner)


# yield inside nested control flow: a loop inside an if inside a while
generator int nested_flow(int n):
	int i = 0
	while (i < n):
		if (i % 2 == 0):
			int j = 0
			while (j < 2):
				yield i * 10 + j
				j = j + 1
		i = i + 1


void test_basic_counter_while_loop():
	generator* g = counter(5)
	int sum = 0
	int count = 0
	while (gen_next(g)):
		sum = sum + gen_value(g)
		count = count + 1
	assert_equal(10, sum) /* 0+1+2+3+4 */
	assert_equal(5, count)
	assert_equal(1, gen_done(g))
	gen_free(g)


void test_generator_with_arguments():
	generator* g = from_to(10, 14)
	int sum = 0
	while (gen_next(g)):
		sum = sum + gen_value(g)
	assert_equal(46, sum) /* 10+11+12+13 */
	gen_free(g)


void test_multiple_live_generators_interleaved():
	generator* a = counter(3)
	generator* b = from_to(100, 103)
	int sum = 0
	while (gen_next(a)):
		gen_next(b)
		sum = sum + gen_value(a) + gen_value(b)
	assert_equal(306, sum) /* (0+100)+(1+101)+(2+102) */
	assert_equal(1, gen_done(a))
	# b yielded 3 values but was never resumed a 4th time: still suspended
	assert_equal(0, gen_done(b))
	gen_free(a)
	gen_free(b) /* frees the still-suspended generator */


void test_empty_generator_immediately_done():
	generator* g = empty()
	assert_equal(0, gen_done(g)) /* body has not run yet */
	assert_equal(0, gen_next(g))
	assert_equal(1, gen_done(g))
	gen_free(g)


void test_return_stops_generator():
	generator* g = stops_early(10)
	int count = 0
	while (gen_next(g)):
		count = count + 1
	assert_equal(3, count) /* 0, 1, 2 then return */
	gen_free(g)


void test_nested_generators():
	generator* g = doubled(4)
	int sum = 0
	while (gen_next(g)):
		sum = sum + gen_value(g)
	assert_equal(12, sum) /* 0+2+4+6 */
	gen_free(g)


void test_for_loop_over_generator():
	int sum = 0
	for int x in counter(5):
		sum = sum + x
	assert_equal(10, sum)


void test_for_loop_break():
	# break must not corrupt the stack; the loop frees the suspended
	# generator on the break edge
	int sum = 0
	for int x in counter(100):
		if (x == 4):
			break
		sum = sum + x
	assert_equal(6, sum) /* 0+1+2+3 */


void test_for_loop_continue():
	int sum = 0
	for int x in counter(6):
		if (x % 2 == 1):
			continue
		sum = sum + x
	assert_equal(6, sum) /* 0+2+4 */


void test_nested_for_loops_over_generators():
	int sum = 0
	for int x in counter(3):
		for int y in counter(2):
			sum = sum + x * 10 + y
	assert_equal(63, sum) /* (0+1)+(10+11)+(20+21) */


void test_yield_in_nested_control_flow():
	generator* g = nested_flow(4)
	int values = 0
	int count = 0
	while (gen_next(g)):
		values = values + gen_value(g)
		count = count + 1
	assert_equal(4, count) /* i=0: 0,1 ; i=2: 20,21 */
	assert_equal(42, values)
	gen_free(g)


void test_gen_next_after_done_returns_zero():
	generator* g = counter(1)
	assert_equal(1, gen_next(g))
	assert_equal(0, gen_next(g))
	assert_equal(0, gen_next(g))
	assert_equal(0, gen_next(g))
	assert_equal(1, gen_done(g))
	gen_free(g)


void test_gen_free_abandoned_generator():
	# Abandon after two of five values: gen_free must munmap the still
	# live stack without resuming the body
	generator* g = counter(5)
	gen_next(g)
	gen_next(g)
	assert_equal(1, gen_value(g))
	assert_equal(0, gen_done(g))
	gen_free(g)


void test_many_generators():
	# 64KB stacks: dozens of live generators plus create/free churn
	int round = 0
	while (round < 50):
		generator* g = counter(4)
		int sum = 0
		while (gen_next(g)):
			sum = sum + gen_value(g)
		assert_equal(6, sum)
		gen_free(g)
		round = round + 1


generator char* words():
	yield c"alpha"
	yield c"beta"


void test_pointer_yield_type():
	generator* g = words()
	assert_equal(1, gen_next(g))
	char* w = cast(char*, gen_value(g))
	assert_equal('a', w[0])
	assert_equal(1, gen_next(g))
	w = cast(char*, gen_value(g))
	assert_equal('b', w[0])
	assert_equal(0, gen_next(g))
	gen_free(g)
