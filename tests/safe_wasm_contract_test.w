# wbuild: target=safe_wasm_contract_runtime_test tag=tests_wasm dep=safe_wasm_contract_test dep=wrun
# wbuild: step="env W_SAFE_WASM_RUN=1 bin/safe_wasm_contract_test"
# Every contract is checked and compiled for wasm with and without --safe,
# and checked for the default x86 target: wasm must report the same first
# diagnostic as x86. Rejections must prevent publication of a module,
# including with nonfatal warnings. tests_wasm reruns the matrix and
# executes each accepted module under bin/wrun wasm.
import lib.testing
import lib.process
import lib.file
import lib.env


int wasm_contract_case_number


void wasm_contract_result(process_result* result, char* diagnostic, int checking, char* path):
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


# The first "message" value of NDJSON diagnostics, or "" when clean.
char* wasm_contract_first_message(char* json):
	char* key = c"\"message\": \""
	int key_length = strlen(key)
	int n = strlen(json)
	int i = 0
	while (i + key_length <= n):
		int matches = 1
		for j in range(key_length):
			if (json[i + j] != key[j]): matches = 0
		if (matches):
			int start = i + key_length
			int end = start
			while ((end < n) && (json[end] != '"')):
				if ((json[end] == '\\') && (end + 1 < n)): end = end + 1
				end = end + 1
			char* copy = cast(char*, malloc(end - start + 1))
			for k in range(end - start): copy[k] = json[start + k]
			copy[end - start] = 0
			return copy
		i = i + 1
	return strclone(c"")


# A null target selects the default (x86) target, which has no selector.
process_result* wasm_contract_check(char* target, char* path, int relaxed, int safe):
	char** checking = strv_new(6 + safe)
	strv_set(checking, 0, c"bin/wv2")
	strv_set(checking, 1, c"check")
	strv_set(checking, 2, c"--json")
	strv_set(checking, 3, c"--strict")
	if (relaxed): strv_set(checking, 3, c"--quiet")
	strv_set(checking, 4, c"--quiet")
	if (target): strv_set(checking, 4, target)
	strv_set(checking, 5, path)
	if (safe): strv_set(checking, 6, c"--safe")
	process_result* checked = process_run(checking[0], checking, 0, 0, 30000)
	free(cast(void*, checking))
	return checked


void wasm_contract_case(char* source, char* diagnostic, int relaxed = 0, char* target = 0, int parity = 1):
	if (target == 0): target = c"wasm"
	wasm_contract_case_number = wasm_contract_case_number + 1
	char* number = itoa(wasm_contract_case_number)
	char* path = strjoin(c"bin/wasm_contract_case_", number)
	free(number)
	char* full = strjoin(path, c".w")
	free(path)
	char* output = strjoin(full, c".wasm")
	assert1(file_write_text(full, source))
	for mode in range(2):
		unlink(output)
		process_result* checked = wasm_contract_check(target, full, relaxed, mode)
		wasm_contract_result(checked, diagnostic, 1, full)
		if (parity && (strcmp(target, c"wasm") == 0)):
			# Diagnostic parity: the default target reports the same
			# first message for the same program and flags.
			process_result* native = wasm_contract_check(0, full, relaxed, mode)
			assert1(native != 0)
			assert_equal(checked.status, native.status)
			char* expected = wasm_contract_first_message(native.stdout_text)
			char* got = wasm_contract_first_message(checked.stdout_text)
			if (strcmp(expected, got) != 0):
				print(full)
				print(native.stdout_text)
				print(checked.stdout_text)
			assert_strings_equal(expected, got)
			free(expected)
			free(got)
			process_result_free(native)
		process_result_free(checked)
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
		wasm_contract_result(compiled, diagnostic, 0, full)
		process_result_free(compiled)
		free(cast(void*, compiling))
		if (diagnostic):
			assert1(open(output, 0, 0) < 0)
		else:
			# A wasm32 module: "\0asm", binary format version 1.
			char* binary = file_read_text(output)
			assert1(binary != 0)
			assert_equal(0, binary[0])
			assert_equal('a', binary[1])
			assert_equal('s', binary[2])
			assert_equal('m', binary[3])
			assert_equal(1, binary[4])
			assert_equal(0, binary[5])
			assert_equal(0, binary[6])
			assert_equal(0, binary[7])
			free(binary)
			if (env_get(c"W_SAFE_WASM_RUN") != 0):
				char** run = strv_new(3)
				strv_set(run, 0, c"bin/wrun")
				strv_set(run, 1, c"wasm")
				strv_set(run, 2, output)
				process_result* executed = process_run(run[0], run, 0, 0, 30000)
				assert1(executed != 0)
				if (executed.status):
					print(full)
					print(executed.stderr_text)
				assert_equal(0, executed.status)
				process_result_free(executed)
				free(cast(void*, run))
		unlink(output)
	unlink(full)
	free(output)
	free(full)


void test_wasm_contract_0():
	wasm_contract_case(c"int main():\n\town int* value = new int\n\t*value = (1 << 20) + 7\n\treturn (*value >> 20) - 1\n", 0)
	wasm_contract_case(c"int main():\n\town int* value = new int\n\town int* moved = value\n\treturn *value\n", c"moved")
	wasm_contract_case(c"int main():\n\tint value = 3\n\tref int* view = &value\n\tvalue = 4\n\treturn *view\n", c"conflicting")
	wasm_contract_case(c"ref int* bad(ref int* input):\n\tint local = 3\n\treturn &local\nint main():\n\treturn 0\n", c"must borrow from")
	wasm_contract_case(c"ref[a] int* choose(ref[a] int* first, ref[b] int* second) where b > a:\n\treturn second\nint main():\n\tint x = 3\n\tint y = 7\n\tref int* value = choose(&x, &y)\n\treturn *value - 7\n", 0)
	wasm_contract_case(c"ref[a] T* choose[T](ref[a] T* first, ref[b] T* second) where b > a:\n\treturn second\nint main():\n\tint x = 3\n\tint y = 7\n\tref int* value = choose[int](&x, &y)\n\treturn *value - 7\n", 0)
	wasm_contract_case(c"refmut[a] int* bad(ref[a] int* value):\n\treturn value\nint main():\n\treturn 0\n", c"mutable borrowed parameter")

void test_wasm_contract_1():
	wasm_contract_case(c"own int* make(int value):\n\town int* result = new int\n\t*result = value\n\treturn result\ntype Make = fn[](int) -> own int*\nint main():\n\tMake* factory = make\n\town int* result = factory(7)\n\treturn *result - 7\n", 0)
	wasm_contract_case(c"ref[a] int* pass(ref[a] int* value):\n\treturn value\ntype Pass = fn[a](ref[a] int*) -> ref[a] int*\nint main():\n\tint x = 7\n\tPass* identity = pass\n\tref int* value = identity(&x)\n\treturn *value - 7\n", 0)
	wasm_contract_case(c"ref[a] int[] tail(ref[a] int[] values):\n\treturn values[1:]\nint main():\n\tint[3] values\n\tvalues[1] = 7\n\tref int[] view = tail(values)\n\treturn view[0] + view.length - 9\n", 0)
	wasm_contract_case(c"int main():\n\tint[3] values\n\tref int[] view = values\n\tvalues[0] = 7\n\treturn view[0]\n", c"conflicting")
	wasm_contract_case(c"struct View:\n\tref[data] int[] values\nref[a] View wrap(ref[a] int[] values):\n\treturn View(values)\nint main():\n\tint[3] values\n\tvalues[1] = 7\n\tref View wrapper = wrap(values)\n\tref int[] view = wrapper.values\n\treturn view[1] + view.length - 10\n", 0)
	wasm_contract_case(c"struct Pair:\n\town int* first\n\town int* second\nown Pair* make():\n\treturn new Pair(new int, new int)\nint main():\n\town Pair* value = make()\n\tvalue = make()\n\trefmut int* first = value.first\n\t*first = 7\n\treturn *first - 7\n", 0)
	wasm_contract_case(c"int maybe(optref int* value):\n\tif (value): return *value\n\treturn 0\nint main():\n\tint x = 7\n\treturn maybe(&x) + maybe(0) - 7\n", 0)

void test_wasm_contract_2():
	wasm_contract_case(c"int bad(optref int* value):\n\treturn *value\nint main():\n\treturn 0\n", c"presence check")
	wasm_contract_case(c"int bump(refmut int* value):\n\t*value += 1\n\treturn 0\nint example(refmut int* value):\n\tdefer (bump(value))\n\treturn *value\nint main():\n\tint x = 7\n\tint result = example(&x)\n\treturn result + x - 15\n", 0)
	wasm_contract_case(c"int main():\n\tint total = 0\n\tfor i in range(5):\n\t\town int* value = new int\n\t\t*value = i\n\t\tif (i == 1): continue\n\t\tif (i == 4): break\n\t\ttotal += *value\n\treturn total - 5\n", 0)
	wasm_contract_case(c"import lib.safe_buffer\nint main():\n\town WIntBuffer* buffer = int_buffer_new()\n\tint_buffer_push(buffer, 7)\n\tref int[] view = int_buffer_view(buffer)\n\treturn view[0] + view.length - 8\n", 0)
	wasm_contract_case(c"import lib.safe_buffer\nint main():\n\town WIntBuffer* buffer = int_buffer_new()\n\tint_buffer_push(buffer, 7)\n\tref int[] view = int_buffer_view(buffer)\n\tint_buffer_push(buffer, 8)\n\treturn view[0]\n", c"conflicting")
	wasm_contract_case(c"int main():\n\town int* value = new int\n\tint address = cast(int, value)\n\treturn address\n", c"safe:")
	wasm_contract_case(c"int main():\n\toptref int* saved = 0\n\tif (1):\n\t\town int* value = new int\n\t\tsaved = value\n\tif (saved): return *saved\n\treturn 0\n", c"moved")

void test_wasm_contract_3():
	# wasm32 words: references and slice descriptor halves are 4 bytes.
	wasm_contract_case(c"int main():\n\town int* value = new int\n\t*value = __word_size__\n\treturn *value - 4\n", 0)
	wasm_contract_case(c"import lib.safe_buffer\nint main():\n\town WByteArena* arena = byte_arena_new()\n\tbyte[2] data\n\tdata[1] = cast(byte, 9)\n\tref byte[] copy = byte_arena_copy(arena, data)\n\tif copy[1] != cast(byte, 9): return 1\n\treturn copy.length - 2\n", 0)
	wasm_contract_case(c"import lib.safe_buffer\nint main():\n\town WByteArena* arena = byte_arena_new()\n\tbyte[2] data\n\tref byte[] copy = byte_arena_copy(arena, data)\n\tbyte_arena_reset(arena)\n\treturn copy.length\n", c"conflicting")

void test_wasm_contract_raw_runtime_calls():
	wasm_contract_case(c"int main():\n\town int* value = new int\n\treturn getpid()\n", c"runtime call has no audited ownership contract")
	wasm_contract_case(c"int main():\n\town int* value = new int\n\treturn mmap(0, 4096, 3, 34)\n", c"runtime call has no audited ownership contract")
	# The WASI import stubs stay outside the checked call allowlist; the
	# x86 parity half sees no such symbol, so these run unpaired.
	wasm_contract_case(c"int main():\n\town int* value = new int\n\treturn wasi_memory_grow(1)\n", c"runtime call has no audited ownership contract", 0, 0, 0)
	wasm_contract_case(c"int main():\n\town int* value = new int\n\treturn wasi_fd_write(1, 0, 0, 0)\n", c"runtime call has no audited ownership contract", 0, 0, 0)

void test_wasm_contract_unsupported_targets():
	wasm_contract_case(c"int main():\n\town int* value = new int\n\treturn 0\n", c"only Linux x86, x64 and arm64", 0, c"arm64_android")
	wasm_contract_case(c"int main():\n\town int* value = new int\n\treturn 0\n", c"only Linux x86, x64 and arm64", 0, c"arm64_ios")
	wasm_contract_case(c"int main():\n\town int* value = new int\n\treturn 0\n", c"only Linux x86, x64 and arm64", 0, c"arm64_ios_sim")

void test_wasm_runtime_pin_rejects_changed_implementation():
	char* root = c"bin/safe_wasm_pin"
	mkdir(root, 493)
	mkdir(c"bin/safe_wasm_pin/lib", 493)
	mkdir(c"bin/safe_wasm_pin/lib/__arch__", 493)
	mkdir(c"bin/safe_wasm_pin/lib/__arch__/wasm", 493)
	char* path = c"bin/safe_wasm_pin/lib/__arch__/wasm/syscalls.w"
	char* original = file_read_text(c"lib/__arch__/wasm/syscalls.w")
	assert1(original != 0)
	char* modified = strjoin(original, c"\n# changed runtime contract\n")
	assert1(file_write_text(path, modified))
	char* source = c"bin/safe_wasm_pin_input.w"
	assert1(file_write_text(source, c"int main():\n\town int* value = new int\n\treturn 0\n"))
	char* output = c"bin/safe_wasm_pin_output.wasm"
	for mode in range(2):
		unlink(output)
		char** checking = strv_new(8 + mode)
		strv_set(checking, 0, c"bin/wv2")
		strv_set(checking, 1, c"check")
		strv_set(checking, 2, c"--json")
		strv_set(checking, 3, c"--strict")
		strv_set(checking, 4, c"wasm")
		strv_set(checking, 5, c"--import-root")
		strv_set(checking, 6, root)
		strv_set(checking, 7, source)
		if (mode): strv_set(checking, 8, c"--safe")
		process_result* result = process_run(checking[0], checking, 0, 0, 30000)
		wasm_contract_result(result, c"runtime implementation differs", 1, source)
		process_result_free(result)
		free(cast(void*, checking))
		char** compiling = strv_new(8 + mode)
		strv_set(compiling, 0, c"bin/wv2")
		strv_set(compiling, 1, c"wasm")
		strv_set(compiling, 2, c"--strict")
		strv_set(compiling, 3, c"--import-root")
		strv_set(compiling, 4, root)
		strv_set(compiling, 5, source)
		strv_set(compiling, 6, c"-o")
		strv_set(compiling, 7, output)
		if (mode): strv_set(compiling, 8, c"--safe")
		result = process_run(compiling[0], compiling, 0, 0, 30000)
		wasm_contract_result(result, c"runtime implementation differs", 0, source)
		process_result_free(result)
		free(cast(void*, compiling))
		assert1(open(output, 0, 0) < 0)
	unlink(path)
	unlink(source)
	free(original)
	free(modified)


void test_wasm_context_runtime_contract():
	wasm_contract_case(c"import lib.lib\nint main():\n\town int* value = new int\n\treturn *value\n", 0)
