import lib.testing
import tests.generics_helper

# An instantiation BEFORE the definition (in file order): the call is
# recorded as a forward reference and resolved at the end of
# compilation, like any call to a not-yet-defined generic.
int forward_calls_smaller():
	return smaller[int](12, 7)


T smaller[T](T a, T b):
	if (a < b):
		return a
	return b


T max[T](T a, T b):
	if (a > b):
		return a
	return b


# Two type parameters
K pick_first[K, V](K key, V value):
	return key


# The body uses T and T* locals, and calls another (plain) function
int twice(int x):
	return x + x


T doubled_larger[T](T a, T b):
	T bigger = a
	T* p = &bigger
	if (b > a):
		*p = b
	return twice(*p)


# A generic calling another generic
T largest3[T](T a, T b, T c):
	return max[T](max[T](a, b), c)


struct pair[T]:
	T first
	T second


int sum_pair(pair[int]* p):
	return p.first + p.second


# A generic struct value as a parameter and a return value
pair[int] swap_pair(pair[int] p):
	pair[int] result
	result.first = p.second
	result.second = p.first
	return result


# Identity through a struct-valued type argument: T = pair[int]
T same[T](T x):
	return x


void test_max_int():
	assert_equal(5, max[int](3, 5))
	# same instantiation again: deduplicated, still correct
	assert_equal(9, max[int](9, 5))


void test_smaller_forward_and_after():
	# before the definition (see forward_calls_smaller above) and after
	assert_equal(7, forward_calls_smaller())
	assert_equal(3, smaller[int](3, 8))


void test_max_char():
	char a = 'a'
	char z = 'z'
	assert_equal('z', max[char](a, z))


void test_char_pointer_type_arg():
	char* hello = c"hello"
	char* world = c"world"
	char* got = pick_first[char*, int](hello, 42)
	assert_equal(0, strcmp(got, c"hello"))


void test_two_type_params():
	assert_equal(11, pick_first[int, char*](11, c"ignored"))


void test_body_locals_and_plain_call():
	assert_equal(16, doubled_larger[int](3, 8))
	assert_equal(16, doubled_larger[int](8, 3))


void test_generic_calls_generic():
	assert_equal(9, largest3[int](4, 9, 2))
	assert_equal(9, largest3[int](9, 2, 4))


void test_generic_struct_local_and_pointer():
	pair[int] p
	p.first = 1
	p.second = 2
	assert_equal(1, p.first)
	pair[int]* pp = &p
	pp.second = 22
	assert_equal(22, p.second)
	assert_equal(23, sum_pair(&p))


void test_generic_struct_char_pointer():
	pair[char*] names
	names.first = c"alpha"
	names.second = c"beta"
	assert_equal(0, strcmp(names.first, c"alpha"))
	assert_equal(0, strcmp(names.second, c"beta"))


void test_generic_struct_by_value():
	pair[int] p
	p.first = 3
	p.second = 4
	pair[int] swapped = swap_pair(p)
	assert_equal(4, swapped.first)
	assert_equal(3, swapped.second)


void test_struct_type_argument():
	pair[int] p
	p.first = 5
	p.second = 6
	pair[int] copy = same[pair[int]](p)
	assert_equal(5, copy.first)
	assert_equal(6, copy.second)


void test_cross_file_generic():
	# box[T]/unbox[T] come from tests/generics_helper.w, which also
	# instantiates box[int]/unbox[int] itself (deduplicated here)
	box[int] b
	b.value = 77
	assert_equal(77, unbox[int](&b))
	assert_equal(30, helper_boxed_sum(10, 20))
	box[char] c
	c.value = 'x'
	assert_equal('x', unbox[char](&c))
