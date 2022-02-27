import testing


struct point:
	int x
	int y
	int z


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
	point* ptp = malloc(12 * num)  /* point.size */
	int i = 0
	while (i < num):
		ptp[i].x = i
		ptp[i].y = i * 10
		ptp[i].z = i * 100
		i = i + 1
	free(ptp)
