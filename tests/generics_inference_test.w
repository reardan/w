# wbuild: x64
import lib.testing

# Generic type-argument inference (docs/projects/generics.md): a call
# to a generic function without the '[type-args]' list infers the type
# arguments from the argument types. Explicit instantiation coverage
# lives in tests/generics_test.w and must keep passing unchanged.

T max[T](T a, T b):
	if (a > b):
		return a
	return b


K pick_first[K, V](K key, V value):
	return key


T first_of[T](T* p):
	return *p


void swap[T](T* a, T* b):
	T tmp = *a
	*a = *b
	*b = tmp


T same[T](T x):
	return x


# T constrained through the first parameter only; the second is a
# concrete type that gets the ordinary argument check and coercion
T scaled[T](T a, int factor):
	return a * factor


# Inference inside a generic body compiled at the drain: max's type
# argument is inferred from the already-substituted T-typed values
T largest3[T](T a, T b, T c):
	return max(max(a, b), c)


# A recursive inferred call inside the instantiation's own body
T rec_sum[T](T a, T depth):
	if (depth <= 0):
		return a
	return rec_sum(a, depth - 1) + a


void test_int_literals():
	assert_equal(5, max(3, 5))
	assert_equal(9, max(9, 5))


void test_int_vars():
	int a = 4
	int b = 11
	assert_equal(11, max(a, b))
	assert_equal(11, max(b, a))


void test_char_args():
	char a = 'a'
	char z = 'z'
	assert_equal('z', max(a, z))


void test_bool_args():
	bool t = true
	bool f = false
	assert_equal(1, max(f, t))


void test_pointer_args():
	int x = 7
	int y = 42
	int* p = &x
	int* q = &y
	swap(p, q)
	assert_equal(42, x)
	assert_equal(7, y)
	assert_equal(7, first_of(q))
	char* s = c"hi"
	assert_equal('h', first_of(s))


void test_char_pointer_binding():
	char* s = same(c"walrus")
	assert_equal(0, strcmp(s, c"walrus"))


void test_multi_param():
	assert_equal(11, pick_first(11, c"ignored"))
	char* got = pick_first(c"hello", 42)
	assert_equal(0, strcmp(got, c"hello"))


void test_mixed_concrete_param():
	assert_equal(42, scaled(6, 7))


void test_shared_instantiation():
	# inferred and explicit calls of the same generic and types share
	# one instantiation (both are max$int) and agree on results
	assert_equal(5, max(3, 5))
	assert_equal(5, max[int](3, 5))
	assert_equal(8, max[int](8, 2))
	assert_equal(8, max(8, 2))


void test_nested_inference():
	assert_equal(3, max(max(1, 2), 3))
	assert_equal(9, max(max(9, 2), max(4, 8)))


void test_inference_in_expressions():
	assert_equal(13, 3 + max(4, 5) * 2)
	int total = 0
	for int i in range(3):
		total = total + max(i, 1)
	assert_equal(4, total)


void test_float_args():
	# a float literal binds T to the literal's type (float32 on x86,
	# float64 on x64); a later untyped constant coerces to the binding
	assert_equal(1, max(1.5, 0.5) == 1.5)
	assert_equal(1, max(1.5, 2) == 2.0)


void test_generic_body_and_recursion():
	assert_equal(9, largest3(4, 9, 2))
	assert_equal(9, largest3[int](9, 2, 4))
	assert_equal(15, rec_sum(5, 2))
