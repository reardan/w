import lib.testing

int flag

void thread_func():
	flag = 1337
	# Terminate just this thread; returning would fall off the top of its stack.
	thread_exit(0)


void test_thread_create():
	flag = 0
	int tid = thread_create(thread_func)
	asserts("thread_create failed", tid > 0)
	# CLONE_VM shares memory, so spin until the child writes the flag.
	int spins = 0
	while ((flag == 0) & (spins < 100000000)):
		spins = spins + 1
	assert_equal(1337, flag)
