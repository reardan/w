import lib.testing


int func():
	return 1337


void test_int_func_pointer():
	# Storing a function in a word pointer needs the explicit cast
	int* test_func = cast(int*, func)

	print_hex("test_func: ", cast(int, test_func))
	# print_hex("*test_func: ", *test_func)
	assert_equal(1337, test_func())



void test_int_pointer():
	int want = 7777
	print_hex("want: ", want)
	int* ip = &want
	print_hex("ip: ", cast(int, ip))
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


# Milestone 5: structs as by-value parameters
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


void mutate_point(point pt):
	pt.x = 99
	pt.y = 98
	pt.z = 97


void test_argument_copy_isolation():
	# The callee mutates its copy; the caller's struct must not change
	point pt
	pt.x = 1
	pt.y = 2
	pt.z = 3
	mutate_point(pt)
	assert_equal(1, pt.x)
	assert_equal(2, pt.y)
	assert_equal(3, pt.z)


int sum_point_plus(point pt, int extra):
	return pt.x + pt.y + pt.z + extra


int sum_before_point(int extra, point pt):
	return pt.x + pt.y + pt.z + extra


void test_struct_param_with_scalars():
	# Parameters before and after a multi-word struct must still resolve
	point pt
	pt.x = 10
	pt.y = 20
	pt.z = 30
	assert_equal(65, sum_point_plus(pt, 5))
	assert_equal(67, sum_before_point(7, pt))


# Milestone 6: constructor-style new
void test_pointer():
	point* ptp = new point(4, 5, 6)
	assert_equal(ptp.x, 4)
	assert_equal(ptp.y, 5)
	assert_equal(ptp.z, 6)
	free(ptp)


void test_new_constructor_expressions():
	int base = 10
	point* ptp = new point(base + 1, base * 2, base - 3)
	assert_equal(11, ptp.x)
	assert_equal(20, ptp.y)
	assert_equal(7, ptp.z)
	free(ptp)


# Milestone 7: multi-level pointers
void test_int_double_pointer():
	int value = 55
	int* p = &value
	int** pp = &p
	int* got = *pp
	assert_equal(55, *got)
	**pp = 66
	assert_equal(66, value)


void test_char_double_pointer():
	char* s = "ab"
	char** sp = &s
	char* got = *sp
	assert_equal('a', got[0])
	assert_equal('b', got[1])


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
