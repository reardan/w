# wbuild: x64
# Qualified type names through an import alias (docs/todo.txt "type
# system"): 'import m as t' makes 't.SomeType' resolve in type
# positions -- locals, globals, parameters, returns, struct fields,
# pointers, casts, 'new' and the struct-constructor literal -- checked
# against the aliased module's declarations exactly like the value
# spelling 't.name' import_test pins. Unqualified use of the module's
# types keeps working (the type table stays global).
import lib.testing
import tests.import_alias_type_helper as th

# Return type and parameter declared through the alias
th.alias_point make_point(int x, int y):
	th.alias_point p = th.alias_point(x, y)
	return p

int point_sum(th.alias_point p):
	return p.x + p.y

# A struct field typed through the alias
struct alias_wrapper:
	th.alias_point inner
	int tag

# A global declared through the alias
th.alias_point global_point

void test_alias_type_local():
	th.alias_point p
	p.x = 3
	p.y = 4
	assert_equal(7, point_sum(p))

void test_alias_type_ctor_literal():
	assert_equal(12, point_sum(th.alias_point(5, 7)))

void test_alias_type_return_and_param():
	th.alias_point p = make_point(20, 22)
	assert_equal(42, point_sum(p))

void test_alias_type_field():
	alias_wrapper w
	w.inner.x = 1
	w.inner.y = 2
	w.tag = 3
	assert_equal(6, w.inner.x + w.inner.y + w.tag)

void test_alias_type_global():
	global_point.x = 30
	global_point.y = 12
	assert_equal(42, point_sum(global_point))

void test_alias_type_pointer_and_new():
	th.alias_point* p = new th.alias_point(8, 9)
	assert_equal(17, p.x + p.y)
	th.alias_point* q = &global_point
	global_point.x = 5
	global_point.y = 6
	assert_equal(11, q.x + q.y)

void test_alias_type_nested_struct():
	th.alias_box b
	b.corner.x = 1
	b.corner.y = 2
	b.depth = 3
	assert_equal(6, b.corner.x + b.corner.y + b.depth)

void test_alias_type_alias_target():
	th.alias_word v = 40
	assert_equal(42, v + 2)

void test_alias_type_cast():
	int raw = 9
	th.alias_word w = cast(th.alias_word, raw)
	assert_equal(9, w)

# Unqualified module-type use keeps existing behavior
void test_unqualified_type_still_works():
	alias_point p
	p.x = 2
	p.y = 2
	assert_equal(4, p.x + p.y)

# The value spelling through the same alias stays intact
void test_alias_value_member():
	assert_equal(1337, th.alias_type_helper_value())
