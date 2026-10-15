# wbuild: name=javascript_runtime_binary_test
# wbuild: target=javascript_runtime_binary_test tag=tests dep=javascript_parser
# wbuild: step="bin/wv2 x64 tests/javascript/runtime_binary_test.w -o bin/javascript_runtime_binary_test"
# wbuild: step="bin/javascript_runtime_binary_test" expect_stdout="javascript_runtime_binary_test: OK"
# wbuild: step="bin/javascript_runtime_binary_test memory" expect_stdout="javascript_runtime_binary_test: OK"
import lib.assert
import lib.args
import libs.extras.javascript.runtime


void binary_test_eval(js_runtime* rt, char* source):
	js_completion* result = js_runtime_eval(rt, source, strlen(source), 100000)
	assert_equal(0, result.status)
	assert1(result.value.number == 1.0)


void test_binary():
	js_runtime* rt = js_runtime_new()
	binary_test_eval(rt, c"let b = new ArrayBuffer(32); let u = new Uint8Array(b); let d = new DataView(b); u.length === 32 && u.byteLength === 32 && u[0] === 0 && u.buffer === b;")
	binary_test_eval(rt, c"u.set([1,2,3,4]); u.set(u.subarray(0,3),1); u[0] === 1 && u[1] === 1 && u[2] === 2 && u[3] === 3;")
	binary_test_eval(rt, c"let s = u.subarray(-2); s[0] = 257; s.byteOffset === 30 && s.length === 2 && u[30] === 1;")
	binary_test_eval(rt, c"d.setInt32(1,-123456,true); d.getInt32(1,true) === -123456 && d.getUint32(1,true) === 4294843840;")
	binary_test_eval(rt, c"d.setUint16(0,4660); u[0] === 18 && u[1] === 52 && d.getUint16(0) === 4660;")
	binary_test_eval(rt, c"let f = new Float32Array(b,8,2); f[0] = 1.5; d.getFloat32(8,true) === 1.5 && f.length === 2 && f.byteLength === 8;")
	binary_test_eval(rt, c"d.setFloat64(17,-3.25); d.getFloat64(17) === -3.25;")
	binary_test_eval(rt, c"let copy = new Uint8Array(u); copy[0] = 99; u[0] === 18 && copy.buffer !== b && ArrayBuffer.isView(copy) && !ArrayBuffer.isView(b);")
	binary_test_eval(rt, c"let failures = 0; try { new Float32Array(b,1); } catch(e) { if(e.name === 'RangeError') failures++; } try { new DataView(b,33); } catch(e) { failures++; } try { d.getUint32(30); } catch(e) { failures++; } try { u.set([1,2],31); } catch(e) { failures++; } failures === 4;")
	binary_test_eval(rt, c"u[32] = 7; u[-1] = 8; u[32] === undefined && u[-1] === undefined;")
	binary_test_eval(rt, c"let big = new Uint8Array(20000); big[19000] = -1; big[19000] === 255;")
	binary_test_eval(rt, c"let encoder = new TextEncoder(); let decoder = new TextDecoder(); let encoded = encoder.encode('文\\u0000🙂'); encoded.length === 8 && decoder.decode(encoded) === '文\\u0000🙂';")
	binary_test_eval(rt, c"decoder.decode(new Uint8Array([239,187,191,65])) === 'A' && decoder.decode(new Uint8Array([226,130])) === '\\uFFFD';")
	binary_test_eval(rt, c"let fatal = false; try { new TextDecoder('utf-8',{fatal:true}).decode(new Uint8Array([255])); } catch(e) { fatal = true; } fatal;")
	js_runtime_collect(rt)
	binary_test_eval(rt, c"f[0] === 1.5 && s[0] === 1;")
	js_value* buffer = js_runtime_get(rt, rt.global, c"b")
	assert_equal(1, js_runtime_array_buffer_detach(rt, buffer))
	binary_test_eval(rt, c"b.byteLength === 0 && u.length === 0 && u[0] === undefined;")
	binary_test_eval(rt, c"let detached = false; try { d.getUint8(0); } catch(e) { detached = true; } detached;")
	js_runtime_free(rt)


void test_binary_host():
	js_runtime* rt = js_runtime_new()
	byte* bytes = cast(byte*, malloc(16))
	for i in range(16): bytes[i] = cast(byte, i)
	js_value* wrapped = js_runtime_array_buffer_wrap(rt, bytes, 16)
	js_value* view = js_runtime_binary_view(rt, 2, wrapped, 4, 8)
	assert_equal(1, js_runtime_root(rt, view))
	js_runtime_collect(rt)
	assert1(js_runtime_binary_data(rt, view) == bytes + 4)
	assert_equal(8, js_runtime_binary_byte_length(rt, view))
	js_value* copied = js_runtime_array_buffer_copy(rt, bytes, 16)
	bytes[0] = 99
	assert_equal(0, cast(int, js_runtime_binary_data(rt, copied)[0]))
	assert_equal(16, rt.binary_bytes_used)
	js_runtime_collect(rt)
	assert_equal(0, rt.binary_bytes_used)
	assert_equal(1, js_runtime_array_buffer_detach(rt, wrapped))
	assert1(js_runtime_binary_data(rt, view) == 0)
	assert_equal(0, js_runtime_binary_byte_length(rt, view))
	free(bytes)
	js_runtime_unroot(rt, view)
	js_runtime_collect(rt)
	rt.max_binary_bytes = 8
	js_value* owned = js_runtime_array_buffer(rt, 8)
	assert1(owned != rt.undefined_value)
	assert1(js_runtime_array_buffer(rt, 1) == rt.undefined_value)
	assert_equal(5, rt.completion.status)
	js_runtime_free(rt)


int main(int argc, int argv):
	args_init(argc, argv)
	if (argc > 1): malloc_force_debug_mode()
	if (argc == 1): test_binary()
	test_binary_host()
	if (argc > 1): assert_equal(0, debug_alloc_report_leaks())
	println(c"javascript_runtime_binary_test: OK")
	return 0
