# Named-field construction (golf ergonomics wave 5): 'new T(f: v, ...)'
# and the struct value constructor 'T(f: v, ...)' fill fields by name in
# any order; the fields left out read zero. Positional forms unchanged.
# wbuild: x64
import lib.testing


struct nc_point:
	int x
	int y
	char tag


# Word-multiple field structs: a struct copy into a field is word
# granular, so a 9-byte nc_point field would spill into the next field
struct nc_vec:
	int x
	int y


struct nc_line:
	nc_vec from
	nc_vec to
	char* label


int nc_sum(nc_point p):
	return p.x + p.y


void test_new_named_any_order():
	nc_point* p = new nc_point(y: 7, x: 3)
	assert_equal(3, p.x)
	assert_equal(7, p.y)
	assert_equal(0, p.tag)


void test_new_named_zeroes_the_rest():
	nc_point* p = new nc_point(tag: 'q')
	assert_equal(0, p.x)
	assert_equal(0, p.y)
	assert_equal('q', p.tag)


void test_value_ctor_named():
	nc_point p = nc_point(y: 5)
	assert_equal(0, p.x)
	assert_equal(5, p.y)
	assert_equal(9, nc_sum(nc_point(x: 4, y: 5)))


void test_nested_struct_fields():
	nc_line* l = new nc_line(label: c"diag", to: nc_vec(y: 2, x: 3))
	assert_equal(0, l.from.x)
	assert_equal(3, l.to.x)
	assert_equal(2, l.to.y)
	assert_equal(0, strcmp(c"diag", l.label))


void test_positional_unchanged():
	nc_point* p = new nc_point(1, 2, 'z')
	assert_equal(1, p.x)
	assert_equal(2, p.y)
	assert_equal('z', p.tag)
	nc_point q = nc_point(8, 9, 'w')
	assert_equal(17, nc_sum(q))
