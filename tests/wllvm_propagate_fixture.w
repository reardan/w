# Differential fixture for bin/wllvm: a '?' error exit runs the deferred
# statements in scope (LIFO, once per exit), as result_propagate_suffix
# does natively, including two '?' in one statement, one inside a return
# value or a condition, and a defer registered inside a loop (it runs at
# the function's exits, reading the loop variable then). Exits 44.
import lib.result

int order
void mark(int n): order = order * 10 + n


wresult[int]* source(int n):
	if (n < 0): return result_new_error[int](n)
	return result_new_ok[int](n)


wresult[int]* deferred(int n):
	defer mark(9)
	defer mark(8)
	int value = source(n)?
	mark(1)
	return result_new_ok[int](value + 1)


wresult[int]* deferred_twice(int n, int m):
	defer mark(7)
	int value = source(n)? + source(m)?
	mark(2)
	return result_new_ok[int](value)


wresult[int]* deferred_return(int n):
	defer mark(6)
	return result_new_ok[int](source(n)? + 1)


wresult[int]* deferred_if(int n):
	defer mark(5)
	if source(n)? > 3:
		mark(3)
	return result_new_ok[int](0)


wresult[int]* deferred_loop(int n):
	defer mark(4)
	for i in range(3):
		defer mark(i + 1)
		int value = source(n - i)?
		mark(value)
	return result_new_ok[int](0)


int check(int got, int want, int code):
	if (got != want):
		println(itoa(got))
		return code
	return 0


int run(int which, int a, int b):
	order = 0
	if (which == 0): deferred(a)
	if (which == 1): deferred_twice(a, b)
	if (which == 2): deferred_return(a)
	if (which == 3): deferred_if(a)
	if (which == 4): deferred_loop(a)
	return order


int main():
	int failed = check(run(0, 4, 0), 189, 1)
	if (failed == 0): failed = check(run(0, -7, 0), 89, 2)
	if (failed == 0): failed = check(run(1, 1, 2), 27, 3)
	if (failed == 0): failed = check(run(1, -1, 2), 7, 4)
	if (failed == 0): failed = check(run(1, 1, -2), 7, 5)
	if (failed == 0): failed = check(run(2, -1, 0), 6, 6)
	if (failed == 0): failed = check(run(2, 1, 0), 6, 7)
	if (failed == 0): failed = check(run(3, -1, 0), 5, 8)
	if (failed == 0): failed = check(run(3, 5, 0), 35, 9)
	if (failed == 0): failed = check(run(4, 1, 0), 1034, 10)
	if (failed == 0): failed = check(run(4, 3, 0), 32144, 11)
	if (failed != 0): return failed
	return 44
