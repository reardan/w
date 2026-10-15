# wbuild: name=javascript_runtime_bigint_test
# wbuild: target=javascript_runtime_bigint_test tag=tests dep=javascript_parser
# wbuild: step="bin/wv2 x64 tests/javascript/runtime_bigint_test.w -o bin/javascript_runtime_bigint_test"
# wbuild: step="bin/javascript_runtime_bigint_test" expect_stdout="javascript_runtime_bigint_test: OK"
# wbuild: step="bin/javascript_runtime_bigint_test memory" expect_stdout="javascript_runtime_bigint_test: OK"
import lib.assert
import lib.args
import libs.extras.javascript.runtime


void bigint_test_eval(js_runtime* rt, char* source):
	js_completion* result = js_runtime_eval(rt, source, strlen(source), 10000)
	assert_equal(0, result.status)
	assert1(result.value.number == 1.0)


void test_bigint_scripts():
	js_runtime* rt = js_runtime_new()
	# Numeric separators are post-ES2020 and remain outside the parser contract.
	char* separator = c"1_000n;"
	assert_equal(6, js_runtime_eval(rt, separator, strlen(separator), 10000).status)
	bigint_test_eval(rt, c"typeof BigInt(42) === 'bigint' && BigInt(42) === 42n && 42n !== 42 && BigInt(true) === 1n && BigInt(false) === 0n && !0n && !!1n;")
	bigint_test_eval(rt, c"BigInt('18446744073709551615') === 0xffffffffffffffffn && BigInt('-9223372036854775808') === -9223372036854775808n && 0b101n === 5n && 0o17n === 15n && 1000n === BigInt(1000);")
	bigint_test_eval(rt, c"`${18446744073709551615n}` === '18446744073709551615' && `${-9223372036854775808n}` === '-9223372036854775808' && BigInt('  ') === 0n && BigInt(' +42 ') === 42n;")
	bigint_test_eval(rt, c"let errors = 0; try { BigInt(1.5); } catch(e) { if(e.name === 'RangeError') errors++; } try { BigInt('18446744073709551616'); } catch(e) { if(e.name === 'RangeError') errors++; } try { BigInt('-9223372036854775809'); } catch(e) { errors++; } try { BigInt('1.5'); } catch(e) { if(e.name === 'SyntaxError') errors++; } try { +1n; } catch(e) { if(e.name === 'TypeError') errors++; } errors === 5;")
	bigint_test_eval(rt, c"let b = new ArrayBuffer(24); let u = new Uint8Array(b); let d = new DataView(b); d.setBigUint64(1,18446744073709551615n,true); d.getBigUint64(1,true) === 18446744073709551615n && d.getBigInt64(1,true) === -1n && u[1] === 255 && u[8] === 255;")
	bigint_test_eval(rt, c"d.setBigUint64(0,0x0102030405060708n); u[0] === 1 && u[7] === 8 && d.getBigUint64(0,true) === 0x0807060504030201n;")
	bigint_test_eval(rt, c"d.setBigInt64(8,-9223372036854775808n,true); d.getBigInt64(8,true) === -9223372036854775808n && d.getBigUint64(8,true) === 9223372036854775808n;")
	bigint_test_eval(rt, c"d.setBigUint64(0,-1n); d.getBigUint64(0) === 18446744073709551615n && -(-9223372036854775808n) === 9223372036854775808n;")
	bigint_test_eval(rt, c"let rejected = 0; try { d.setBigUint64(0,1); } catch(e) { rejected++; } try { d.getBigUint64(17); } catch(e) { rejected++; } try { -18446744073709551615n; } catch(e) { rejected++; } rejected === 3;")
	bigint_test_eval(rt, c"d.setBigUint64(0,'9007199254740993',true); d.getBigUint64(0,true) === 9007199254740993n && !Number.isInteger(1n) && !Number.isFinite(1n);")
	js_runtime_collect(rt)
	bigint_test_eval(rt, c"d.getBigUint64(0,true) === 9007199254740993n;")
	js_runtime_free(rt)


void test_bigint_host():
	js_runtime* rt = js_runtime_new()
	int bits = 0
	js_value* signed_value = js_runtime_bigint_i64(rt, -1)
	js_value* unsigned_value = js_runtime_bigint_u64(rt, -1)
	assert_equal(10, signed_value.kind)
	assert_equal(1, js_runtime_bigint_bits(rt, signed_value, &bits))
	assert_equal(-1, bits)
	assert_equal(1, js_runtime_bigint_bits(rt, unsigned_value, &bits))
	assert_equal(-1, bits)
	assert_equal(0, js_runtime_equal(signed_value, unsigned_value))
	assert_equal(1, js_runtime_equal(js_runtime_bigint_i64(rt, 7), js_runtime_bigint_u64(rt, 7)))
	js_runtime_root(rt, signed_value)
	js_runtime_collect(rt)
	assert_equal(1, js_runtime_bigint_bits(rt, signed_value, &bits))
	assert_equal(-1, bits)
	assert_equal(0, js_runtime_bigint_bits(rt, js_runtime_number(rt, 1.0), &bits))
	assert_equal(2, rt.completion.status)
	js_runtime* other = js_runtime_new()
	assert_equal(0, js_runtime_bigint_bits(other, signed_value, &bits))
	assert_equal(2, other.completion.status)
	js_runtime_free(other)
	js_runtime_unroot(rt, signed_value)
	js_runtime_free(rt)


int main(int argc, int argv):
	args_init(argc, argv)
	if (argc > 1): malloc_force_debug_mode()
	if (argc == 1): test_bigint_scripts()
	test_bigint_host()
	if (argc > 1): assert_equal(0, debug_alloc_report_leaks())
	println(c"javascript_runtime_bigint_test: OK")
	return 0
