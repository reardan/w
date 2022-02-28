import testing


struct point:
	int x
	int y
	int z


void test_void():
	int v


void test_declare_local():
	point p


void test_simple_assignment():
	point p
	p.x = 1
	assert_equal(1, p.x)


void test_multiple_assignment():
	point p
	p.x = 1
	p.y = 2
	p.z = 3
	assert_equal(1, p.x)
	assert_equal(2, p.y)
	assert_equal(3, p.z)


/*
struct mixed:
	int32 a
	int16 b
	int8 c
	int32 d


void test_mixed_types():
	mixed m
	m.a = 1
	m.b = 2
	m.c = 3
	m.d = 4
	assert_equal(1, m.a)
	assert_equal(2, m.b)
	assert_equal(3, m.c)
	assert_equal(4, m.d)

*/


/*
void test_local():
	point pt(1, 2, 3)
	assert_equal(pt.x, 1)
	assert_equal(pt.y, 2)
	assert_equal(pt.z, 3)


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
