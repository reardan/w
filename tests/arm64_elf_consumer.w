# Linux runtime coverage for the ELF mechanisms shared with Android.
# Uses the existing tests_arm64 QEMU/native runner and cross libc only.
# wbuild: target=arm64_elf_pie_test tag=tests_arm64 dep=wv2 dep=wrun
# wbuild: step="bin/wv2 arm64 --pie tests/android_elf_fixture.w -o bin/arm64_elf_static"
# wbuild: step="bin/wrun arm64 bin/arm64_elf_static" expect_stdout="Android PIE OK"
# wbuild: step="bin/wv2 arm64 --pie tests/android_elf_fixture.w tests/elf_pie_imports.w -o bin/arm64_elf_dynamic"
# wbuild: step="bin/wrun arm64 bin/arm64_elf_dynamic" expect_stdout="Android PIE OK"
# wbuild: step="bin/wv2 arm64 --shared tests/android_elf_fixture.w tests/elf_pie_imports.w -o bin/libarm64_pie_fixture.so"
# wbuild: step="bin/wv2 arm64 --pie tests/arm64_elf_consumer.w -o bin/arm64_elf_consumer"
# wbuild: step="bin/wrun arm64 bin/arm64_elf_consumer" expect_stdout="ARM64 PIE/shared OK"
import lib.lib
import lib.assert

c_lib "bin/libarm64_pie_fixture.so"
extern int android_sum10(int a, int b, int c, int d, int e, int f, int g, int h, int i, int j)
extern float32 android_float(float32 a, int b)
extern float64 android_double(float64 a, float64 b, float64 c, float64 d, float64 e, float64 f, float64 g, float64 h, float64 i)
extern int android_relocated()

int main():
	assert_equal(55, android_sum10(1, 2, 3, 4, 5, 6, 7, 8, 9, 10))
	assert1(android_float(1.5, 4) == 6.0)
	assert1(android_double(1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0) == 45.0)
	assert_equal(42, android_relocated())
	println(c"ARM64 PIE/shared OK")
	return 0
