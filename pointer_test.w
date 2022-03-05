# Milestone 1:
void test_char_ptr():
    # Currently works:
    char* char_ptr = "hi"
    assert_equal('h', char_ptr[0])

    # Doesn't currently work:
    assert_equal(*char_ptr, 'h')
    *char_ptr = 'a'
    assert(strcmp("ai", char_ptr) == 0)


# Milestone 2:
void test_int_ptr():
    int value = 10
    int *ptr = &value
    *ptr = 20
    assert_equal(20, value)


# Milestone 3:

# Milestone 4: Struct Pointers
/*
void fill_point(point* pt):
	pt.x = 1
	pt.y = 2
	pt.z = 3


void test_argument_pointer():
	point pt
	fill_point(pt)
	assert_equal(pt.x, 1)
	assert_equal(pt.y, 2)
	assert_equal(pt.z, 3)


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


void test_pointer():
	point* ptp = new point(4, 5, 6)
	assert_equal(ptp.x, 4)
	assert_equal(ptp.y, 5)
	assert_equal(ptp.z, 6)
	free(ptp)


void test_array_of_structs():
	int num = 1000
	# 12 = pt size, TODO: struct.size attribute
	point* ptp = malloc(12 * num) 
	int i = 0
	while (i < num):
		ptp[i].x = i
		ptp[i].y = i * 10
		ptp[i].z = i * 100
		i = i + 1
	free(ptp)
*/