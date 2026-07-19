# wbuild: x64
import lib.testing


# Pointer + integer / pointer - integer keep the pointer's type
# (grammar/additive_expr.w), so dereferencing or indexing the
# parenthesized result reads the ELEMENT's width. Before the fix the
# result was an untyped constant: *(p - 1) read a full word regardless
# of element type and (p - 1)[i] fell back to byte elements, so a char
# deref in a comparison or boolean context dragged in the neighboring
# bytes. The offset itself stays a raw, unscaled byte offset (T* + n
# advances n bytes on every target); only indexing scales.


void test_char_deref_in_comparison():
	char* s = c"AB"
	char* t = s + 1
	asserts(c"compare form must read one byte", (*(t - 1)) == 'A')
	assert_equal('A', *(t - 1))
	assert_equal('A', (t - 1)[0])
	char v = *(t - 1)
	assert_equal('A', v)


void test_char_deref_truthiness():
	# buf[0] = 0 with nonzero bytes after it: a wider-than-byte read at
	# buf[0] is nonzero while the byte itself is zero. Built in writable
	# memory: string literals live in a read-only segment on arm64.
	char* buf = malloc(4)
	buf[0] = 0
	buf[1] = 'X'
	buf[2] = 'Y'
	buf[3] = 0
	char* p = buf + 1
	int wide = 0
	if (*(p - 1)):
		wide = 1
	assert_equal(0, wide)
	int negated = 0
	if (!(*(p - 1))):
		negated = 1
	assert_equal(1, negated)


void test_word_element_deref_and_index():
	int* p = cast(int*, malloc(4 * __word_size__))
	p[0] = 11
	p[1] = 22
	p[2] = 33
	# byte offset, element-wide read
	assert_equal(22, *(p + __word_size__))
	assert_equal(22, (p + __word_size__)[0])
	# indexing the arithmetic result scales by the element width
	assert_equal(33, (p + __word_size__)[1])
	# integer + pointer commutes
	assert_equal(22, *(__word_size__ + p))
	# chained arithmetic keeps the type
	assert_equal(33, *((p + __word_size__) + __word_size__))
	free(p)


void test_store_through_arithmetic_deref():
	int* p = cast(int*, malloc(3 * __word_size__))
	p[0] = 1
	p[1] = 2
	p[2] = 3
	*(p + __word_size__) = 44
	assert_equal(44, p[1])
	assert_equal(1, p[0])
	assert_equal(3, p[2])
	free(p)


void test_pointer_difference_is_integer():
	char* s = c"hello"
	char* e = s + 5
	assert_equal(5, e - s)
	int distance = e - s
	assert_equal(5, distance)
	int* p = cast(int*, 0)
	int* q = p + 3 * __word_size__
	# pointer difference is a byte distance, matching T* + n
	assert_equal(3 * __word_size__, q - p)


void test_arithmetic_result_assigns_to_pointer():
	char* s = c"AB"
	char* t = s + 1
	char* back = t - 1
	assert_equal('A', back[0])
	assert_equal('A', *back)
