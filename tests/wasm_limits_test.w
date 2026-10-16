# wbuild: name=wasm_limits_test arch_only=x64
import lib.assert
import structures.string
import libs.extras.wasm.runtime

void source_leb(string_builder* bytes, int n):
	while (n >= 128):
		string_append_char(bytes, (n & 127) | 128)
		n = n >> 7
	string_append_char(bytes, n)

int main():
	string_builder* bytes = string_new()
	string_append_bytes(bytes, c"\x00asm\x01\x00\x00\x00", 8)
	string_append_char(bytes, 0)
	source_leb(bytes, 1048576)
	# Empty custom-section name, followed by uninterpreted payload bytes.
	for i in range(1048576): string_append_char(bytes, 0)
	wwasm* machine = wwasm_load(bytes.data, bytes.length)
	assert_equal(0, machine.valid)
	wwasm_free(machine)
	machine = wwasm_load_bounded(bytes.data, bytes.length, bytes.length, 524288)
	assert1(machine.valid)
	assert_equal(bytes.length, machine.length)
	assert_equal(0, machine.bytes[bytes.length - 1])
	wwasm_free(machine)
	machine = wwasm_load_bounded(bytes.data, bytes.length, bytes.length - 1, 524288)
	assert_equal(0, machine.valid)
	wwasm_free(machine)
	machine = wwasm_load_bounded(bytes.data, bytes.length, 67108865, 524288)
	assert_equal(0, machine.valid)
	wwasm_free(machine)
	machine = wwasm_load_bounded(bytes.data, -1, 4194304, 524288)
	assert_equal(0, machine.valid)
	wwasm_free(machine)
	# A larger allowance must not accept truncated section contents.
	machine = wwasm_load_bounded(bytes.data, bytes.length - 1, 4194304, 524288)
	assert_equal(0, machine.valid)
	wwasm_free(machine)
	string_free(bytes)
	char* small = c"\x00asm\x01\x00\x00\x00\x01\x05\x01\x60\x00\x01\x7f\x03\x02\x01\x00\x07\x05\x01\x01f\x00\x00\x0a\x06\x01\x04\x00\x41\x2a\x0b"
	machine = wwasm_load_bounded(small, 34, 1048576, 1)
	assert_equal(0, machine.valid)
	assert_strings_equal(c"decoded instruction limit", machine.error)
	wwasm_free(machine)
	machine = wwasm_load_bounded(small, 34, 1048576, 2)
	assert1(machine.valid)
	assert_equal(2, machine.op_count)
	wwasm_free(machine)
	machine = wwasm_load_bounded(small, 34, 1048576, 2097153)
	assert_equal(0, machine.valid)
	wwasm_free(machine)
	println(c"wasm_limits_test: OK")
	return 0
