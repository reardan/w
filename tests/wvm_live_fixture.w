# wbuild: binary=wvm_live_fixture arch=x64
import lib.lib
import lib.mem
import lib.assert

thread_local int live_tls
int live_global

type live_simd_fn = fn() -> int

int main():
	live_tls = 91
	live_global = 37
	int local = 123
	char* heap = cast(char*, malloc(4096))
	heap[123] = 77
	assert_equal(8, sys_getrandom(heap, 8, 0))
	int executable = mmap(0, 4096, 7, 34)
	asserts(c"SIMD fixture code", executable > 0)
	mem_copy[char](cast(char*, executable), c"\xb8\x4d\x00\x00\x00\x66\x48\x0f\x6e\xc0\xc3", 11)
	live_simd_fn* load_simd = cast(live_simd_fn*, executable)
	assert_equal(77, load_simd())
	assert_equal(6, write(1, c"before", 6))
	assert_equal(91, live_tls)
	assert_equal(37, live_global)
	assert_equal(123, local)
	assert_equal(77, cast(int, heap[123]))
	char[3] input
	assert_equal(3, read(0, &input[0], 3))
	assert_equal(3, write(1, &input[0], 3))
	assert_equal(8, write(1, heap, 8))
	live_global = live_global + 5
	assert_equal(42, live_global)
	free(heap)
	return 7
