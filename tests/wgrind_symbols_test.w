# wbuild: target=wgrind_symbols_test tag=tests dep=wv2
# wbuild: step="bin/wv2 x64 tests/wgrind_symbols_test.w -o bin/wgrind_symbols_test"
# wbuild: step="bin/wgrind_symbols_test" expect_stdout="wgrind_symbols_test: OK"
import lib.assert
import libs.wgrind.execute_symbols


void symbol_put(char* data, int offset, int size, int value):
	for i in range(size): data[offset + i] = (value >> (i * 8)) & 255


# Three sections: null, symbol table, string table. Keep headers and
# payloads disjoint so every malformed-offset case has a precise bound.
void symbol_image(char* data, int dynamic, int w_abi):
	for i in range(512): data[i] = 0
	data[0] = 127
	data[1] = 'E'
	data[2] = 'L'
	data[3] = 'F'
	data[4] = 2
	data[5] = 1
	data[6] = 1
	symbol_put(data, 16, 2, 2 + dynamic)
	symbol_put(data, 18, 2, 62)
	symbol_put(data, 40, 8, 64)
	symbol_put(data, 58, 2, 64)
	symbol_put(data, 60, 2, 3)
	symbol_put(data, 128 + 4, 4, 2 + dynamic * 9)
	symbol_put(data, 128 + 24, 8, 256)
	symbol_put(data, 128 + 32, 8, 72)
	symbol_put(data, 128 + 40, 4, 2)
	symbol_put(data, 128 + 56, 8, 24)
	symbol_put(data, 192 + 4, 4, 3)
	symbol_put(data, 192 + 24, 8, 384)
	symbol_put(data, 192 + 32, 8, 32)
	char* names = c"\0malloc\0free\0malloc_backend\0"
	for i in range(27): data[384 + i] = names[i]
	symbol_put(data, 256, 4, 1)
	data[256 + 4] = 18 # STB_GLOBAL, STT_FUNC
	symbol_put(data, 256 + 6, 2, 1)
	symbol_put(data, 256 + 8, 8, 4096)
	symbol_put(data, 256 + 16, 8, 64)
	symbol_put(data, 280, 4, 8)
	data[280 + 4] = 18
	symbol_put(data, 280 + 6, 2, 1)
	symbol_put(data, 280 + 8, 8, 8192)
	symbol_put(data, 280 + 16, 8, 32)
	if (w_abi):
		symbol_put(data, 304, 4, 13)
		data[304 + 4] = 18
		symbol_put(data, 304 + 6, 2, 1)
		symbol_put(data, 304 + 8, 8, 12288)


void check_symbol_tables():
	char[512] image
	wg_context* c = wg_create(1, 1, 0)
	assert1(c != 0)
	assert_equal(0, c.error)
	wg_symbols symbols
	wg_symbols_init(&symbols, c, 16)
	symbol_image(&image[0], 0, 0)
	assert1(wg_symbols_image(&symbols, &image[0], 512, 123456))
	assert_equal(2, symbols.allocators.length)
	assert_equal(1, wg_symbols_at(&symbols, 4096))
	assert_equal(2, wg_symbols_at(&symbols, 8192))
	assert_equal(0, wg_symbols_at(&symbols, 4097))
	assert1(wg_symbols_allocator_contains(&symbols, 4096, 4096))
	assert1(wg_symbols_allocator_contains(&symbols, 4096, 4159))
	assert_equal(0, wg_symbols_allocator_contains(&symbols, 4096, 4160))
	assert_equal(0, wg_symbols_allocator_contains(&symbols, 4096, 4095))
	# Repeated image scans deduplicate aliases at the same loaded address.
	assert1(wg_symbols_image(&symbols, &image[0], 512, 0))
	assert_equal(2, symbols.allocators.length)
	symbol_image(&image[0], 1, 0)
	int high_bias = 1 << 40
	assert1(wg_symbols_image(&symbols, &image[0], 512, high_bias))
	assert_equal(4, symbols.allocators.length)
	assert_equal(1, wg_symbols_at(&symbols, high_bias + 4096))
	assert_equal(2, wg_symbols_at(&symbols, high_bias + 8192))
	symbol_image(&image[0], 0, 1)
	assert1(wg_symbols_image(&symbols, &image[0], 512, 0))
	assert_equal(1, symbols.w_abi)
	assert_equal(4, symbols.allocators.length)
	wg_symbols_destroy(&symbols)
	wg_destroy(c)


void check_symbol_bounds():
	char[512] image
	for scenario in range(10):
		symbol_image(&image[0], 0, 0)
		int length = 512
		if (scenario == 0): length = 18
		elif (scenario == 1): symbol_put(&image[0], 40, 8, -64)
		elif (scenario == 2): symbol_put(&image[0], 128 + 24, 8, 500)
		elif (scenario == 3): symbol_put(&image[0], 128 + 40, 4, 3)
		elif (scenario == 4): symbol_put(&image[0], 256, 4, 32)
		elif (scenario == 5):
			for i in range(384, 416): image[i] = 'x'
		elif (scenario == 6): symbol_put(&image[0], 128 + 56, 8, 16)
		elif (scenario == 7): symbol_put(&image[0], 192 + 32, 8, -1)
		elif (scenario == 8): symbol_put(&image[0], 128 + 32, 8, 71)
		else: image[5] = 2
		wg_context* c = wg_create(1, 1, 0)
		assert1(c != 0)
		wg_symbols symbols
		wg_symbols_init(&symbols, c, 16)
		assert_equal(0, wg_symbols_image(&symbols, &image[0], length, 0))
		assert_equal(WG_INCOMPLETE, c.error)
		wg_symbols_destroy(&symbols)
		wg_destroy(c)
	wg_context* c = wg_create(1, 1, 0)
	assert1(c != 0)
	wg_symbols symbols
	wg_symbols_init(&symbols, c, 1)
	symbol_image(&image[0], 0, 0)
	assert_equal(0, wg_symbols_image(&symbols, &image[0], 512, 0))
	assert_equal(WG_INCOMPLETE, c.error)
	wg_symbols_destroy(&symbols)
	wg_destroy(c)


int main():
	check_symbol_tables()
	check_symbol_bounds()
	println(c"wgrind_symbols_test: OK")
	return 0
