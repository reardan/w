import lib.testing


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


void test_mixed_types():
	mixed m
	m.a = 1
	m.b = 2
	m.c = 3
	m.d = 4
	assert_equal_hex(1, m.a)
	assert_equal_hex(2, m.b)
	assert_equal_hex(3, m.c)
	assert_equal_hex(4, m.d)


void test_mixed_types_reversed():
	mixed m
	m.d = 4
	m.c = 3
	m.b = 2
	m.a = 1
	assert_equal_hex(1, m.a)
	assert_equal_hex(2, m.b)
	assert_equal_hex(3, m.c)
	assert_equal_hex(4, m.d)


void test_new_struct():
	point* p = new point()
	p.x = 3
	p.y = 4
	assert_equal(3, p.x)
	assert_equal(4, p.y)
	free(p)


void test_new_without_parens():
	point* p = new point
	p.x = 7
	assert_equal(7, p.x)
	free(p)


void test_new_two_structs_are_distinct():
	point* a = new point()
	point* b = new point()
	assert1(a != b)
	a.x = 1
	b.x = 2
	assert_equal(1, a.x)
	assert_equal(2, b.x)
	free(a)
	free(b)


void test_new_mixed_constructor():
	# Constructor stores must respect each field's width and offset
	mixed* m = new mixed(1, 2, 3, 4)
	assert_equal_hex(1, m.a)
	assert_equal_hex(2, m.b)
	assert_equal_hex(3, m.c)
	assert_equal_hex(4, m.d)
	free(m)


/*
void test_double_struct():
	point p
	mixed m
	# test point
	# test mixed
*/


# --- struct-by-value regression tests: nested calls, reassignment, and
# deep frames (each shape has crashed or misread memory before) ---


struct sbox:
	int[3] cells


point make_point(int x, int y, int z):
	point pt
	pt.x = x
	pt.y = y
	pt.z = z
	return pt


point shift_point(point pt, int dx):
	point r
	r.x = pt.x + dx
	r.y = pt.y
	r.z = pt.z
	return r


int point_total(point pt):
	return pt.x + pt.y + pt.z


sbox make_sbox(int a, int b, int c):
	sbox s
	s.cells[0] = a
	s.cells[1] = b
	s.cells[2] = c
	return s


sbox merge_sbox(sbox x, sbox y):
	sbox r
	r.cells[0] = x.cells[0] + y.cells[0]
	r.cells[1] = x.cells[1] + y.cells[1]
	r.cells[2] = x.cells[2] + y.cells[2]
	return r


# A struct-returning call as a call argument must not corrupt the
# callee's parameter block (the nested call parks its return buffer on
# the stack between the outer arguments).
void test_nested_struct_call_argument():
	assert_equal(6, point_total(make_point(1, 2, 3)))
	point moved = shift_point(make_point(1, 2, 3), 10)
	assert_equal(11, moved.x)
	assert_equal(3, moved.z)
	# both arguments nested, with array-field descriptors in play
	sbox merged = merge_sbox(make_sbox(1, 2, 3), make_sbox(10, 20, 30))
	assert_equal(11, merged.cells[0])
	assert_equal(22, merged.cells[1])
	assert_equal(33, merged.cells[2])


# Assigning a struct-returning call to an existing local: the saved
# lhs address is buried under the callee's return buffer and must be
# read back esp-relative, not popped.
void test_struct_reassignment_from_call():
	point pt = make_point(1, 2, 3)
	pt = shift_point(pt, 10)
	assert_equal(11, pt.x)
	assert_equal(2, pt.y)
	pt = shift_point(make_point(5, 6, 7), 1)
	assert_equal(6, pt.x)
	assert_equal(7, pt.z)
	sbox s = make_sbox(1, 2, 3)
	s = merge_sbox(s, make_sbox(1, 1, 1))
	assert_equal(2, s.cells[0])
	assert_equal(4, s.cells[2])


# Locals whose slot index exceeds 127 words used to be read back through
# a sign-extended char, so deep frames misaddressed every late variable.
void test_deep_frame_slots():
	sbox s1 = make_sbox(1, 2, 3)
	sbox s2 = make_sbox(4, 5, 6)
	sbox s3 = make_sbox(7, 8, 9)
	sbox s4 = make_sbox(10, 11, 12)
	sbox s5 = make_sbox(13, 14, 15)
	sbox s6 = make_sbox(16, 17, 18)
	sbox s7 = make_sbox(19, 20, 21)
	sbox s8 = make_sbox(22, 23, 24)
	sbox s9 = make_sbox(25, 26, 27)
	sbox s10 = make_sbox(28, 29, 30)
	sbox s11 = make_sbox(31, 32, 33)
	sbox s12 = make_sbox(34, 35, 36)
	sbox s13 = make_sbox(37, 38, 39)
	point late = make_point(1, 2, 3)
	assert_equal(1, late.x)
	assert_equal(2, late.y)
	assert_equal(3, late.z)
	assert_equal(1, s1.cells[0])
	assert_equal(39, s13.cells[2])
	assert_equal(6, point_total(late))
/*
value-declaration constructors are not implemented (use new):
void test_constructor():
	point pt(1, 2, 3)
	assert_equal(pt.x, 1)
	assert_equal(pt.y, 2)
	assert_equal(pt.z, 3)
*/
