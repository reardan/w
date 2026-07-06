import lib.testing
import lib.result


void test_result_new_ok():
	wresult[int]* r = result_new_ok[int](42)
	assert_equal(1, result_is_ok[int](r))
	assert_equal(0, result_is_error[int](r))
	assert_equal(42, result_value[int](r))
	assert_equal(0, result_code[int](r))
	result_free[int](r)


void test_result_new_error():
	wresult[int]* r = result_new_error[int](-2)
	assert_equal(0, result_is_ok[int](r))
	assert_equal(1, result_is_error[int](r))
	assert_equal(0, result_value[int](r))
	assert_equal(-2, result_code[int](r))
	result_free[int](r)


void test_result_set_reuses_storage():
	wresult[int]* r = result_new_error[int](-13)
	result_set_ok[int](r, 9)
	assert_equal(1, result_is_ok[int](r))
	assert_equal(9, result_value[int](r))
	assert_equal(0, result_code[int](r))
	result_set_error[int](r, -22)
	assert_equal(1, result_is_error[int](r))
	assert_equal(-22, result_code[int](r))
	assert_equal(0, result_value[int](r))
	result_free[int](r)


void test_result_from_syscall():
	wresult[int]* zero = result_new_from_syscall(0)
	assert_equal(1, result_is_ok[int](zero))
	assert_equal(0, result_value[int](zero))
	result_free[int](zero)

	wresult[int]* ok = result_new_from_syscall(3)
	assert_equal(1, result_is_ok[int](ok))
	assert_equal(3, result_value[int](ok))
	result_free[int](ok)

	wresult[int]* high_address = result_new_from_syscall(0x80000000)
	assert_equal(1, result_is_ok[int](high_address))
	assert_equal(0x80000000, result_value[int](high_address))
	result_free[int](high_address)

	wresult[int]* err = result_new_from_syscall(-9)
	assert_equal(1, result_is_error[int](err))
	assert_equal(-9, result_code[int](err))
	result_free[int](err)


void test_result_unwrap_or():
	wresult[int]* ok = result_new_ok[int](7)
	wresult[int]* err = result_new_error[int](-1)
	assert_equal(7, result_unwrap_or[int](ok, 99))
	assert_equal(99, result_unwrap_or[int](err, 99))
	result_free[int](ok)
	result_free[int](err)


void test_result_take_or():
	assert_equal(7, result_take_or[int](result_new_ok[int](7), 99))
	assert_equal(99, result_take_or[int](result_new_error[int](-1), 99))


void test_result_name_available_for_locals():
	int result = 5
	result = 6
	assert_equal(6, result)


void test_result_pointer_payload():
	char* payload = malloc(16)
	strcpy(payload, c"carried")
	wresult[char*]* r = result_new_ok[char*](payload)
	assert_equal(1, result_is_ok[char*](r))
	char* got = result_take_or[char*](r, 0)
	assert_strings_equal(c"carried", got)
	free(got)


void test_result_char_payload():
	wresult[char]* r = result_new_ok[char]('x')
	assert_equal(1, result_is_ok[char](r))
	assert_equal('x', result_value[char](r))
	result_free[char](r)


void test_result_bool_payload():
	wresult[bool]* r = result_new_ok[bool](true)
	assert_equal(1, result_is_ok[bool](r))
	assert_equal(1, result_value[bool](r))
	assert_equal(0, result_take_or[bool](result_new_error[bool](-5), false))
	result_free[bool](r)
