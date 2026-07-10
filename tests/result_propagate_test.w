# wbuild: x64
import lib.testing
import lib.result


# Ok path: '?' unwraps the payload; error path: the enclosing function
# returns the operand pointer as its own wresult (layout-safe because
# 'ok'/'code' offsets are identical across instantiations).
wresult[int]* find_number(int key):
	if (key < 0):
		return result_new_error[int](-2)
	return result_new_ok[int](key * 10)


# Propagates a wresult[int]* error through a function whose own payload
# type is char* — a different payload type than the operand's.
wresult[char*]* describe_number(int key):
	int number = find_number(key)?
	if (number > 50):
		return result_new_ok[char*](c"big")
	return result_new_ok[char*](c"small")


# Third link in the chain, with yet another payload type (bool).
wresult[bool]* description_is_big(int key):
	char* description = describe_number(key)?
	return result_new_ok[bool](strcmp(description, c"big") == 0)


# '?' inside a larger expression, and directly on a generic helper call.
wresult[int]* plus_one_of_four():
	return result_new_ok[int](result_new_ok[int](4)? + 1)


# Mixing '?' with normal returns, and using '?' more than once.
wresult[int]* sum_two(int a, int b):
	if (a == b):
		return result_new_error[int](-99)
	int total = find_number(a)? + find_number(b)?
	return result_new_ok[int](total)


void test_ok_path_unwraps():
	wresult[char*]* r = describe_number(9)
	assert_equal(1, result_is_ok[char*](r))
	assert_strings_equal(c"big", result_value[char*](r))
	result_free[char*](r)

	wresult[char*]* small = describe_number(2)
	assert_strings_equal(c"small", result_value[char*](small))
	result_free[char*](small)


void test_error_propagates_through_chain():
	# find_number fails with -2; the error travels through
	# wresult[int]* -> wresult[char*]* -> wresult[bool]* unchanged.
	wresult[bool]* r = description_is_big(-1)
	assert_equal(1, result_is_error[bool](r))
	assert_equal(-2, result_code[bool](r))
	result_free[bool](r)


void test_ok_through_chain():
	wresult[bool]* big = description_is_big(9)
	assert_equal(1, result_is_ok[bool](big))
	assert_equal(1, result_value[bool](big))
	result_free[bool](big)

	wresult[bool]* small = description_is_big(1)
	assert_equal(1, result_is_ok[bool](small))
	assert_equal(0, result_value[bool](small))
	result_free[bool](small)


void test_question_in_larger_expression():
	wresult[int]* r = plus_one_of_four()
	assert_equal(1, result_is_ok[int](r))
	assert_equal(5, result_value[int](r))
	result_free[int](r)


void test_mixed_returns():
	wresult[int]* err = sum_two(3, 3)
	assert_equal(1, result_is_error[int](err))
	assert_equal(-99, result_code[int](err))
	result_free[int](err)

	wresult[int]* propagated = sum_two(-1, 3)
	assert_equal(1, result_is_error[int](propagated))
	assert_equal(-2, result_code[int](propagated))
	result_free[int](propagated)

	wresult[int]* ok = sum_two(2, 3)
	assert_equal(1, result_is_ok[int](ok))
	assert_equal(50, result_value[int](ok))
	result_free[int](ok)
