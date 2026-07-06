import lib.testing
import lib.result

/*
Cross-feature coverage for the five language features that landed
together: compound assignment, switch, defer, the generic wresult[T]
result type with postfix '?' propagation, and generic type-argument
inference. Each feature has its own dedicated suite; this one checks
that they compose in a single function and, in particular, that the
'?' error path runs deferred statements before returning (a '?' exit
is a function exit like any 'return').
*/


# Deferred statements append digits here so tests can assert order.
int trace


void mark(int digit):
	trace = trace * 10 + digit


T biggest[T](T a, T b):
	if (a > b):
		return a
	return b


wresult[int]* lookup(int key):
	if (key < 0):
		return result_new_error[int](-7)
	return result_new_ok[int](key)


# defer + '?' + compound assignment + switch + inference in one body.
wresult[int]* score(int key):
	defer mark(9)
	int value = lookup(key)?
	int total = 0
	switch (biggest(value, 2)):
		case 2:
			total += 20
		case 3, 4:
			total += 40
		default:
			total += value
			total *= 2
	return result_new_ok[int](total)


void test_ok_paths_compose():
	trace = 0
	wresult[int]* small = score(1)
	assert_equal(20, result_value[int](small))
	result_free[int](small)

	wresult[int]* mid = score(4)
	assert_equal(40, result_value[int](mid))
	result_free[int](mid)

	wresult[int]* big = score(10)
	assert_equal(20, result_value[int](big))
	result_free[int](big)

	# each of the three calls ran its defer on the normal return path
	assert_equal(999, trace)


void test_error_path_runs_defer():
	trace = 0
	wresult[int]* r = score(-5)
	assert_equal(1, result_is_error[int](r))
	assert_equal(-7, result_code[int](r))
	# the '?' early exit still ran the deferred statement
	assert_equal(9, trace)
	result_free[int](r)


# Inferred generic call used as a switch scrutinee and inside compound
# assignment, with defers stacked LIFO around it.
int mixed_loop():
	defer mark(1)
	defer mark(2)
	int total = 0
	for int i in range(0, 4):
		switch (i):
			case 0, 1:
				total += biggest(i, 1)
			case 2:
				continue
			default:
				total <<= 1
	return total


void test_loop_switch_inference_defer():
	trace = 0
	assert_equal(4, mixed_loop())
	assert_equal(21, trace)
