import testing

int value

void dec_value():
	# totally not thread safe lul
	# todo: add lock / atomic decrement
	value = value - 1
	if (value <= 0):
		exit(0)

void thread_func():
	println("Hello from \x1b[93;1mmain\x1b[0m!\x0a\x00")
	dec_value()


void thread_func2():
	println("Hello from \x1b[91;1mthread\x1b[0m!\x0a\x00")
	dec_value()


void test_stack_create():
	value = 1000000
	# debugger
	# print_hex("thread_func(): ", thread_func)
	int thread = thread_create(thread_func)
	# debugger
	# print_hex("thread: ", thread)


