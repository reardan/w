# wbuild: x64
# Pointer-returning methods retain their aggregate receiver's caller-owned
# buffer. Range bounds must remember their actual slots around those buffers.
# Scalar methods release their receiver before condition back edges; both
# forms suspend the conservative independent layout cursor.
import lib.testing


struct layout_header_pair:
	int x
	int y


layout_header_pair layout_header_make(int x, int y):
	return layout_header_pair(x, y)


int layout_header_pair_sum(layout_header_pair* self):
	return self.x + self.y


int* layout_header_pair_address(layout_header_pair* self):
	return &self.x


float layout_header_pair_fraction(layout_header_pair* self):
	return self.x + 0.5


int layout_header_pair_sum_with(layout_header_pair* self, layout_header_pair other):
	return self.x + self.y + other.x + other.y


void test_temporary_receiver_with_aggregate_argument():
	int hits = 0
	while layout_header_make(2, 3).sum_with(layout_header_make(4, 5)) && (hits < 3):
		hits += 1
	assert_equal(3, hits)


void test_temporary_receiver_float_result():
	int sentinel = 19
	float value = layout_header_make(2, 3).fraction()
	assert_near(2.5, value)
	assert_equal(19, sentinel)


void test_switch_header_with_aggregate_receiver():
	int selected = 0
	switch *layout_header_make(5, 0).address():
		case 5:
			selected = 1
			break
		default: selected = -1
	assert_equal(1, selected)


void test_range_header_with_aggregate_receiver():
	int hits = 0
	int total = 0
	for i in range(*layout_header_make(5, 0).address()):
		hits += 1
		total += i
	assert_equal(5, hits)
	assert_equal(10, total)


int layout_range_trace


layout_header_pair layout_range_bound(int marker, int x, int y):
	layout_range_trace = layout_range_trace * 10 + marker
	return layout_header_make(x, y)


void test_range_two_aggregate_receiver_bounds():
	layout_range_trace = 0
	int total = 0
	for i in range(*layout_range_bound(1, 2, 0).address(), *layout_range_bound(2, 5, 0).address()):
		total += i
	assert_equal(9, total)
	assert_equal(12, layout_range_trace)


void test_range_three_aggregate_receiver_bounds():
	layout_range_trace = 0
	int hits = 0
	int total = 0
	for i in range(*layout_range_bound(1, 3, 0).address(), *layout_range_bound(2, 9, 0).address(), *layout_range_bound(3, 2, 0).address()):
		hits += 1
		total += i
	assert_equal(3, hits)
	assert_equal(15, total)
	assert_equal(123, layout_range_trace)


void test_temporary_receiver_short_circuit_guards():
	int hits = 0
	while (hits < 3) && layout_header_make(2, 3).sum():
		hits += 1
	assert_equal(3, hits)
	hits = 0
	while layout_header_make(2, 3).sum() && (hits < 3):
		hits += 1
	assert_equal(3, hits)
	hits = 0
	while layout_header_make(0, 0).sum() || (hits < 3):
		hits += 1
	assert_equal(3, hits)


void test_aggregate_switch_header_inside_loop():
	int hits = 0
	for i in range(3):
		switch *layout_header_make(5, 0).address():
			case 5:
				hits += 1
				continue
			default: break
		hits += 100
	assert_equal(3, hits)


void test_aggregate_while_condition_preserves_break_depth():
	int hits = 0
	while layout_header_make(2, 3).sum():
		hits += 1
		if (hits < 3): continue
		break
	assert_equal(3, hits)
