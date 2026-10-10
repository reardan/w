# wbuild: x64
# Exercise page-size-dependent allocation on an ordinary 4 KB host and
# the Android fstatat translation without needing an Android device.
import lib.assert
import lib.page_size
import lib.arm64.android_stat


void check_page_layout(int page):
	int previous = runtime_page_size_cached
	runtime_page_size_cached = page
	assert_equal(1, debug_pages_for(page))
	assert_equal(2, debug_pages_for(page + 1))
	char* p = cast(char*, debug_malloc(page + 8))
	asserts(c"debug allocation", p != 0)
	int idx = debug_tbl_find(cast(int, p))
	assert_equal(2 * page, debug_tbl_region_size[idx])
	assert_equal(0, (cast(int, p) + page + 8 - debug_tbl_region[idx]) % page)
	p[0] = 12
	p[page + 7] = 34
	assert_equal(12, p[0])
	assert_equal(34, p[page + 7])
	char[16] vec
	asserts(c"payload remains mapped", sys_mincore(debug_tbl_region[idx], page, cast(int, &vec[0])) == 0)
	asserts(c"guard is unmapped", sys_mincore(cast(int, p) + page + 8, page, cast(int, &vec[0])) != 0)
	debug_free(p)
	debug_quarantine_reclaim_to(0)
	runtime_page_size_cached = previous


int main():
	int[6] auxv
	auxv[0] = 3
	auxv[1] = 42
	auxv[2] = 6
	auxv[3] = 16384
	auxv[4] = 0
	auxv[5] = 0
	assert_equal(16384, runtime_page_size_from_auxv(&auxv[0]))
	auxv[3] = 12345
	assert_equal(0, runtime_page_size_from_auxv(&auxv[0]))
	auxv[0] = 0
	assert_equal(0, runtime_page_size_from_auxv(&auxv[0]))
	check_page_layout(4096)
	check_page_layout(16384)
	check_page_layout(65536)

	char[128] raw
	char[256] result
	for i in range(128): raw[i] = 0
	for i in range(256): result[i] = 99
	save_i(&raw[0], 0x12345678, 8)
	save_i(&raw[8], 123, 8)
	save_int32(&raw[16], 33188)
	save_int32(&raw[20], 2)
	save_int32(&raw[24], 1001)
	save_int32(&raw[28], 1002)
	save_i(&raw[48], 54321, 8)
	save_int32(&raw[56], 16384)
	save_i(&raw[64], 112, 8)
	save_i(&raw[72], 100, 8)
	save_i(&raw[80], 123456789, 8)
	save_i(&raw[88], 200, 8)
	save_i(&raw[96], 234567891, 8)
	save_i(&raw[104], 300, 8)
	save_i(&raw[112], 345678912, 8)
	android_stat_to_statx(&raw[0], &result[0])
	assert_equal(2047, load_int32(&result[0]))
	assert_equal(16384, load_int32(&result[4]))
	assert_equal(2, load_int32(&result[16]))
	assert_equal(1001, load_int32(&result[20]))
	assert_equal(1002, load_int32(&result[24]))
	assert_equal(33188, load_int16(&result[28]))
	assert_equal(123, load_i(&result[32], 8))
	assert_equal(54321, load_i(&result[40], 8))
	assert_equal(112, load_i(&result[48], 8))
	assert_equal(100, load_i(&result[64], 8))
	assert_equal(123456789, load_int32(&result[72]))
	assert_equal(300, load_i(&result[96], 8))
	assert_equal(345678912, load_int32(&result[104]))
	assert_equal(200, load_i(&result[112], 8))
	assert_equal(234567891, load_int32(&result[120]))
	assert_equal(0, load_i(&result[80], 8))
	assert_equal(0x456, load_int32(&result[136]))
	assert_equal(0x12378, load_int32(&result[140]))
	assert_equal(0, result[255])
	println2(c"android_runtime_layout_test: OK")
	return 0
