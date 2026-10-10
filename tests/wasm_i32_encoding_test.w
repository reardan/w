# Cross-host regression: an i32 bit pattern must encode identically even
# when folding produced a positive integer above INT32_MAX on a 64-bit host.
# wbuild: x64
import lib.lib
import lib.assert
import code_generator.wasm


int main():
	code_size = 128
	code = cast(char*, malloc(code_size))
	codepos = 0
	int high_bit = 0x7fffffff
	high_bit = high_bit + 1
	wasm_i32_const(high_bit)
	assert_equal(6, codepos)
	assert_equal(0x41, code[0] & 255)
	for i in range(1, 5): assert_equal(0x80, code[i] & 255)
	assert_equal(0x78, code[5] & 255)
	codepos = 0
	wasm_i32_const(high_bit + 0x7fffffff)
	assert_equal(2, codepos)
	assert_equal(0x7f, code[1] & 255)
	codepos = 0
	wasm_i32_const(0x7fffffff)
	assert_equal(6, codepos)
	assert_equal(0x07, code[5] & 255)
	free(code)
	return 0
