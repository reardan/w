# The source-owned target tests the generated producer/consumer DAG
# as well as independent shared-library compilation and the SysV ABI.
# wbuild: binary=library_shared_test arch=x64 link=shared_fixture tag=tests
# wbuild: step="bin/library_shared_test" expect_stdout="shared library OK"
# wbuild: step="bin/wv2 --shared tests/library_shared_input.w -o bin/library_bad_arch.so" expect_fail expect_stderr="x64"
# wbuild: step="bin/wv2 x64 --shared tests/library_shared_tls_input.w -o bin/library_bad_tls.so" expect_fail expect_stderr="thread_local"
import lib.lib
import lib.assert
import lib.file

extern int shared_add(int a, int b)
extern int shared_sum8(int a, int b, int c, int d, int e, int f, int g, int h)
extern int shared_bump(int by)
extern char* shared_text()
extern float32 shared_scale32(float32 value, int factor)
extern float64 shared_scale64(float64 value, int factor, float64 offset)
extern float64 shared_sum9(float64 a, float64 b, float64 c, float64 d, float64 e, float64 f, float64 g, float64 h, float64 i)
extern int shared_pointer(int* value, int by)


int main():
	assert_equal(42, shared_add(17, 25))
	assert_equal(204, shared_sum8(1, 2, 3, 4, 5, 6, 7, 8))
	assert_equal(13, shared_bump(3))
	assert_equal(20, shared_bump(7))
	assert_strings_equal(c"shared library", shared_text())
	assert1(shared_scale32(1.5, 4) == 6.0)
	assert1(shared_scale64(2.5, 3, 0.25) == 7.75)
	assert1(shared_sum9(1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0) == 45.0)
	int value = 37
	assert_equal(42, shared_pointer(&value, 5))
	assert_equal(42, value)
	# ET_DYN, x86-64, and no executable entry point. A shared library
	# has a dynamic table and must not carry a PT_INTERP executable
	# loader request or any writable/executable load segment.
	char* image = file_read_text(c"bin/libshared_fixture.so")
	assert1(image != 0)
	assert_equal(3, load_i(image + 16, 2))
	assert_equal(62, load_i(image + 18, 2))
	assert_equal(0, load_int(image + 24))
	int dynamic = 0
	int phoff = load_int(image + 32)
	for i in range(load_i(image + 56, 2)):
		char* ph = image + phoff + i * 56
		int kind = load_i(ph, 4)
		assert1(kind != 3)
		if (kind == 2): dynamic = 1
		if (kind == 1): assert1((load_i(ph + 4, 4) & 3) != 3)
	assert_equal(1, dynamic)
	free(image)
	println(c"shared library OK")
	return 0
