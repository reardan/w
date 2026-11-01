# wbuild: x64
# wbuild: target=symbol_address_test_darwin dep=wv2 tag=tests
# wbuild: step="bin/wv2 arm64_darwin tests/symbol_address_test.w -o bin/symbol_address_test_darwin"
import lib.testing
import compiler.compiler
import lib.process


# The compiler's packed records retain native host addresses even when
# their low word has its sign bit set. Locals remain signed integers.
void test_symbol_value_preserves_host_word():
	char* saved_table = table
	table = cast(char*, malloc(symbol_data_size + 8))
	for i in range(symbol_data_size + 8): table[i] = 0
	int t = 8
	sym_set_value_at(t, -7)
	assert_equal(-7, sym_value_at(t))
	sym_set_value_at(t, 0)
	assert_equal(0, sym_value_at(t))
	if (__word_size__ == 8):
		int high = 0x12345 << 16
		high = high << 16
		int value = high | (1 << 31) | 0x4567
		sym_set_value_at(t, value)
		assert_equal(value, sym_value_at(t))
		assert_equal(0x12345, load_int(table + t + 162))
		# The high word must be replaced when a packed slot is reused.
		sym_set_value_at(t, 19)
		assert_equal(19, sym_value_at(t))
	free(table)
	table = saved_table


# Exercise the actual A64 prototype chain, including its code_offset
# sentinel, at high native addresses and across a 4 GB boundary. No code
# is executed: this runs under the x86/x64 compiler-coverage jobs too.
void test_arm64_high_address_forward_chain():
	char* saved_table = table
	char* saved_code = code
	int saved_code_size = code_size
	int saved_codepos = codepos
	int saved_offset = code_offset
	int saved_isa = target_isa
	int saved_pac = arm64_pac
	table = cast(char*, malloc(symbol_data_size + 8))
	code = cast(char*, malloc(256))
	for i in range(symbol_data_size + 8): table[i] = 0
	for i in range(256): code[i] = 0
	code_size = 256
	codepos = 16
	code_offset = 0x10000000
	if (__word_size__ == 8): code_offset = (0x12345 << 16) << 16
	target_isa = 1
	arm64_pac = 0
	int first = addr_chain_link(0)
	int second = addr_chain_link(first)
	assert_equal(code_offset, be_addr_slot_read(first - code_offset))
	assert_equal(first, be_addr_slot_read(second - code_offset))
	int t = 8
	table[t + 1] = 'U'
	sym_set_value_at(t, second)
	int target = code_offset + 200
	if (__word_size__ == 8): target = code_offset - 16384 + 4088
	sym_define_global_at(t, target)
	assert_equal('D', table[t + 1])
	assert_equal(target, sym_value_at(t))
	assert_equal(target, be_addr_slot_read(first - code_offset))
	assert_equal(target, be_addr_slot_read(second - code_offset))
	free(code)
	free(table)
	table = saved_table
	code = saved_code
	code_size = saved_code_size
	codepos = saved_codepos
	code_offset = saved_offset
	target_isa = saved_isa
	arm64_pac = saved_pac

void test_symbol_dump_preserves_type_ids_and_full_addresses():
	char* saved_table = table
	int saved_pos = table_pos
	table = cast(char*, malloc(symbol_data_size + 8))
	for i in range(symbol_data_size + 8): table[i] = 0
	strcpy(table, c"display")
	int t = 7
	table_pos = t + symbol_data_size
	table[t + 1] = 'D'
	save_int(table + t + 6, 300)
	save_int(table + t + 10, 1234)
	int value = 0x12345678
	if (__word_size__ == 8): value = value | ((0x12345 << 16) << 16)
	sym_set_value_at(t, value)
	int reader
	int writer
	assert_equal(0, process_make_pipe(&reader, &writer))
	int saved_stderr = open(c"/dev/null", 0, 0)
	assert1(saved_stderr >= 0)
	assert_equal(saved_stderr, dup2(2, saved_stderr))
	assert_equal(2, dup2(writer, 2))
	print_symbol_table(0)
	int restored = dup2(saved_stderr, 2)
	close(saved_stderr)
	close(writer)
	assert_equal(2, restored)
	char[512] output
	int length = read(reader, &output[0], 511)
	close(reader)
	assert1(length > 0)
	output[length] = 0
	assert_contains(&output[0], c"display type(300) visibility(D)")
	assert_contains(&output[0], c"symtype(1234)")
	if (__word_size__ == 8): assert_contains(&output[0], c"address(0x0001234512345678)")
	else: assert_contains(&output[0], c"address(0x12345678)")
	free(table)
	table = saved_table
	table_pos = saved_pos

# wbuild: target=symbol_address_darwin_test tag=tests_darwin dep=symbol_address_test_darwin
# wbuild: step="bin/symbol_address_test_darwin" expect_stdout="All tests passed"
