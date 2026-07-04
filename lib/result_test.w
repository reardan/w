import lib.testing
import lib.result


void test_result_new_ok():
	wresult* r = result_new_ok(42)
	assert_equal(1, result_is_ok(r))
	assert_equal(0, result_is_error(r))
	assert_equal(42, result_value(r))
	assert_equal(0, result_code(r))
	result_free(r)


void test_result_new_error():
	wresult* r = result_new_error(-2)
	assert_equal(0, result_is_ok(r))
	assert_equal(1, result_is_error(r))
	assert_equal(0, result_value(r))
	assert_equal(-2, result_code(r))
	result_free(r)


void test_result_set_reuses_storage():
	wresult* r = result_new_error(-13)
	result_set_ok(r, 9)
	assert_equal(1, result_is_ok(r))
	assert_equal(9, result_value(r))
	assert_equal(0, result_code(r))
	result_set_error(r, -22)
	assert_equal(1, result_is_error(r))
	assert_equal(-22, result_code(r))
	assert_equal(0, result_value(r))
	result_free(r)


void test_result_from_syscall():
	wresult* zero = result_new_from_syscall(0)
	assert_equal(1, result_is_ok(zero))
	assert_equal(0, result_value(zero))
	result_free(zero)

	wresult* ok = result_new_from_syscall(3)
	assert_equal(1, result_is_ok(ok))
	assert_equal(3, result_value(ok))
	result_free(ok)

	wresult* high_address = result_new_from_syscall(0x80000000)
	assert_equal(1, result_is_ok(high_address))
	assert_equal(0x80000000, result_value(high_address))
	result_free(high_address)

	wresult* err = result_new_from_syscall(-9)
	assert_equal(1, result_is_error(err))
	assert_equal(-9, result_code(err))
	result_free(err)


void test_result_unwrap_or():
	wresult* ok = result_new_ok(7)
	wresult* err = result_new_error(-1)
	assert_equal(7, result_unwrap_or(ok, 99))
	assert_equal(99, result_unwrap_or(err, 99))
	result_free(ok)
	result_free(err)


void test_result_take_or():
	assert_equal(7, result_take_or(result_new_ok(7), 99))
	assert_equal(99, result_take_or(result_new_error(-1), 99))


void test_result_name_available_for_locals():
	int result = 5
	result = 6
	assert_equal(6, result)


void test_result_pointer_payload():
	char* payload = malloc(16)
	strcpy(payload, "carried")
	wresult* r = result_new_ok(cast(int, payload))
	char* got = cast(char*, result_take_or(r, 0))
	assert_strings_equal("carried", got)
	free(got)
