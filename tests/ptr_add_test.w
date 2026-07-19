# wbuild: x64
import lib.testing
import lib.ptr

# ptr_add[T](p, n) == &p[n]: scaled by T's width, unlike raw `p + n`
# (a byte offset for every pointee width -- see CLAUDE.md's "T* + int"
# rule and the inflate.w Huffman-table bug in
# docs/projects/ai_tooling_next_steps.md).


struct triple:
	int a
	int b
	int c


void test_int_pointer_scales():
	# int is word-sized: 4 bytes on x86, 8 on x64 (__word_size__)
	int* base = cast(int*, malloc(__word_size__ * 5))
	base[0] = 10
	base[1] = 20
	base[2] = 30
	base[3] = 40
	base[4] = 50

	int* two_ahead = ptr_add(base, 2)
	assert_equal(30, *two_ahead)
	assert_equal(cast(int, &base[2]), cast(int, two_ahead))

	# The whole point: ptr_add is NOT the same as raw pointer + int.
	# Raw `+` moves __word_size__ times too little per element.
	int* raw_two_ahead = base + 2
	assert1(cast(int, two_ahead) != cast(int, raw_two_ahead))
	assert_equal(__word_size__ * 2, cast(int, two_ahead) - cast(int, base))
	assert_equal(2, cast(int, raw_two_ahead) - cast(int, base))

	free(base)


void test_int_pointer_negative_offset():
	int* base = cast(int*, malloc(__word_size__ * 5))
	base[0] = 10
	base[1] = 20
	base[2] = 30
	base[3] = 40
	base[4] = 50

	int* at_three = ptr_add(base, 3)
	int* back_to_one = ptr_add(at_three, -2)
	assert_equal(20, *back_to_one)
	assert_equal(cast(int, &base[1]), cast(int, back_to_one))

	free(base)


void test_char_pointer_stride_one():
	# char is 1 byte, so ptr_add and raw `+` agree here -- the bug only
	# bites wider pointee types.
	char* s = c"hello world"
	char* at_six = ptr_add(s, 6)
	assert_equal('w', *at_six)
	assert_equal(cast(int, s + 6), cast(int, at_six))

	char* back_two = ptr_add(at_six, -2)
	assert_equal('o', *back_two)


# No sizeof operator in W (see lib/ptr.w's ptr_diff), so recover a
# struct's stride the same way: compare where index 1 lands.
int sizeof_triple():
	triple* probe = cast(triple*, malloc(__word_size__ * 8))
	int stride = cast(int, &probe[1]) - cast(int, probe)
	free(probe)
	return stride


void test_struct_pointer_scales():
	triple* arr = cast(triple*, malloc(sizeof_triple() * 3))
	arr[0].a = 1
	arr[0].b = 2
	arr[0].c = 3
	arr[1].a = 4
	arr[1].b = 5
	arr[1].c = 6
	arr[2].a = 7
	arr[2].b = 8
	arr[2].c = 9

	triple* second = ptr_add(arr, 1)
	assert_equal(4, second.a)
	assert_equal(5, second.b)
	assert_equal(6, second.c)
	assert_equal(cast(int, &arr[1]), cast(int, second))

	triple* back_to_first = ptr_add(second, -1)
	assert_equal(1, back_to_first.a)

	free(arr)


void test_ptr_diff_round_trips():
	int* base = cast(int*, malloc(__word_size__ * 5))
	int* three_ahead = ptr_add(base, 3)
	assert_equal(3, ptr_diff(three_ahead, base))
	assert_equal(cast(int, three_ahead), cast(int, ptr_add(base, ptr_diff(three_ahead, base))))
	free(base)
