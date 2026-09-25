# wbuild: x64
import lib.testing

# sizeof(T) (issue #434): a type's size in bytes as a compile-time int.


struct sizeof_pair:
	char tag
	int value


struct sizeof_nested:
	sizeof_pair first
	int16 count


union sizeof_either:
	char small
	int32 big


void test_builtin_sizes():
	assert_equal(1, sizeof(char))
	assert_equal(1, sizeof(bool))
	assert_equal(1, sizeof(int8))
	assert_equal(2, sizeof(int16))
	assert_equal(4, sizeof(int32))
	assert_equal(2, sizeof(uint16))
	assert_equal(4, sizeof(float32))
	assert_equal(__word_size__, sizeof(int))
	assert_equal(__word_size__, sizeof(uint))


void test_pointer_sizes():
	assert_equal(__word_size__, sizeof(char*))
	assert_equal(__word_size__, sizeof(int**))
	assert_equal(__word_size__, sizeof(sizeof_pair*))


# Struct sizes are the packed field sum and match the indexing stride.
void test_struct_sizes():
	assert_equal(1 + __word_size__, sizeof(sizeof_pair))
	sizeof_pair* probe = cast(sizeof_pair*, 0)
	assert_equal(cast(int, &probe[1]), sizeof(sizeof_pair))
	sizeof_nested* nested = cast(sizeof_nested*, 0)
	assert_equal(cast(int, &nested[1]), sizeof(sizeof_nested))
	assert_equal(4, sizeof(sizeof_either))


void test_sizeof_in_expressions():
	int n = 3
	sizeof_pair* arr = cast(sizeof_pair*, malloc(n * sizeof(sizeof_pair)))
	arr[2].tag = 'z'
	arr[2].value = 42
	assert_equal('z', arr[2].tag)
	assert_equal(42, arr[2].value)
	free(arr)
	assert_equal(sizeof(char) + sizeof(int), sizeof(sizeof_pair))
