# wbuild: x64
import lib.testing
import lib.process
import lib.container


int print_test_step
int print_test_stop
char* print_test_output


int print_test_writer(int fd, char* data, int length):
	print_test_step = print_test_step + 1
	if (print_test_step == 1): return -4
	if (print_test_step == 2):
		print_test_output[0] = data[0]
		return 1
	if (print_test_stop != 1): return print_test_stop
	for i in range(length): print_test_output[1 + i] = data[i]
	return length


void test_print_checked_retries_short_writes_and_interrupts():
	print_result r
	print_test_output = cast(char*, malloc(8))
	print_test_step = 0
	print_test_stop = 1
	assert_equal(0, print_write_using(print_test_writer, 1, c"abc", 3, &r))
	assert_equal(3, r.transferred)
	assert_equal(0, r.error)
	assert_bytes_equal(c"abc", print_test_output, 3)
	print_test_step = 0
	print_test_stop = -28
	assert_equal(-28, print_write_using(print_test_writer, 1, c"abc", 3, &r))
	assert_equal(1, r.transferred)
	assert_equal(28, r.error)
	print_test_step = 0
	print_test_stop = 0
	assert_equal(-5, print_write_using(print_test_writer, 1, c"abc", 3, &r))
	assert_equal(1, r.transferred)
	assert_equal(5, r.error)
	print_test_step = 0
	print_test_stop = 20
	assert_equal(-5, print_write_using(print_test_writer, 1, c"abc", 3, &r))
	assert_equal(1, r.transferred)
	assert_equal(5, r.error)
	free(print_test_output)


void test_print_checked_descriptor_errors_and_empty_requests():
	print_result r
	assert_equal(0, print_write_checked(-1, c"", 0, &r))
	assert_equal(0, r.transferred)
	assert_equal(-9, print_write_checked(-1, c"x", 1, &r))
	assert_equal(9, r.error)
	assert_equal(0, r.transferred)
	assert_equal(-22, print_write_checked(-1, c"x", -1, &r))


void test_builtin_print_failures_are_sticky_until_cleared():
	# Preserve stdout with F_DUPFD, then exercise the compiler's print
	# lowerings against a real failing descriptor. Restore before asserts.
	int saved = sys_fcntl(1, 0, 3)
	assert1(saved >= 0)
	int full = open(c"/dev/full", 1, 0)
	assert1(full >= 0)
	assert_equal(1, dup2(full, 1))
	close(full)
	print_clear_error(1)
	print(42)
	int int_error = print_last_error(1)
	print_clear_error(1)
	print(c"text")
	int text_error = print_last_error(1)
	print_clear_error(1)
	float32 value = 1.25
	print(value)
	int float_error = print_last_error(1)
	print_clear_error(1)
	println()
	int newline_error = print_last_error(1)
	print_clear_error(1)
	char letter = 'a'
	print(letter)
	int char_error = print_last_error(1)
	print_clear_error(1)
	string text = c"string"
	print(text)
	int string_error = print_last_error(1)
	print_clear_error(1)
	list[string] values = list[string]{s"entry"}
	print(values)
	int list_error = print_last_error(1)
	list_free[string](values)
	print_result r
	int checked_status = print_checked(c"checked", &r)
	close(1)
	println(c"later error")
	int first_error = print_last_error(1)
	dup2(saved, 1)
	close(saved)
	print_clear_error(1)
	assert_equal(28, int_error)
	assert_equal(28, text_error)
	assert_equal(28, float_error)
	assert_equal(28, newline_error)
	assert_equal(28, char_error)
	assert_equal(28, string_error)
	assert_equal(28, list_error)
	assert_equal(28, first_error)
	assert_equal(-28, checked_status)
	assert_equal(28, r.error)
	assert_equal(0, print_last_error(1))
	assert_equal(0, print_last_error(2))
