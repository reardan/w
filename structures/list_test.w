import lib.testing
import structures.list


void test_create():
	create()


void test_delete():
	# TODO: check that child elements are freed
	die()


void test_push_pop():
	create()
	int want = 1234
	push(want)
	assert_equal(want, pop())
	assert_equal(length, 0)


void test_push_pop_x2():
	create()

	int want1 = 1234
	push(want1)
	assert_equal(want1, pop())

	int want2 = 5678
	push(want2)
	assert_equal(want2, pop())

	assert_equal(length, 0)


void test_push2_pop2():
	create()

	int want1 = 1234
	push(want1)
	int want2 = 5678
	push(want2)

	assert_equal(want2, pop())
	assert_equal(want1, pop())

	assert_equal(length, 0)


void test_push_pop_1000():
	create()

	int len = 1000

	int i = 0
	while (i < len):
		push(i)
		i = i + 1
	assert_equal(len, length)

	i = 0
	while (i < len):
		pop()
		i = i + 1
	assert_equal(0, length)


void test_empty_pop():
	create()

	int got = pop()
	assert_equal(0, got)



void test_join():
	push(cast(int, c"Hey there!"))
	push(cast(int, c"How's it going?"))
	push(cast(int, c"Well! And you?"))
	push(cast(int, c"Amazing!"))
	push(cast(int, c"Have a great day!"))
	push(cast(int, c"You too!"))
	println(join(c", "))
	assert_strings_equal(c"Hey there! How's it going? Well! And you? Amazing! Have a great day! You too!", join(c" "))


void test_join_simple():
	create()
	char* s = c"Hey there!"
	print_hex(c"s: ", cast(int, s))
	push(cast(int, s))
	assert_strings_equal(s, join(c","))


void test_strcmp():
	asserts(c"spaces equal", strcmp(c" ", c" ") == 0)


void test_split():
	create()
	# split_string tokenizes its input in place, so pass a heap copy: the
	# string literal is read-only under the W^X code/data split.
	split_string(strclone(c"1 2 3 4 5 6 7 8 9 10"), c" ")
	assert_equal(10, length)
	assert_strings_equal(c"1", cast(char*, get(0)))
	assert_strings_equal(c"10", cast(char*, get(9)))


# Test failed malloc / free / realloc via mocks

