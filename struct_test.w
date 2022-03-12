import testing


struct point:
	int x
	int y
	int z


struct duo:
	int a
	int b


struct quad:
	int a
	int b
	int c
	int d


void test_void():
	int v


void test_declare_local():
	point pt


void test_multiple_assignment():
	point pt
	pt.x = 1
	pt.y = 2
	pt.z = 3
	assert_equal_hex(3, pt.z)
	assert_equal_hex(2, pt.y)
	assert_equal_hex(1, pt.x)


void test_duo():
	duo d
	d.a = 4
	d.b = 5
	assert_equal_hex(4, d.a)
	assert_equal_hex(5, d.b)


/*void test_duo_bad_name():
	duo d
	debugger
	d.a = 4
	d.b = 5
	debugger
	assert_equal_hex(4, d.y)
	assert_equal_hex(5, d.x)*/


void test_simple_assignment():
	point pt
	pt.x = 7
	assert_equal_hex(7, pt.x)


void test_field_2():
	point pt
	pt.y = 14
	assert_equal_hex(14, pt.y)


void test_quad():
	quad q
	q.a = 5
	q.b = 6
	q.c = 7
	q.d = 8
	assert_equal_hex(5, q.a)
	assert_equal_hex(6, q.b)
	assert_equal_hex(7, q.c)
	assert_equal_hex(8, q.d)


/*void test_simple_pointer():
	int z = 7
	int y = 5
	int x = 3
	point *pt
	pt = &x
	assert_equal_hex(7, *pt.z)
	assert_equal_hex(5, *pt.y)
	assert_equal_hex(3, *pt.x)*/



struct mixed:
	int32 a
	int16 b
	int8 c
	int32 d


/*void test_mixed_types():
	mixed m
	m.a = 1
	m.b = 2
	m.c = 3
	m.d = 4
	assert_equal_hex(1, m.a)
	assert_equal_hex(2, m.b)
	assert_equal_hex(3, m.c)
	assert_equal_hex(4, m.d)

	# this doesn't actually check the sizes are correctly implemented
	# to do this, have binary data then create a struct pointer to it
	# then check the values are correct

	# it actually partially checks it due to the cross reading of data*/


void test_mixed_types_reversed():
	mixed m
	debugger
	m.d = 4
	debugger
	m.c = 3
	debugger
	m.b = 2
	debugger
	m.a = 1
	debugger
	assert_equal_hex(1, m.a)
	debugger
	assert_equal_hex(2, m.b)
	assert_equal_hex(3, m.c)
	assert_equal_hex(4, m.d)



/*
void test_double_struct():
	point p
	mixed m
	# test point
	# test mixed
*/
/*

void test_constructor():
	point pt(1, 2, 3)
	assert_equal(pt.x, 1)
	assert_equal(pt.y, 2)
	assert_equal(pt.z, 3)
*/
