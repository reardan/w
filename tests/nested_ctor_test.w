# wbuild: x64
import lib.testing

/*
Struct-value constructor calls and their interaction with 'new' (issue
#270): 'T(a, b)' builds a T in a stack temp that stays parked like a
struct-returning call's buffer, and the 'new' constructor path reads its
saved allocation address esp-relative past any such leak instead of
assuming it sits on top of the stack. Covers the exact issue repro,
constructor calls in either argument position, nested 'new' inside 'new'
arguments, depth-2 value nesting, struct-returning calls as 'new'
arguments, and struct-value calls fed to ordinary functions.
*/


struct nc_point:
	int x
	int y


struct nc_holder:
	nc_point p


struct nc_deep:
	nc_holder h


struct nc_box:
	nc_point* ptr


struct nc_scalar_first:
	int a
	nc_point p


struct nc_scalar_last:
	nc_point p
	int b


struct nc_two_points:
	nc_point first
	nc_point second


# Mixed-width fields: constructor stores must respect each field's
# width and offset in the stack temp too.
struct nc_mixed:
	char tag
	int x
	char pad
	int y


nc_point nc_make_point(int x, int y):
	nc_point pt
	pt.x = x
	pt.y = y
	return pt


int nc_point_total(nc_point pt):
	return pt.x + pt.y


int nc_point_sum(nc_point* self):
	return self.x + self.y


# The exact issue #270 repro: a struct-value constructor as the
# argument of a 'new' constructor.
void test_new_with_ctor_argument():
	nc_holder* h = new nc_holder(nc_point(7, 8))
	assert_equal(7, h.p.x)
	assert_equal(8, h.p.y)
	free(h)


void test_value_ctor_declaration():
	nc_point p = nc_point(7, 8)
	assert_equal(7, p.x)
	assert_equal(8, p.y)


void test_value_ctor_assignment():
	nc_point p = nc_point(0, 0)
	p = nc_point(3, 4)
	assert_equal(3, p.x)
	assert_equal(4, p.y)


void test_value_ctor_expression_arguments():
	int base = 10
	nc_point p = nc_point(base + 1, base * 2)
	assert_equal(11, p.x)
	assert_equal(20, p.y)


# A struct-value constructor as an ordinary call argument slides over
# its parked temp exactly like a struct-returning call does.
void test_ctor_as_function_argument():
	assert_equal(3, nc_point_total(nc_point(1, 2)))
	assert_equal(15, nc_point_total(nc_make_point(7, 8)))


void test_method_on_ctor_result():
	assert_equal(3, nc_point(1, 2).sum())


# Struct-returning function call as a 'new' argument: the parked return
# buffer must not clobber the saved allocation address.
void test_new_with_call_argument():
	nc_holder* h = new nc_holder(nc_make_point(7, 8))
	assert_equal(7, h.p.x)
	assert_equal(8, h.p.y)
	free(h)


void test_new_with_local_struct_argument():
	nc_point tmp = nc_point(7, 8)
	nc_holder* h = new nc_holder(tmp)
	assert_equal(7, h.p.x)
	assert_equal(8, h.p.y)
	free(h)


# Constructor call as the second of two 'new' arguments (and as the
# first, followed by a scalar).
void test_ctor_in_either_argument_position():
	nc_scalar_first* sf = new nc_scalar_first(5, nc_point(1, 2))
	assert_equal(5, sf.a)
	assert_equal(1, sf.p.x)
	assert_equal(2, sf.p.y)
	free(sf)
	nc_scalar_last* sl = new nc_scalar_last(nc_point(3, 4), 9)
	assert_equal(3, sl.p.x)
	assert_equal(4, sl.p.y)
	assert_equal(9, sl.b)
	free(sl)


void test_two_ctor_arguments():
	nc_two_points* tp = new nc_two_points(nc_point(1, 2), nc_point(3, 4))
	assert_equal(1, tp.first.x)
	assert_equal(2, tp.first.y)
	assert_equal(3, tp.second.x)
	assert_equal(4, tp.second.y)
	free(tp)


# 'new' nested inside another 'new''s argument list.
void test_new_inside_new_arguments():
	nc_box* b = new nc_box(new nc_point(5, 6))
	assert_equal(5, b.ptr.x)
	assert_equal(6, b.ptr.y)
	free(b.ptr)
	free(b)


# Depth-2 value nesting: a constructor argument that is itself a
# constructor call with a constructor argument.
void test_depth_two_value_nesting():
	nc_deep* d = new nc_deep(nc_holder(nc_point(7, 8)))
	assert_equal(7, d.h.p.x)
	assert_equal(8, d.h.p.y)
	free(d)
	nc_holder hv = nc_holder(nc_point(5, 6))
	assert_equal(5, hv.p.x)
	assert_equal(6, hv.p.y)


void test_mixed_width_value_ctor():
	nc_mixed m = nc_mixed('t', 2, 'p', 4)
	assert_equal('t', m.tag)
	assert_equal(2, m.x)
	assert_equal('p', m.pad)
	assert_equal(4, m.y)


void test_mixed_width_new_ctor_argument():
	nc_scalar_first* sf = new nc_scalar_first(nc_point_total(nc_point(2, 3)), nc_point(4, 5))
	assert_equal(5, sf.a)
	assert_equal(4, sf.p.x)
	assert_equal(5, sf.p.y)
	free(sf)
