# wbuild: x64
# List negative indexing and slicing (issue #360 item 5): l[-1] counts
# from the end, l[start:end] copies the selected range into a NEW list
# (Python-style copy semantics), with open and negative bounds. The
# out-of-range trap paths are asserted by container_trap_test via
# tests/list_negative_index_trap_fixture.w and the slice trap fixtures.
import lib.testing


void test_negative_index_read():
	list[int] l = list[int]{10, 20, 30, 40}
	assert_equal(40, l[-1])
	assert_equal(30, l[-2])
	assert_equal(20, l[-3])
	assert_equal(10, l[-4])


void test_negative_index_write():
	list[int] l = list[int]{1, 2, 3}
	l[-1] = 30
	l[-3] = 10
	assert_equal(10, l[0])
	assert_equal(2, l[1])
	assert_equal(30, l[2])


void test_negative_index_compound():
	list[int] l = list[int]{5, 6, 7}
	l[-1] += 3
	l[-3] -= 4
	l[-2] *= 2
	assert_equal(1, l[0])
	assert_equal(12, l[1])
	assert_equal(10, l[2])


void test_negative_index_expression():
	list[int] l = list[int]{4, 8, 15}
	int i = 1
	assert_equal(15, l[0 - i])
	assert_equal(8, l[-i - 1])
	assert_equal(15, l[l[-3] - 5])


void test_negative_index_after_push_pop():
	list[int] l = list[int]{1, 2}
	l.push(3)
	assert_equal(3, l[-1])
	l.pop()
	assert_equal(2, l[-1])


void test_slice_basic():
	list[int] l = list[int]{10, 20, 30, 40}
	list[int] mid = l[1:3]
	assert_equal(2, mid.length)
	assert_equal(20, mid[0])
	assert_equal(30, mid[1])


void test_slice_open_forms():
	list[int] l = list[int]{1, 2, 3, 4}
	list[int] head = l[:2]
	assert_equal(2, head.length)
	assert_equal(1, head[0])
	assert_equal(2, head[1])
	list[int] tail = l[2:]
	assert_equal(2, tail.length)
	assert_equal(3, tail[0])
	assert_equal(4, tail[1])
	list[int] all = l[:]
	assert_equal(4, all.length)
	assert_equal(1, all[0])
	assert_equal(4, all[3])


void test_slice_full_and_empty():
	list[int] l = list[int]{7, 8, 9}
	list[int] full = l[0:3]
	assert_equal(3, full.length)
	list[int] empty = l[1:1]
	assert_equal(0, empty.length)
	list[int] at_end = l[3:3]
	assert_equal(0, at_end.length)
	list[int] at_start = l[0:0]
	assert_equal(0, at_start.length)


void test_slice_negative_endpoints():
	list[int] l = list[int]{10, 20, 30, 40}
	list[int] a = l[-3:-1]
	assert_equal(2, a.length)
	assert_equal(20, a[0])
	assert_equal(30, a[1])
	list[int] b = l[1:-1]
	assert_equal(2, b.length)
	assert_equal(20, b[0])
	list[int] c = l[-2:]
	assert_equal(2, c.length)
	assert_equal(30, c[0])
	assert_equal(40, c[1])
	list[int] d = l[:-2]
	assert_equal(2, d.length)
	assert_equal(10, d[0])
	list[int] e = l[-1:-1]
	assert_equal(0, e.length)


void test_slice_of_empty_list():
	list[int] l = list[int]{}
	list[int] a = l[:]
	assert_equal(0, a.length)
	list[int] b = l[0:0]
	assert_equal(0, b.length)


void test_slice_is_a_copy():
	list[int] l = list[int]{1, 2, 3, 4}
	list[int] s = l[1:3]
	s[0] = 99
	assert_equal(2, l[1])
	l[2] = 77
	assert_equal(3, s[1])


void test_push_pop_after_slicing():
	list[int] l = list[int]{1, 2, 3, 4}
	list[int] s = l[1:3]
	s.push(50)
	assert_equal(3, s.length)
	assert_equal(4, l.length)
	assert_equal(50, s[-1])
	l.push(5)
	assert_equal(5, l.length)
	assert_equal(3, s.length)
	assert_equal(50, s.pop())
	assert_equal(5, l.pop())
	assert_equal(2, s.length)
	assert_equal(4, l.length)
	assert_equal(3, s[-1])
	assert_equal(4, l[-1])


void test_slice_chained():
	list[int] l = list[int]{10, 20, 30, 40}
	assert_equal(2, l[1:3].length)
	assert_equal(20, l[1:3][0])
	assert_equal(30, l[1:3][-1])
	assert_equal(1, l[1:3][1:2].length)
	assert_equal(30, l[1:3][1:2][0])


void test_slice_char_elements():
	list[char] l = list[char]{'a', 'b', 'c', 'd'}
	list[char] mid = l[1:-1]
	assert_equal(2, mid.length)
	assert_equal('b', mid[0])
	assert_equal('c', mid[-1])


struct slice_point:
	int x
	int y


void test_slice_struct_elements():
	list[slice_point] pts = new list[slice_point]
	slice_point p
	p.x = 1
	p.y = 2
	pts.push(p)
	p.x = 3
	p.y = 4
	pts.push(p)
	p.x = 5
	p.y = 6
	pts.push(p)
	list[slice_point] tail = pts[1:]
	assert_equal(2, tail.length)
	assert_equal(3, tail[0].x)
	assert_equal(4, tail[0].y)
	assert_equal(5, tail[-1].x)
	assert_equal(6, tail[-1].y)
	tail[0].x = 99
	assert_equal(3, pts[1].x)
	assert_equal(4, pts[-2].y)
	assert_equal(2, pts[-3].y)


void test_slice_iteration():
	list[int] l = list[int]{1, 2, 3, 4, 5}
	int sum = 0
	for int v in l[1:4]:
		sum = sum + v
	assert_equal(9, sum)
