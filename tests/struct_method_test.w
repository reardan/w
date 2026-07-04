import lib.testing


struct method_point:
	int x
	int y


struct method_box:
	method_point point


struct method_runner:
	int* run


void method_point_move(method_point* self, int dx, int dy):
	self.x = self.x + dx
	self.y = self.y + dy


int method_point_sum(method_point* self):
	return self.x + self.y


int method_point_add(method_point* self, int extra):
	return self.sum() + extra


int method_runner_run(method_runner* self):
	return 88


int method_runner_field_run():
	return 77


void test_value_receiver_method():
	method_point p
	p.x = 1
	p.y = 2
	p.move(3, 4)
	assert_equal(4, p.x)
	assert_equal(6, p.y)
	assert_equal(10, p.sum())


void test_pointer_receiver_method():
	method_point* p = new method_point(5, 6)
	p.move(7, 8)
	assert_equal(12, p.x)
	assert_equal(14, p.y)
	assert_equal(26, p.sum())
	free(p)


void test_nested_field_method():
	method_box box
	box.point.x = 9
	box.point.y = 10
	assert_equal(19, box.point.sum())


void test_method_argument_calls_method():
	method_point p
	p.x = 3
	p.y = 4
	assert_equal(12, p.add(5))


void test_field_function_pointer_precedence():
	method_runner runner
	runner.run = cast(int*, method_runner_field_run)
	assert_equal(77, runner.run())

