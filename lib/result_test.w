import lib.testing
import lib.result


void test_result_new_ok():
	result* r = result_new_ok(42)
	assert_equal(1, result_is_ok(r))
	assert_equal(0, result_is_error(r))
	assert_equal(42, result_value(r))
	assert_equal(0, result_code(r))
	result_free(r)


void test_result_new_error():
	result* r = result_new_error(-2)
	assert_equal(0, result_is_ok(r))
	assert_equal(1, result_is_error(r))
	assert_equal(0, result_value(r))
	assert_equal(-2, result_code(r))
	result_free(r)


void test_result_set_reuses_storage():
	result* r = result_new_error(-13)
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
	result* ok = result_new_from_syscall(3)
	assert_equal(1, result_is_ok(ok))
	assert_equal(3, result_value(ok))
	result_free(ok)

	result* err = result_new_from_syscall(-9)
	assert_equal(1, result_is_error(err))
	assert_equal(-9, result_code(err))
	result_free(err)


void test_result_unwrap_or():
	result* ok = result_new_ok(7)
	result* err = result_new_error(-1)
	assert_equal(7, result_unwrap_or(ok, 99))
	assert_equal(99, result_unwrap_or(err, 99))
	result_free(ok)
	result_free(err)
