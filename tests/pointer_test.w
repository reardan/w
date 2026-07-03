import lib.testing


int func():
	return 1337


void test_int_func_pointer():
	int* test_func = func

	print_hex("test_func: ", test_func)
	# print_hex("*test_func: ", *test_func)
	assert_equal(1337, test_func())



void test_int_pointer():
	int want = 7777
	print_hex("want: ", want)
	int* ip = &want
	print_hex("ip: ", ip)
	int got = *ip
	print_hex("got: ", got)
	assert_equal(want, got)


void test_char_lookup_0():
	char* want = "a"
	int got = want[0]
	assert_equal('a', got)


void test_char_lookup_6():
	char* want = "hello world"
	int got = want[6]
	assert_equal('w', got)


void test_char_lookup_hi():
	char* char_ptr = "hi"
	assert_equal('h', char_ptr[0])
	assert_equal('i', char_ptr[1])
	assert_equal(0, char_ptr[2])


# Milestone 1:
void test_char_ptr_ms1():
	char* char_ptr = "hi"

	assert_equal_hex('h', *char_ptr)
	*char_ptr = 'a'
	assert1(strcmp("ai", char_ptr) == 0)


# Milestone 2: ampersand operator
void test_ptr_to_int_address():
	int value = 10
	int *ptr = &value
	*ptr = 20
	assert_equal(20, value)


# Milestone 3: int[]
void test_int_pointer_brackets():
	int* array_ptr = malloc(4 * 10)
	array_ptr[0] = 879
	assert_equal(879, array_ptr[0])
	array_ptr[2] = 9876
	assert_equal(9876, array_ptr[2])
	free(array_ptr)


# Milestone 4: Struct Pointers

struct point:
	int x
	int y
	int z


void fill_point(point* pt):
	pt.x = 1
	pt.y = 2
	pt.z = 3


void test_argument_pointer():
	point pt
	fill_point(&pt)
	assert_equal(pt.x, 1)
	assert_equal(pt.y, 2)
	assert_equal(pt.z, 3)


/* Structs as by-value parameters are not implemented yet:
void argument(point pt):
	assert_equal(1, pt.x)
	assert_equal(2, pt.y)
	assert_equal(3, pt.z)


void test_argument():
	point pt
	pt.x = 1
	pt.y = 2
	pt.z = 3
	argument(pt)


'new' is not implemented yet:
void test_pointer():
	point* ptp = new point(4, 5, 6)
	assert_equal(ptp.x, 4)
	assert_equal(ptp.y, 5)
	assert_equal(ptp.z, 6)
	free(ptp)
*/


void test_array_of_structs():
	int num = 1000
	point* ptp = malloc(12 * num)
	int i = 0
	while (i < num):
		ptp[i].x = i
		ptp[i].y = i * 10
		ptp[i].z = i * 100
		i = i + 1
	i = 0
	while (i < num):
		assert_equal(i, ptp[i].x)
		assert_equal(i * 10, ptp[i].y)
		assert_equal(i * 100, ptp[i].z)
		i = i + 1
	free(ptp)
