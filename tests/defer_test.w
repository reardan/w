import lib.testing
# wbuild: x64

/*
Go-style 'defer' statements (docs/projects/defer.md): deferred simple
statements run in LIFO order at every function exit — before each
'return' and at the fall-through end. The deferred expression is
re-parsed and re-emitted at each exit point, so it is evaluated at
EXIT TIME (arguments are not captured at defer time, unlike Go).
*/


# Deferred statements append digits to this trace so tests can assert
# both WHAT ran and in WHICH order.
int trace


void mark(int digit):
	trace = trace * 10 + digit


# --- single defer runs at the fall-through end ---

void single_defer_helper():
	mark(1)
	defer mark(2)
	mark(3)


void test_single_defer_fall_through():
	trace = 0
	single_defer_helper()
	assert_equal(132, trace)


# --- multiple defers run in LIFO order ---

void lifo_helper():
	defer mark(1)
	defer mark(2)
	defer mark(3)
	mark(4)


void test_defers_run_lifo():
	trace = 0
	lifo_helper()
	assert_equal(4321, trace)


# --- defer runs before an early return taken in a branch ---

int early_return_helper(int n):
	defer mark(9)
	if (n == 1):
		mark(1)
		return 10
	mark(2)
	return 20


void test_defer_before_early_return():
	trace = 0
	assert_equal(10, early_return_helper(1))
	assert_equal(19, trace)
	trace = 0
	assert_equal(20, early_return_helper(2))
	assert_equal(29, trace)


# --- defers run on every return path ---

int three_returns(int n):
	defer mark(7)
	if (n == 1):
		return 100
	if (n == 2):
		return 200
	return 300


void test_defer_on_every_return_path():
	trace = 0
	assert_equal(100, three_returns(1))
	assert_equal(7, trace)
	trace = 0
	assert_equal(200, three_returns(2))
	assert_equal(7, trace)
	trace = 0
	assert_equal(300, three_returns(3))
	assert_equal(7, trace)


# --- exit-time evaluation: the deferred expression sees mutations that
# --- happen after the defer statement (documented v1 semantics)

int exit_time_helper():
	int x = 1
	defer mark(x)
	x = 2
	return x


void test_defer_evaluates_at_exit_time():
	trace = 0
	assert_equal(2, exit_time_helper())
	assert_equal(2, trace)


# --- a defer referencing a local still resolves correctly when the
# --- exit point sits behind additional local declarations (deeper
# --- stack than at registration time)

int deep_stack_helper(int n):
	int a = 5
	defer mark(a)
	if (n == 1):
		int b = 10
		int c = 20
		int d = 30
		return b + c + d
	return 0


void test_defer_local_after_more_locals():
	trace = 0
	assert_equal(60, deep_stack_helper(1))
	assert_equal(5, trace)
	trace = 0
	assert_equal(0, deep_stack_helper(2))
	assert_equal(5, trace)


# --- the return expression is evaluated BEFORE the defers run ---

int g_val


int return_before_defers():
	g_val = 5
	defer g_val = 99
	return g_val


void test_return_value_saved_around_defers():
	assert_equal(5, return_before_defers())
	assert_equal(99, g_val)


# --- defer inside a function called from a loop: the registry resets
# --- per call, so each call runs exactly its own defer

void loop_body(int i):
	defer mark(i)


void test_defer_in_function_called_in_loop():
	trace = 0
	for int i in range(1, 4):
		loop_body(i)
	assert_equal(123, trace)


# --- deferred call with multiple arguments ---

void record3(int a, int b, int c):
	trace = trace * 1000 + a * 100 + b * 10 + c


void multi_arg_helper(int a):
	defer record3(a, a + 1, a + 2)
	mark(9)


void test_defer_call_with_multiple_args():
	trace = 0
	multi_arg_helper(1)
	assert_equal(9123, trace)


# --- struct-by-value return: the value is copied into the caller's
# --- buffer before the defers run ---

struct defer_pair:
	int a
	int b


defer_pair make_pair(int x):
	defer mark(8)
	defer_pair p
	p.a = x
	p.b = x + 1
	return p


void test_defer_with_struct_return():
	trace = 0
	defer_pair q = make_pair(3)
	assert_equal(3, q.a)
	assert_equal(4, q.b)
	assert_equal(8, trace)


# --- realistic pattern: open a file, defer the close ---

int close_count


int close_counted(int fd):
	close_count = close_count + 1
	return close(fd)


int first_byte_of(char* path):
	int fd = open(path, 0, 0)
	if (fd < 0):
		return 0 - 1
	defer close_counted(fd)
	char* buf = malloc(4)
	int n = read(fd, buf, 1)
	int result = 0 - 1
	if (n == 1):
		result = buf[0]
	free(buf)
	return result


void test_defer_closes_file_descriptor():
	close_count = 0
	# this file's own first byte: the 'i' of 'import lib.testing'
	assert_equal('i', first_byte_of(c"tests/defer_test.w"))
	assert_equal(1, close_count)
