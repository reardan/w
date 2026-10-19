# wbuild: name=wasm_execution_test arch_only=x64
# Validated operand/local access must preserve exact fuel and repeated calls.
import lib.testing
import libs.extras.wasm.runtime

void test_wasm_locals_fuel_and_reuse():
	# (i32) -> i32, two additional locals: x * (x + 7).
	char* bytes = c"\x00asm\x01\x00\x00\x00\x01\x06\x01\x60\x01\x7f\x01\x7f\x03\x02\x01\x00\x0a\x15\x01\x13\x01\x02\x7f\x01\x20\x00\x22\x02\x41\x07\x6a\x21\x01\x20\x01\x20\x02\x6c\x0b"
	wwasm* m = wwasm_load(bytes, 43)
	asserts(c"valid local operations", m.valid)
	list[int] args = new list[int]
	args.push(5)
	for fuel in range(12):
		int result = wwasm_call(m, 0, args, fuel)
		assert_equal(0, m.depth)
		assert_equal(0, m.fuel)
		if (fuel == 11):
			asserts(c"exact fuel succeeds", m.error == 0)
			assert_equal(60, result)
		else:
			asserts(c"insufficient fuel traps", m.error != 0)
			if (fuel == 0): assert_strings_equal(c"WebAssembly execution limit", m.error)
			else: assert_strings_equal(c"WebAssembly instruction limit", m.error)
	args[0] = -3
	assert_equal(-12, wwasm_call(m, 0, args, 20))
	assert_equal(9, m.fuel)
	asserts(c"repeat call resets locals and previous trap", m.error == 0)
	__w_list_free(cast(__w_list*, args))
	wwasm_free(m)

void test_wasm_nested_calls_keep_locals():
	# f0(x) stores x, calls f1(x) = x + 7, then adds its own unchanged local.
	char* bytes = c"\x00asm\x01\x00\x00\x00\x01\x06\x01\x60\x01\x7f\x01\x7f\x03\x03\x02\x00\x00\x0a\x17\x02\x0d\x01\x01\x7f\x20\x00\x22\x01\x10\x01\x20\x01\x6a\x0b\x07\x00\x20\x00\x41\x07\x6a\x0b"
	wwasm* m = wwasm_load(bytes, 46)
	asserts(c"valid nested functions", m.valid)
	list[int] args = new list[int]
	args.push(8)
	assert_equal(23, wwasm_call(m, 0, args, 12))
	asserts(c"nested call succeeds", m.error == 0)
	assert_equal(0, m.fuel)
	assert_equal(0, m.depth)
	__w_list_free(cast(__w_list*, args))
	wwasm_free(m)
