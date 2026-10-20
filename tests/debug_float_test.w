# wbuild: binary=debug_float_test tag=tests dep=wdbg dep=wdbg_x64 data=tests/debug_float_fixture.w data=tests/debug_float64_fixture.w data=tests/debug_bfloat_fixture.w
# wbuild: step="bin/debug_float_test"
import lib.testing
import lib.process
import lib.str


process_result* debug_float_run(char* binary, char* source, char* commands):
	char** args = strv_new(2)
	strv_set(args, 0, binary)
	strv_set(args, 1, source)
	process_result* result = process_run(binary, args, 0, commands, 30000)
	free(cast(void*, args))
	assert_equal(0, result.status)
	assert_contains(result.stdout_text, c"debuggee main returned 0")
	return result


void test_debug_float_values():
	for host in range(2):
		char* binary = c"bin/wdbg"
		if (host): binary = c"bin/wdbg64"
		process_result* result = debug_float_run(binary, c"tests/debug_float_fixture.w", c"i locals\np debug_float_global\np pair\ninspect half\ninspect single\ninspect negative_zero\ninspect subnormal\ninspect infinity\ninspect nan\ninspect pointer.*\ninspect aliased\ninspect negative_subnormal\ninspect pair.half\ninspect pair.single\ncontinue\n")
		char* output = result.stdout_text
		assert_contains(output, c"single = -2.5 (")
		assert_contains(output, c"half = 1.5 (")
		assert_contains(output, c"aliased = -2.5 (")
		assert_contains(output, c"largest = 65504.0 (")
		assert_contains(output, c"negative_subnormal = -5.9604645e-08 (")
		assert_contains(output, c"debug_float_global = 1.25 (")
		assert_contains(output, c"pair = {half = 1.5 (")
		assert_contains(output, c"negative_zero = -0.0 (")
		assert_contains(output, c"subnormal = 5.9604645e-08 (")
		assert_contains(output, c"infinity = inf (")
		assert_contains(output, c"nan = nan (")
		assert_contains(output, c"\"value\":\"1.5\",\"bits\":\"0x3e00\"")
		assert_contains(output, c"\"value\":\"-2.5\",\"bits\":\"0xc0200000\"")
		assert_contains(output, c"\"value\":\"-0.0\",\"bits\":\"0x")
		assert_contains(output, c"\"value\":\"5.9604645e-08\",\"bits\":\"0x")
		assert_contains(output, c"\"value\":\"inf\",\"bits\":\"0x")
		assert_contains(output, c"\"value\":\"nan\",\"bits\":\"0x")
		assert_contains(output, c"\"value\":\"-2.5\",\"bits\":\"0xc100\"")
		assert_contains(output, c"\"value\":\"-5.9604645e-08\",\"bits\":\"0x8001\"")
		assert_contains(output, c"\"path\":\"pair.half\",\"name\":\"pair.half\",\"type\":\"float16\"")
		assert_contains(output, c"\"path\":\"pair.single\",\"name\":\"pair.single\",\"type\":\"float32\"")
		process_result_free(result)


void test_debug_bfloat_values():
	for host in range(2):
		char* binary = c"bin/wdbg"
		if (host): binary = c"bin/wdbg64"
		process_result* result = debug_float_run(binary, c"tests/debug_bfloat_fixture.w", c"i locals\np pair\ninspect brain\ninspect aliased\ninspect subnormal\ninspect nan\ncontinue\n")
		char* output = result.stdout_text
		assert_contains(output, c"brain = 1.5 (0x3fc0)")
		assert_contains(output, c"aliased = -2.5 (0xc020)")
		assert_contains(output, c"negative_zero = -0.0 (0x8000)")
		assert_contains(output, c"subnormal = 9.1835e-41 (0x0001)")
		assert_contains(output, c"infinity = inf (0x7f80)")
		assert_contains(output, c"nan = nan (0x7fc1)")
		assert_contains(output, c"pair = {value = 1.5 (0x3fc0)")
		assert_contains(output, c"\"value\":\"1.5\",\"bits\":\"0x3fc0\"")
		assert_contains(output, c"\"value\":\"-2.5\",\"bits\":\"0xc020\"")
		process_result_free(result)


void test_debug_float64_values():
	process_result* result = debug_float_run(c"bin/wdbg64", c"tests/debug_float64_fixture.w", c"i locals\np pair\ninspect wide\ninspect negative_zero\ninspect subnormal\ninspect infinity\ninspect nan\ncontinue\n")
	char* output = result.stdout_text
	assert_contains(output, c"wide = 1.2345678901234567 (")
	assert_contains(output, c"pair = {value = 1.2345678901234567 (")
	assert_contains(output, c"negative_zero = -0.0 (")
	assert_contains(output, c"subnormal = 5e-324 (")
	assert_contains(output, c"infinity = inf (")
	assert_contains(output, c"nan = nan (")
	assert_contains(output, c"\"value\":\"1.2345678901234567\",\"bits\":\"0x")
	assert_contains(output, c"\"value\":\"5e-324\",\"bits\":\"0x")
	process_result_free(result)
