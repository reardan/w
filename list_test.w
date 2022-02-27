import testing
import list


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
		pop(i)
		i = i + 1
	assert_equal(0, length)


void test_empty_pop():
	create()

	int got = pop()
	assert_equal(0, got)


# Test failed malloc / free / realloc via mocks

