# wbuild: x64
import lib.testing

/*
Method chaining through method return values (docs/projects/struct_methods.md):
a direct call's result keeps the callee's declared return type, so a following
'.method(...)' or '.field' suffix dispatches on the returned struct pointer or
struct value. Covers pointer returns, by-value returns, chains of depth 3-4,
free-function results feeding method calls, and chains in statement, argument,
condition and return position.
*/


struct chain_point:
	int x
	int y


struct chain_holder:
	chain_point p


# Mixed-width fields: the by-value return buffer is not a whole number of
# words, so chaining exercises the size rounding too.
struct chain_mixed:
	char tag
	int x
	char pad
	int y


void chain_point_move(chain_point* self, int dx, int dy):
	self.x = self.x + dx
	self.y = self.y + dy


int chain_point_sum(chain_point* self):
	return self.x + self.y


chain_point* chain_point_set_x(chain_point* self, int v):
	self.x = v
	return self


chain_point* chain_point_set_y(chain_point* self, int v):
	self.y = v
	return self


chain_point chain_point_plus(chain_point* self, int d):
	chain_point out
	out.x = self.x + d
	out.y = self.y + d
	return out


chain_point* chain_holder_child(chain_holder* self):
	return &self.p


chain_mixed chain_holder_mixed(chain_holder* self):
	chain_mixed out
	out.tag = 't'
	out.pad = 'p'
	out.x = self.p.x
	out.y = self.p.y
	return out


list[int] chain_holder_coords(chain_holder* self):
	list[int] out = new list[int]
	out.push(self.p.x)
	out.push(self.p.y)
	return out


int chain_mixed_sum(chain_mixed* self):
	return self.x + self.y


chain_holder* chain_make_holder(int x, int y):
	chain_holder* h = new chain_holder()
	h.p.x = x
	h.p.y = y
	return h


int chain_use_point(chain_point p):
	return p.x * 100 + p.y


void test_pointer_return_chain_statement():
	chain_holder h
	h.p.x = 1
	h.p.y = 2
	h.child().move(10, 20)
	assert_equal(11, h.p.x)
	assert_equal(22, h.p.y)


void test_pointer_return_chain_expression():
	chain_holder h
	h.p.x = 3
	h.p.y = 4
	assert_equal(7, h.child().sum())


void test_field_through_returned_pointer():
	chain_holder h
	h.p.x = 5
	h.p.y = 6
	assert_equal(5, h.child().x)
	assert_equal(6, h.child().y)


void test_write_through_returned_pointer():
	chain_holder h
	h.p.x = 0
	h.p.y = 0
	h.child().x = 42
	assert_equal(42, h.p.x)


void test_fluent_chain_depth_four():
	chain_point p
	p.x = 0
	p.y = 0
	p.set_x(1).set_y(2).set_x(3)
	assert_equal(3, p.x)
	assert_equal(2, p.y)
	assert_equal(9, p.set_x(4).set_y(5).sum())


void test_value_return_chain():
	chain_point p
	p.x = 1
	p.y = 2
	assert_equal(5, p.plus(1).sum())
	assert_equal(2, p.plus(1).x)
	assert_equal(7, p.plus(1).plus(1).sum())
	# the chain mutates temporaries, never the receiver
	assert_equal(1, p.x)
	assert_equal(2, p.y)


void test_value_return_mixed_width_chain():
	chain_holder h
	h.p.x = 15
	h.p.y = 20
	assert_equal(35, h.mixed().sum())
	assert_equal('t', h.mixed().tag)


void test_free_function_result_chain():
	assert_equal(15, chain_make_holder(7, 8).child().sum())
	assert_equal(7, chain_make_holder(7, 8).p.x)
	chain_make_holder(1, 2).child().move(3, 4)


void test_chain_in_condition():
	chain_point p
	p.x = 1
	p.y = 2
	int taken = 0
	if (p.plus(2).sum() == 7):
		taken = 1
	assert_equal(1, taken)
	while (p.plus(0).sum() < 0):
		p.x = p.x - 1


int chain_helper_return(chain_point* p):
	return p.plus(4).sum()


void test_chain_in_return():
	chain_point p
	p.x = 2
	p.y = 4
	assert_equal(14, chain_helper_return(&p))


void test_chain_as_call_argument():
	chain_point p
	p.x = 1
	p.y = 2
	assert_equal(506, chain_use_point(p.plus(2).plus(2)))
	# a pointer-returning method dispatched on a by-value temp
	assert_equal(13, p.plus(4).set_x(7).sum())


void test_assign_chained_value_result():
	chain_point p
	p.x = 1
	p.y = 2
	chain_point q = p.plus(1).plus(2)
	assert_equal(4, q.x)
	assert_equal(5, q.y)


void test_container_return_chain():
	chain_holder h
	h.p.x = 9
	h.p.y = 11
	assert_equal(9, h.coords()[0])
	assert_equal(11, h.coords()[1])
	assert_equal(2, h.coords().length)
