# wbuild: x64
# wbuild: deps=lib/safe_buffer.w
# Every contract is checked and compiled with and without --safe. Rejections
# must prevent publication of an executable, including with nonfatal warnings.
import lib.testing
import lib.process
import lib.file


int buffer_case_number


void buffer_result(process_result* result, char* diagnostic, int checking, char* path):
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


void buffer_case(char* source, char* diagnostic, int relaxed = 0, char* runtime_diagnostic = 0):
	buffer_case_number = buffer_case_number + 1
	char* number = itoa(buffer_case_number)
	char* prefix = c"bin/buffer_case32_"
	if (__word_size__ == 8): prefix = c"bin/buffer_case64_"
	char* path = strjoin(prefix, number)
	free(number)
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
		strv_set(checking, 5, c"--quiet")
		if (__word_size__ == 8): strv_set(checking, 5, c"x64")
		strv_set(checking, 6, full)
		if (mode): strv_set(checking, 7, c"--safe")
		process_result* checked = process_run(checking[0], checking, 0, 0, 30000)
		buffer_result(checked, diagnostic, 1, full)
		process_result_free(checked)
		free(cast(void*, checking))
		char** compiling = strv_new(8 + mode)
		strv_set(compiling, 0, c"bin/wv2")
		strv_set(compiling, 1, c"--quiet")
		strv_set(compiling, 2, c"--strict")
		if (relaxed): strv_set(compiling, 2, c"--quiet")
		strv_set(compiling, 3, c"--quiet")
		if (__word_size__ == 8): strv_set(compiling, 3, c"x64")
		strv_set(compiling, 4, c"--inline")
		strv_set(compiling, 5, full)
		strv_set(compiling, 6, c"-o")
		strv_set(compiling, 7, output)
		if (mode): strv_set(compiling, 8, c"--safe")
		process_result* compiled = process_run(compiling[0], compiling, 0, 0, 30000)
		buffer_result(compiled, diagnostic, 0, full)
		process_result_free(compiled)
		free(cast(void*, compiling))
		if (diagnostic):
			assert1(open(output, 0, 0) < 0)
		else:
			char** run = strv_new(1)
			strv_set(run, 0, output)
			process_result* executed = process_run(output, run, 0, 0, 30000)
			assert1(executed != 0)
			if (runtime_diagnostic):
				assert_equal(1, executed.status)
				assert_contains(executed.stderr_text, runtime_diagnostic)
			else: assert_equal(0, executed.status)
			process_result_free(executed)
			free(cast(void*, run))
		unlink(output)
	unlink(full)
	free(output)
	free(full)


void test_checked_buffer_public_operations():
	buffer_case(c"import lib.safe_buffer\nint main():\n\town WIntBuffer* b = int_buffer_new()\n\treturn int_buffer_length(b)\n", 0)
	buffer_case(c"import lib.safe_buffer\nint main():\n\town WIntBuffer* b = int_buffer_new()\n\tref int[] empty = int_buffer_view(b)\n\treturn empty.length\n", 0)
	buffer_case(c"import lib.safe_buffer\nint main():\n\town WIntBuffer* b = int_buffer_new()\n\tint i = 0\n\twhile i < 65:\n\t\tint_buffer_push(b, i)\n\t\ti = i + 1\n\tint total = 0\n\ti = 0\n\twhile i < int_buffer_length(b):\n\t\ttotal = total + int_buffer_get(b, i)\n\t\ti = i + 1\n\treturn total - 2080\n", 0)
	buffer_case(c"import lib.safe_buffer\nint main():\n\town WIntBuffer* b = int_buffer_new()\n\tint_buffer_push(b, 7)\n\tint_buffer_set(b, 0, 9)\n\treturn int_buffer_get(b, 0) + int_buffer_length(b) - 10\n", 0)
	buffer_case(c"import lib.safe_buffer\nint main():\n\town WIntBuffer* b = int_buffer_new()\n\tint_buffer_push(b, 7)\n\tint value = int_buffer_pop(b)\n\treturn value + int_buffer_length(b) - 7\n", 0)
	buffer_case(c"import lib.safe_buffer\nint main():\n\town WIntBuffer* b = int_buffer_new()\n\tint_buffer_push(b, 7)\n\tint_buffer_clear(b)\n\tint_buffer_push(b, 9)\n\treturn int_buffer_get(b, 0) + int_buffer_length(b) - 10\n", 0)
	buffer_case(c"import lib.safe_buffer\nint main():\n\town WIntBuffer* b = int_buffer_new()\n\tint_buffer_push(b, 7)\n\tref int[] view = int_buffer_view(b)\n\tint old = view[0]\n\tint_buffer_push(b, 9)\n\treturn old + int_buffer_get(b, 1) - 16\n", 0)
	buffer_case(c"import lib.safe_buffer\nint main():\n\town WIntBuffer* b = int_buffer_new()\n\tint_buffer_push(b, 7)\n\town WIntBuffer* moved = b\n\treturn int_buffer_get(moved, 0) - 7\n", 0)
	buffer_case(c"import lib.safe_buffer\nown WIntBuffer* make():\n\town WIntBuffer* b = int_buffer_new()\n\tint_buffer_push(b, 7)\n\treturn b\nint consume(own WIntBuffer* b):\n\treturn int_buffer_get(b, 0)\nint main():\n\treturn consume(make()) - 7\n", 0)
	buffer_case(c"import lib.safe_buffer\nref[a] int[] view(ref[a] WIntBuffer* b):\n\treturn int_buffer_view(b)\nint main():\n\town WIntBuffer* b = int_buffer_new()\n\tint_buffer_push(b, 7)\n\tref int[] values = view(b)\n\treturn values[0] + values.length - 8\n", 0)
	buffer_case(c"import lib.safe_buffer\nint main():\n\town WIntBuffer* b = int_buffer_new()\n\tint_buffer_push(b, 7)\n\tint_buffer_push(b, 9)\n\tref int[] values = int_buffer_view(b)[1:]\n\treturn values[0] + values.length - 10\n", 0)


void test_checked_buffer_view_invalidation():
	buffer_case(c"import lib.safe_buffer\nint main():\n\town WIntBuffer* b = int_buffer_new()\n\tint_buffer_push(b, 7)\n\tref int[] view = int_buffer_view(b)\n\tint_buffer_push(b, 9)\n\treturn view[0]\n", c"conflicting")
	buffer_case(c"import lib.safe_buffer\nint main():\n\town WIntBuffer* b = int_buffer_new()\n\tint_buffer_push(b, 7)\n\tref int[] view = int_buffer_view(b)\n\tint_buffer_set(b, 0, 9)\n\treturn view[0]\n", c"conflicting")
	buffer_case(c"import lib.safe_buffer\nint main():\n\town WIntBuffer* b = int_buffer_new()\n\tint_buffer_push(b, 7)\n\tref int[] view = int_buffer_view(b)\n\tint_buffer_pop(b)\n\treturn view[0]\n", c"conflicting")
	buffer_case(c"import lib.safe_buffer\nint main():\n\town WIntBuffer* b = int_buffer_new()\n\tint_buffer_push(b, 7)\n\tref int[] view = int_buffer_view(b)\n\tint_buffer_clear(b)\n\treturn view[0]\n", c"conflicting")
	buffer_case(c"import lib.safe_buffer\nint main():\n\town WIntBuffer* b = int_buffer_new()\n\tint_buffer_push(b, 7)\n\tref int[] view = int_buffer_view(b)\n\tb = int_buffer_new()\n\treturn view[0]\n", c"conflicting")
	buffer_case(c"import lib.safe_buffer\nint main():\n\town WIntBuffer* b = int_buffer_new()\n\tint_buffer_push(b, 7)\n\tref int[] view = int_buffer_view(b)\n\town WIntBuffer* moved = b\n\treturn view[0]\n", c"moved value")
	buffer_case(c"import lib.safe_buffer\nint main():\n\town WIntBuffer* b = int_buffer_new()\n\tref int[] empty = int_buffer_view(b)\n\tint_buffer_push(b, 9)\n\treturn empty.length\n", c"conflicting")
	buffer_case(c"import lib.safe_buffer\nint main():\n\town WIntBuffer* b = int_buffer_new()\n\tint_buffer_push(b, 7)\n\tref int[] view = int_buffer_view(b)\n\tview[0] = 9\n\treturn 0\n", c"shared reference")
	buffer_case(c"import lib.safe_buffer\nref[a] int[] choose(ref[a] WIntBuffer* a, ref[a] WIntBuffer* b, int first):\n\tif first: return int_buffer_view(a)\n\treturn int_buffer_view(b)\nint main():\n\town WIntBuffer* a = int_buffer_new()\n\town WIntBuffer* b = int_buffer_new()\n\tint_buffer_push(a, 7)\n\tint_buffer_push(b, 9)\n\tref int[] values = choose(a, b, 1)\n\tint_buffer_clear(b)\n\treturn values[0]\n", c"conflicting")


void test_checked_byte_strings():
	buffer_case(c"import lib.safe_buffer\nint main():\n\town WByteString* s = byte_string_new()\n\tref byte[] empty = byte_string_view(s)\n\treturn empty.length + byte_string_length(s)\n", 0)
	buffer_case(c"import lib.safe_buffer\nint main():\n\tbyte[3] values\n\tvalues[0] = cast(byte, 65)\n\tvalues[1] = cast(byte, 0)\n\tvalues[2] = cast(byte, 255)\n\town WByteString* s = byte_string_from(values)\n\tref byte[] view = byte_string_view(s)\n\treturn cast(int, view[0]) + cast(int, view[1]) + cast(int, view[2]) + view.length - 323\n", 0)
	buffer_case(c"import lib.safe_buffer\nint main():\n\town WByteString* s = byte_string_new()\n\tbyte_string_push(s, cast(byte, 7))\n\tbyte_string_set(s, 0, cast(byte, 255))\n\tint value = cast(int, byte_string_pop(s))\n\treturn value + byte_string_length(s) - 255\n", 0)
	buffer_case(c"import lib.safe_buffer\nint main():\n\town WByteString* s = byte_string_new()\n\tbyte_string_push(s, cast(byte, 7))\n\tbyte_string_clear(s)\n\tbyte_string_push(s, cast(byte, 9))\n\treturn cast(int, byte_string_get(s, 0)) + byte_string_length(s) - 10\n", 0)
	buffer_case(c"import lib.safe_buffer\nint main():\n\town WByteString* src = byte_string_new()\n\tbyte_string_push(src, cast(byte, 65))\n\tbyte_string_push(src, cast(byte, 0))\n\town WByteString* dst = byte_string_new()\n\tbyte_string_append(dst, byte_string_view(src))\n\tbyte_string_append(dst, byte_string_view(src))\n\treturn byte_string_length(dst) + cast(int, byte_string_get(dst, 2)) - 69\n", 0)
	buffer_case(c"import lib.safe_buffer\nint main():\n\tbyte[2] values\n\tvalues[0] = cast(byte, 65)\n\tvalues[1] = cast(byte, 0)\n\tref byte[] all = values\n\town WByteString* s = byte_string_from(all[0:0])\n\tbyte_string_append(s, all[0:0])\n\treturn byte_string_length(s)\n", 0)
	buffer_case(c"import lib.safe_buffer\nint main():\n\town WByteString* s = byte_string_new()\n\tbyte_string_push(s, cast(byte, 7))\n\town WByteString* copy = byte_string_from(byte_string_view(s))\n\tbyte_string_clear(s)\n\treturn cast(int, byte_string_get(copy, 0)) - 7\n", 0)
	buffer_case(c"import lib.safe_buffer\nint main():\n\town WByteString* s = byte_string_new()\n\tbyte_string_push(s, cast(byte, 7))\n\tbyte_string_append(s, byte_string_view(s))\n\treturn 0\n", c"conflicting")
	buffer_case(c"import lib.safe_buffer\nint reverse(ref byte[] view, refmut WByteString* s):\n\tbyte_string_append(s, view)\n\treturn 0\nint main():\n\town WByteString* s = byte_string_new()\n\tbyte_string_push(s, cast(byte, 7))\n\treturn reverse(byte_string_view(s), s)\n", c"conflicting")
	buffer_case(c"import lib.safe_buffer\nint main():\n\town WByteString* s = byte_string_new()\n\tbyte_string_push(s, cast(byte, 7))\n\tref byte[] view = byte_string_view(s)\n\tbyte_string_push(s, cast(byte, 9))\n\treturn cast(int, view[0])\n", c"conflicting")
	buffer_case(c"import lib.safe_buffer\nint main():\n\town WByteString* s = byte_string_new()\n\tbyte_string_push(s, cast(byte, 7))\n\tref byte[] view = byte_string_view(s)\n\tbyte_string_set(s, 0, cast(byte, 9))\n\treturn cast(int, view[0])\n", c"conflicting")
	buffer_case(c"import lib.safe_buffer\nint main():\n\town WByteString* s = byte_string_new()\n\tbyte_string_push(s, cast(byte, 7))\n\tref byte[] view = byte_string_view(s)\n\tbyte_string_pop(s)\n\treturn cast(int, view[0])\n", c"conflicting")
	buffer_case(c"import lib.safe_buffer\nint main():\n\town WByteString* s = byte_string_new()\n\tbyte_string_push(s, cast(byte, 7))\n\tref byte[] view = byte_string_view(s)\n\tbyte_string_clear(s)\n\treturn cast(int, view[0])\n", c"conflicting")
	buffer_case(c"import lib.safe_buffer\nint main():\n\town WByteString* s = byte_string_new()\n\tbyte_string_push(s, cast(byte, 7))\n\tref byte[] view = byte_string_view(s)\n\ts = byte_string_new()\n\treturn cast(int, view[0])\n", c"conflicting")


void test_checked_collection_opacity():
	buffer_case(c"import lib.safe_buffer\nint main():\n\town WIntBuffer* b = int_buffer_new()\n\tint_buffer_push(b, 7)\n\treturn b.length\n", c"safe:", 1)
	buffer_case(c"import lib.safe_buffer\nint main():\n\town WIntBuffer* b = int_buffer_new()\n\tint_buffer_push(b, 7)\n\treturn b.capacity\n", c"safe:", 1)
	buffer_case(c"import lib.safe_buffer\nint main():\n\town WIntBuffer* b = int_buffer_new()\n\tint_buffer_push(b, 7)\n\treturn cast(int, b.items)\n", c"safe:", 1)
	buffer_case(c"import lib.safe_buffer\nint main():\n\town WIntBuffer* b = int_buffer_new()\n\tint_buffer_push(b, 7)\n\tb.length = 999\n\treturn 0\n", c"safe:", 1)
	buffer_case(c"import lib.safe_buffer\nint main():\n\town WIntBuffer* b = new WIntBuffer\n\treturn 0\n", c"safe:")
	buffer_case(c"import lib.safe_buffer\nint main():\n\town WIntBuffer* b = new WIntBuffer(0, 0, 0)\n\treturn 0\n", c"safe:", 1)
	buffer_case(c"import lib.safe_buffer\nint main():\n\town WIntBuffer* b = int_buffer_new()\n\tint_buffer_push(b, 7)\n\treturn cast(int, b)\n", c"safe:", 1)
	buffer_case(c"import lib.safe_buffer\nint main():\n\town WIntBuffer* b = int_buffer_new()\n\tint_buffer_push(b, 7)\n\t__w_int_buffer_drop(b)\n\treturn 0\n", c"safe:", 1)
	buffer_case(c"import lib.safe_buffer\nint main():\n\town WIntBuffer* b = int_buffer_new()\n\tint_buffer_push(b, 7)\n\t__w_int_buffer_ensure(b, 100)\n\treturn 0\n", c"safe:", 1)
	buffer_case(c"import lib.safe_buffer\nint main():\n\town WByteString* s = byte_string_new()\n\tbyte_string_push(s, cast(byte, 7))\n\t__w_byte_string_drop(s)\n\treturn 0\n", c"safe:", 1)
	buffer_case(c"import lib.safe_buffer\nint main():\n\town WByteString* s = byte_string_new()\n\tbyte_string_push(s, cast(byte, 7))\n\treturn s.length\n", c"safe:", 1)
	buffer_case(c"import lib.safe_buffer\nint main():\n\town WByteString* s = new WByteString\n\treturn 0\n", c"safe:")
	buffer_case(c"struct WIntBuffer:\n\tint capacity\n\tint length\n\tint* items\nown WIntBuffer* int_buffer_new():\n\treturn new WIntBuffer\nint main():\n\town WIntBuffer* b = int_buffer_new()\n\treturn 0\n", c"safe:")


void test_checked_collection_runtime_bounds():
	buffer_case(c"import lib.safe_buffer\nint main():\n\town WIntBuffer* b = int_buffer_new()\n\treturn int_buffer_pop(b)\n", 0, 0, c"pop from empty checked buffer")
	buffer_case(c"import lib.safe_buffer\nint main():\n\town WIntBuffer* b = int_buffer_new()\n\tint_buffer_push(b, 7)\n\treturn int_buffer_get(b, -1)\n", 0, 0, c"buffer index out of range: index -1, length 1")
	buffer_case(c"import lib.safe_buffer\nint main():\n\town WIntBuffer* b = int_buffer_new()\n\tint_buffer_push(b, 7)\n\treturn int_buffer_get(b, 1)\n", 0, 0, c"buffer index out of range: index 1, length 1")
	buffer_case(c"import lib.safe_buffer\nint main():\n\town WIntBuffer* b = int_buffer_new()\n\tint_buffer_push(b, 7)\n\tint_buffer_clear(b)\n\treturn int_buffer_get(b, 0)\n", 0, 0, c"buffer index out of range: index 0, length 0")
	buffer_case(c"import lib.safe_buffer\nint main():\n\town WIntBuffer* b = int_buffer_new()\n\tint_buffer_push(b, 7)\n\tint_buffer_set(b, 1, 9)\n\treturn 0\n", 0, 0, c"buffer index out of range: index 1, length 1")
	buffer_case(c"import lib.safe_buffer\nint main():\n\town WByteString* s = byte_string_new()\n\treturn cast(int, byte_string_pop(s))\n", 0, 0, c"pop from empty checked byte string")
	buffer_case(c"import lib.safe_buffer\nint main():\n\town WByteString* s = byte_string_new()\n\tbyte_string_push(s, cast(byte, 7))\n\treturn cast(int, byte_string_get(s, 1))\n", 0, 0, c"byte string index out of range: index 1, length 1")


void test_checked_collection_helper_name_collisions():
	buffer_case(c"import lib.safe_buffer\nvoid __w_int_buffer_drop(WIntBuffer* value):\n\treturn\nint main():\n\town WIntBuffer* b = int_buffer_new()\n\treturn 0\n", c"")
	buffer_case(c"import lib.safe_buffer\nint dispose():\n\town WIntBuffer* b = int_buffer_new()\n\treturn 0\nvoid __w_int_buffer_drop(WIntBuffer* value):\n\treturn\nint main():\n\treturn dispose()\n", c"")
	buffer_case(c"import lib.safe_buffer\nint dispose():\n\town WByteString* s = byte_string_new()\n\treturn 0\nvoid __w_byte_string_drop(WByteString* value):\n\treturn\nint main():\n\treturn dispose()\n", c"")
	buffer_case(c"import lib.safe_buffer\nvoid __w_int_buffer_drop(WIntBuffer* value);\nint main():\n\town WIntBuffer* b = int_buffer_new()\n\treturn 0\n", 0)
	buffer_case(c"import lib.safe_buffer\nint dispose():\n\town WIntBuffer* b = int_buffer_new()\n\treturn 0\nvoid __w_int_buffer_drop(WIntBuffer* value);\nint main():\n\treturn dispose()\n", 0)


void test_checked_collection_runtime_pin():
	char* root = c"bin/safe_buffer_pin32"
	if (__word_size__ == 8): root = c"bin/safe_buffer_pin64"
	mkdir(root, 493)
	char* directory = strjoin(root, c"/lib")
	mkdir(directory, 493)
	char* path = strjoin(directory, c"/safe_buffer.w")
	char* source = strjoin(root, c".w")
	char* output = strjoin(root, c".out")
	char* original = file_read_text(c"lib/safe_buffer.w")
	assert1(original != 0)
	char* changed = strjoin(original, c"\n# changed implementation cannot inherit checked contracts\n")
	assert1(file_write_text(path, changed))
	assert1(file_write_text(source, c"import lib.safe_buffer\nint main():\n\town WIntBuffer* b = int_buffer_new()\n\treturn int_buffer_length(b)\n"))
	for mode in range(2):
		for checking in range(2):
			unlink(output)
			char** args = strv_new(9)
			strv_set(args, 0, c"bin/wv2")
			strv_set(args, 1, c"--quiet")
			strv_set(args, 2, c"--quiet")
			if (checking):
				strv_set(args, 1, c"check")
				strv_set(args, 2, c"--json")
			strv_set(args, 3, c"--quiet")
			if (mode): strv_set(args, 3, c"--safe")
			strv_set(args, 4, c"--quiet")
			if (__word_size__ == 8): strv_set(args, 4, c"x64")
			strv_set(args, 5, c"--import-root")
			strv_set(args, 6, root)
			strv_set(args, 7, source)
			strv_set(args, 8, c"--quiet")
			if (checking == 0):
				free(cast(void*, args))
				args = strv_new(10)
				strv_set(args, 0, c"bin/wv2")
				strv_set(args, 1, c"--quiet")
				if (mode): strv_set(args, 1, c"--safe")
				strv_set(args, 2, c"--quiet")
				if (__word_size__ == 8): strv_set(args, 2, c"x64")
				strv_set(args, 3, c"--import-root")
				strv_set(args, 4, root)
				strv_set(args, 5, source)
				strv_set(args, 6, c"-o")
				strv_set(args, 7, output)
				strv_set(args, 8, c"--quiet")
				strv_set(args, 9, c"--strict")
			process_result* result = process_run(args[0], args, 0, 0, 30000)
			buffer_result(result, c"runtime implementation differs", checking, source)
			assert1(open(output, 0, 0) < 0)
			process_result_free(result)
			free(cast(void*, args))
	unlink(path)
	unlink(source)
	free(original)
	free(changed)
	free(path)
	free(directory)
	free(source)
	free(output)
