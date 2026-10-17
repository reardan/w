# wbuild: target=safe_arm64_contract_runtime_test tag=tests_arm64 dep=safe_arm64_contract_test dep=wrun
# wbuild: step="env W_SAFE_ARM64_RUN=1 bin/safe_arm64_contract_test"
# Every contract is checked and compiled with and without --safe. Rejections
# must prevent publication of an executable, including with nonfatal warnings.
import lib.testing
import lib.process
import lib.file
import lib.env


int arm64_contract_case_number


void arm64_contract_result(process_result* result, char* diagnostic, int checking, char* path):
	assert1(result != 0)
	char* message = result.stderr_text
	if (checking): message = result.stdout_text
	if (diagnostic == 0):
		if (result.status):
			print(path)
			print(message)
		assert_equal(0, result.status)
	else:
		if ((result.status != 1) || (assert_has(message, diagnostic) == 0)):
			print(path)
			print(message)
		assert_equal(1, result.status)
		assert_contains(message, diagnostic)


void arm64_contract_case(char* source, char* diagnostic, int relaxed = 0, int seed = -1, char* target = 0):
	if (target == 0): target = c"arm64"
	arm64_contract_case_number = arm64_contract_case_number + 1
	char* number = itoa(arm64_contract_case_number)
	char* prefix = c"bin/arm64_contract_case32_"

	char* path = strjoin(prefix, number)
	free(number)
	if (seed >= 0):
		char* seed_number = itoa(seed)
		char* tagged = strjoin(path, c"_seed_")
		free(path)
		path = strjoin(tagged, seed_number)
		free(tagged)
		free(seed_number)
	char* full = strjoin(path, c".w")
	free(path)
	char* output = strjoin(full, c".out")
	assert1(file_write_text(full, source))
	for mode in range(2):
		unlink(output)
		char** checking = strv_new(7 + mode)
		strv_set(checking, 0, c"bin/wv2")
		strv_set(checking, 1, c"check")
		strv_set(checking, 2, c"--json")
		strv_set(checking, 3, c"--quiet")
		strv_set(checking, 4, c"--strict")
		if (relaxed): strv_set(checking, 4, c"--quiet")
		strv_set(checking, 5, target)
		strv_set(checking, 6, full)
		if (mode): strv_set(checking, 7, c"--safe")
		process_result* checked = process_run(checking[0], checking, 0, 0, 30000)
		arm64_contract_result(checked, diagnostic, 1, full)
		process_result_free(checked)
		free(cast(void*, checking))
		char** compiling = strv_new(8 + mode)
		strv_set(compiling, 0, c"bin/wv2")
		strv_set(compiling, 1, c"--quiet")
		strv_set(compiling, 2, c"--strict")
		if (relaxed): strv_set(compiling, 2, c"--quiet")
		strv_set(compiling, 3, target)
		strv_set(compiling, 4, c"--inline")
		strv_set(compiling, 5, full)
		strv_set(compiling, 6, c"-o")
		strv_set(compiling, 7, output)
		if (mode): strv_set(compiling, 8, c"--safe")
		process_result* compiled = process_run(compiling[0], compiling, 0, 0, 30000)
		arm64_contract_result(compiled, diagnostic, 0, full)
		process_result_free(compiled)
		free(cast(void*, compiling))
		if (diagnostic):
			assert1(open(output, 0, 0) < 0)
		else:
			char* binary = file_read_text(output)
			assert1(binary != 0)
			assert_equal(127, binary[0])
			assert_equal('E', binary[1])
			assert_equal('L', binary[2])
			assert_equal('F', binary[3])
			assert_equal(2, binary[4])
			assert_equal(1, binary[5])
			assert_equal(183, binary[18] & 255)
			assert_equal(0, binary[19])
			free(binary)
			if (env_get(c"W_SAFE_ARM64_RUN") != 0):
				char** run = strv_new(3)
				strv_set(run, 0, c"bin/wrun")
				strv_set(run, 1, c"arm64")
				strv_set(run, 2, output)
				process_result* executed = process_run(run[0], run, 0, 0, 30000)
				assert1(executed != 0)
				assert_equal(0, executed.status)
				process_result_free(executed)
				free(cast(void*, run))
		unlink(output)
	unlink(full)
	free(output)
	free(full)



void test_arm64_contract_0():
	arm64_contract_case(c"int main():\n\town int* value = new int\n\t*value = (1 << 40) + 7\n\treturn (*value >> 40) - 1\n", 0)
	arm64_contract_case(c"int main():\n\town int* value = new int\n\town int* moved = value\n\treturn *value\n", c"moved")
	arm64_contract_case(c"int main():\n\tint value = 3\n\tref int* view = &value\n\tvalue = 4\n\treturn *view\n", c"conflicting")
	arm64_contract_case(c"ref int* bad(ref int* input):\n\tint local = 3\n\treturn &local\nint main():\n\treturn 0\n", c"must borrow from")
	arm64_contract_case(c"ref[a] int* choose(ref[a] int* first, ref[b] int* second) where b > a:\n\treturn second\nint main():\n\tint x = 3\n\tint y = 7\n\tref int* value = choose(&x, &y)\n\treturn *value - 7\n", 0)
	arm64_contract_case(c"ref[a] T* choose[T](ref[a] T* first, ref[b] T* second) where b > a:\n\treturn second\nint main():\n\tint x = 3\n\tint y = 7\n\tref int* value = choose[int](&x, &y)\n\treturn *value - 7\n", 0)
	arm64_contract_case(c"refmut[a] int* bad(ref[a] int* value):\n\treturn value\nint main():\n\treturn 0\n", c"mutable borrowed parameter")

void test_arm64_contract_1():
	arm64_contract_case(c"own int* make(int value):\n\town int* result = new int\n\t*result = value\n\treturn result\ntype Make = fn[](int) -> own int*\nint main():\n\tMake* factory = make\n\town int* result = factory(7)\n\treturn *result - 7\n", 0)
	arm64_contract_case(c"ref[a] int* pass(ref[a] int* value):\n\treturn value\ntype Pass = fn[a](ref[a] int*) -> ref[a] int*\nint main():\n\tint x = 7\n\tPass* identity = pass\n\tref int* value = identity(&x)\n\treturn *value - 7\n", 0)
	arm64_contract_case(c"ref[a] int[] tail(ref[a] int[] values):\n\treturn values[1:]\nint main():\n\tint[3] values\n\tvalues[1] = 7\n\tref int[] view = tail(values)\n\treturn view[0] + view.length - 9\n", 0)
	arm64_contract_case(c"int main():\n\tint[3] values\n\tref int[] view = values\n\tvalues[0] = 7\n\treturn view[0]\n", c"conflicting")
	arm64_contract_case(c"struct View:\n\tref[data] int[] values\nref[a] View wrap(ref[a] int[] values):\n\treturn View(values)\nint main():\n\tint[3] values\n\tvalues[1] = 7\n\tref View wrapper = wrap(values)\n\tref int[] view = wrapper.values\n\treturn view[1] + view.length - 10\n", 0)
	arm64_contract_case(c"struct Pair:\n\town int* first\n\town int* second\nown Pair* make():\n\treturn new Pair(new int, new int)\nint main():\n\town Pair* value = make()\n\tvalue = make()\n\trefmut int* first = value.first\n\t*first = 7\n\treturn *first - 7\n", 0)
	arm64_contract_case(c"int maybe(optref int* value):\n\tif (value): return *value\n\treturn 0\nint main():\n\tint x = 7\n\treturn maybe(&x) + maybe(0) - 7\n", 0)

void test_arm64_contract_2():
	arm64_contract_case(c"int bad(optref int* value):\n\treturn *value\nint main():\n\treturn 0\n", c"presence check")
	arm64_contract_case(c"int bump(refmut int* value):\n\t*value += 1\n\treturn 0\nint example(refmut int* value):\n\tdefer (bump(value))\n\treturn *value\nint main():\n\tint x = 7\n\tint result = example(&x)\n\treturn result + x - 15\n", 0)
	arm64_contract_case(c"int main():\n\tint total = 0\n\tfor i in range(5):\n\t\town int* value = new int\n\t\t*value = i\n\t\tif (i == 1): continue\n\t\tif (i == 4): break\n\t\ttotal += *value\n\treturn total - 5\n", 0)
	arm64_contract_case(c"import lib.safe_buffer\nint main():\n\town WIntBuffer* buffer = int_buffer_new()\n\tint_buffer_push(buffer, 7)\n\tref int[] view = int_buffer_view(buffer)\n\treturn view[0] + view.length - 8\n", 0)
	arm64_contract_case(c"import lib.safe_buffer\nint main():\n\town WIntBuffer* buffer = int_buffer_new()\n\tint_buffer_push(buffer, 7)\n\tref int[] view = int_buffer_view(buffer)\n\tint_buffer_push(buffer, 8)\n\treturn view[0]\n", c"conflicting")
	arm64_contract_case(c"int main():\n\town int* value = new int\n\tint address = cast(int, value)\n\treturn address\n", c"safe:")
	arm64_contract_case(c"int main():\n\toptref int* saved = 0\n\tif (1):\n\t\town int* value = new int\n\t\tsaved = value\n\tif (saved): return *saved\n\treturn 0\n", c"moved")

void test_arm64_contract_3():
	arm64_contract_case(c"int main():\n\town int* value = new int\n\treturn getpid()\n", c"runtime call has no audited ownership contract")
	arm64_contract_case(c"int main():\n\town int* value = new int\n\treturn mmap(0, 4096, 3, 34)\n", c"runtime call has no audited ownership contract")

void test_arm64_contract_unsupported_targets():
	arm64_contract_case(c"int main():\n\town int* value = new int\n\treturn 0\n", c"only Linux x86, x64 and arm64", 0, -1, c"arm64_darwin")
	arm64_contract_case(c"int main():\n\town int* value = new int\n\treturn 0\n", c"only Linux x86, x64 and arm64", 0, -1, c"arm64_android")
	arm64_contract_case(c"int main():\n\town int* value = new int\n\treturn 0\n", c"only Linux x86, x64 and arm64", 0, -1, c"arm64_ios")
	arm64_contract_case(c"int main():\n\town int* value = new int\n\treturn 0\n", c"only Linux x86, x64 and arm64", 0, -1, c"arm64_ios_sim")
	arm64_contract_case(c"int main():\n\town int* value = new int\n\treturn 0\n", c"only Linux x86, x64 and arm64", 0, -1, c"wasm")

void test_arm64_runtime_pin_rejects_changed_implementation():
	char* root = c"bin/safe_arm64_pin"
	mkdir(root, 493)
	mkdir(c"bin/safe_arm64_pin/lib", 493)
	mkdir(c"bin/safe_arm64_pin/lib/__arch__", 493)
	mkdir(c"bin/safe_arm64_pin/lib/__arch__/arm64", 493)
	char* path = c"bin/safe_arm64_pin/lib/__arch__/arm64/syscalls.w"
	char* original = file_read_text(c"lib/__arch__/arm64/syscalls.w")
	assert1(original != 0)
	char* modified = strjoin(original, c"\n# changed runtime contract\n")
	assert1(file_write_text(path, modified))
	char* source = c"bin/safe_arm64_pin_input.w"
	assert1(file_write_text(source, c"int main():\n\town int* value = new int\n\treturn 0\n"))
	char* output = c"bin/safe_arm64_pin_output"
	for mode in range(2):
		unlink(output)
		char** checking = strv_new(8 + mode)
		strv_set(checking, 0, c"bin/wv2")
		strv_set(checking, 1, c"check")
		strv_set(checking, 2, c"--json")
		strv_set(checking, 3, c"--strict")
		strv_set(checking, 4, c"arm64")
		strv_set(checking, 5, c"--import-root")
		strv_set(checking, 6, root)
		strv_set(checking, 7, source)
		if (mode): strv_set(checking, 8, c"--safe")
		process_result* result = process_run(checking[0], checking, 0, 0, 30000)
		arm64_contract_result(result, c"runtime implementation differs", 1, source)
		process_result_free(result)
		free(cast(void*, checking))
		char** compiling = strv_new(8 + mode)
		strv_set(compiling, 0, c"bin/wv2")
		strv_set(compiling, 1, c"arm64")
		strv_set(compiling, 2, c"--strict")
		strv_set(compiling, 3, c"--import-root")
		strv_set(compiling, 4, root)
		strv_set(compiling, 5, source)
		strv_set(compiling, 6, c"-o")
		strv_set(compiling, 7, output)
		if (mode): strv_set(compiling, 8, c"--safe")
		result = process_run(compiling[0], compiling, 0, 0, 30000)
		arm64_contract_result(result, c"runtime implementation differs", 0, source)
		process_result_free(result)
		free(cast(void*, compiling))
		assert1(open(output, 0, 0) < 0)
	unlink(path)
	unlink(source)
	free(original)
	free(modified)


void test_arm64_context_runtime_contract():
	arm64_contract_case(c"import lib.lib\nint main():\n\town int* value = new int\n\treturn *value\n", 0)
