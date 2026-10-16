# Internal arithmetic probes deliberately use raw runtime metadata. Public
# checked clients cannot construct or modify these descriptors.
# wbuild: x64
# wbuild: step="bin/safe_buffer_limits_test negative" expect_fail expect_stderr="allocation size overflow: "
# wbuild: step="bin/safe_buffer_limits_test addition" expect_fail expect_stderr="allocation size overflow: "
# wbuild: step="bin/safe_buffer_limits_test multiplication" expect_fail expect_stderr="allocation size overflow: "
# wbuild: step="bin/safe_buffer_limits_test bytes" expect_fail expect_stderr="allocation size overflow: "
# wbuild: step="bin/safe_buffer_limits_test oom" expect_fail expect_stderr="out of memory: allocation of "
import lib.safe_buffer
import lib.assert

int buffer_fail_malloc(int size):
	return 0


int buffer_fail_realloc(int old, int old_length, int new_length):
	return 0


void test_growth_arithmetic():
	WIntBuffer buffer
	buffer.capacity = 0
	buffer.length = 0
	buffer.items = 0
	__w_int_buffer_ensure(&buffer, 9)
	assert_equal(9, buffer.capacity)
	assert_equal(0, buffer.length)
	buffer.length = 9
	__w_int_buffer_ensure(&buffer, 1)
	assert_equal(18, buffer.capacity)
	assert_equal(9, buffer.length)
	free(buffer.items)


int main(int argc, char** argv):
	if (argc == 1):
		test_growth_arithmetic()
		return 0
	WIntBuffer buffer
	buffer.capacity = 0
	buffer.length = 0
	buffer.items = 0
	if (strcmp(argv[1], c"negative") == 0): __w_int_buffer_ensure(&buffer, -1)
	if (strcmp(argv[1], c"addition") == 0):
		buffer.length = __w_word_max()
		__w_int_buffer_ensure(&buffer, 1)
	if (strcmp(argv[1], c"multiplication") == 0): __w_int_buffer_ensure(&buffer, __w_word_max())
	if (strcmp(argv[1], c"bytes") == 0):
		WByteString value
		value.capacity = 0
		value.length = __w_word_max()
		value.items = 0
		__w_byte_string_ensure(&value, 1)
	if (strcmp(argv[1], c"oom") == 0):
		malloc_hook_set(cast(int, buffer_fail_malloc), 0, cast(int, buffer_fail_realloc))
		__w_int_buffer_ensure(&buffer, 1)
	return 0
