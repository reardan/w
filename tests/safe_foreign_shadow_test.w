# wbuild: x64
# wbuild: deps=lib/safe_foreign_owner.w
# wbuild: deps=lib/safe_vector.w
# Audited foreign boundaries: attested imports and foreign owners. Every
# contract is checked and compiled with and without --safe, and a rejection
# must leave no executable. A case may write an audited module beside it: @M
# in the source names that module and @D is the SHA-256 of its bytes.
import lib.testing
import lib.process
import lib.file
import lib.str
import lib.sha256


int foreign_shadow_case_number


void foreign_shadow_result(process_result* result, char* diagnostic, int checking, char* path):
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


char* foreign_shadow_digest(char* text):
	char[32] digest
	sha256(text, strlen(text), &digest[0])
	char* hex = cast(char*, malloc(65))
	char* digits = c"0123456789abcdef"
	for i in range(32):
		int value = digest[i] & 255
		hex[i * 2] = digits[value >> 4]
		hex[i * 2 + 1] = digits[value & 15]
	hex[64] = 0
	return hex


# Runs bin/wv2 with the given arguments after the fixed prefix.
process_result* foreign_shadow_run(int checking, int safe, char* root, char* full, char* output):
	char** argv = strv_new(14)
	int count = 0
	strv_set(argv, count, c"bin/wv2")
	count += 1
	if (checking):
		strv_set(argv, count, c"check")
		strv_set(argv, count + 1, c"--json")
		count += 2
	strv_set(argv, count, c"--quiet")
	strv_set(argv, count + 1, c"--strict")
	count += 2
	if (__word_size__ == 8):
		strv_set(argv, count, c"x64")
		count += 1
	if (root != 0):
		strv_set(argv, count, c"--import-root")
		strv_set(argv, count + 1, root)
		count += 2
	if (safe):
		strv_set(argv, count, c"--safe")
		count += 1
	if (checking == 0):
		strv_set(argv, count, c"--no-direct-calls")
		count += 1
	strv_set(argv, count, full)
	count += 1
	if (checking == 0):
		strv_set(argv, count, c"-o")
		strv_set(argv, count + 1, output)
		count += 2
	process_result* result = process_run(argv[0], argv, 0, 0, 30000)
	free(cast(void*, argv))
	return result


# mode 1 edits the module after its digest is taken; mode 2 shadows it with
# a different file of the same name under an earlier import root.
void foreign_shadow_case(char* source, char* module, int mode, char* diagnostic, char* safe_diagnostic = 0, char* runtime_diagnostic = 0):
	foreign_shadow_case_number = foreign_shadow_case_number + 1
	char* number = itoa(foreign_shadow_case_number)
	char* tag = c"32_"
	if (__word_size__ == 8): tag = c"64_"
	char* stem = strjoin(c"foreign_shadow_case", tag)
	char* full = strjoin(strjoin(c"bin/", strjoin(stem, number)), c".w")
	char* output = strjoin(full, c".out")
	char* name = strjoin(strjoin(c"foreign_shadow_module", tag), number)
	char* module_path = strjoin(strjoin(c"bin/", name), c".w")
	char* root = 0
	char* shadow = 0
	if (module != 0):
		source = replace(source, c"@D", foreign_shadow_digest(module))
		source = replace(source, c"@M", strjoin(c"bin.", name))
		if (mode == 1): module = strjoin(module, c"# edited after review\n")
		assert1(file_write_text(module_path, module))
		if (mode == 2):
			root = strjoin(c"bin/foreign_shadow_shadow", tag)
			mkdir(root, 493)
			mkdir(strjoin(root, c"/bin"), 493)
			shadow = strjoin(strjoin(root, c"/"), module_path)
			assert1(file_write_text(shadow, strjoin(module, c"# shadow\n")))
	assert1(file_write_text(full, source))
	for safe in range(2):
		char* expected = diagnostic
		if (safe && safe_diagnostic): expected = safe_diagnostic
		unlink(output)
		process_result* checked = foreign_shadow_run(1, safe, root, full, output)
		foreign_shadow_result(checked, expected, 1, full)
		process_result_free(checked)
		process_result* compiled = foreign_shadow_run(0, safe, root, full, output)
		foreign_shadow_result(compiled, expected, 0, full)
		process_result_free(compiled)
		if (expected):
			assert1(open(output, 0, 0) < 0)
		else:
			char** run = strv_new(1)
			strv_set(run, 0, output)
			process_result* executed = process_run(output, run, 0, 0, 30000)
			assert1(executed != 0)
			if (runtime_diagnostic):
				assert1(executed.status != 0)
				assert_contains(executed.stderr_text, runtime_diagnostic)
			else:
				if (executed.status):
					print(full)
					print(executed.stderr_text)
				assert_equal(0, executed.status)
			process_result_free(executed)
			free(cast(void*, run))
		unlink(output)
	unlink(full)
	if (module != 0): unlink(module_path)
	if (shadow != 0): unlink(shadow)


void test_foreign_shadow___w_foreign_drop_ForeignHandle():
	foreign_shadow_case(c"import @M unsafe \"@D\"\nint use():\n\tint __w_foreign_drop_ForeignHandle = 0\n\town ForeignHandle* h = foreign_handle_new(7)\n\treturn foreign_handle_read(h) + __w_foreign_drop_ForeignHandle\nint main():\n\tif use() != 7: return 2\n\treturn foreign_handle_drop_count() - 1\n", c"# Audited nominal foreign handle with explicit cleanup and threading rules.\nimport lib.safe_foreign_owner\n\n\nstruct ForeignHandle:\n\tint secret\n\tint* raw\n\n\nint foreign_handle_drops\n\n\nvoid __w_foreign_drop_ForeignHandle(ForeignHandle* value):\n\tforeign_handle_drops += 1\n\tfree(value.raw)\n\tfree(value)\n\n\n# Audited assertions: exclusive transfer and concurrent shared reads are safe.\nvoid __w_foreign_send_ForeignHandle(ForeignHandle* value):\n\tpass\n\n\nvoid __w_foreign_sync_ForeignHandle(ForeignHandle* value):\n\tpass\n\n\nown ForeignHandle* foreign_handle_new(int value):\n\tForeignHandle* handle = new ForeignHandle\n\thandle.raw = new int\n\t*handle.raw = value\n\treturn cast(own ForeignHandle*, handle)\n\n\nint foreign_handle_read(ref ForeignHandle* value):\n\treturn *value.raw\n\n\nvoid foreign_handle_write(refmut ForeignHandle* value, int number):\n\t*value.raw = number\n\n\nint foreign_handle_drop_count():\n\treturn foreign_handle_drops\n", 0, 0, 0, 0)

void test_foreign_shadow_free():
	foreign_shadow_case(c"import @M unsafe \"@D\"\nint use():\n\tint free = 0\n\town ForeignHandle* h = foreign_handle_new(7)\n\treturn foreign_handle_read(h) + free\nint main():\n\tif use() != 7: return 2\n\treturn foreign_handle_drop_count() - 1\n", c"# Audited nominal foreign handle with explicit cleanup and threading rules.\nimport lib.safe_foreign_owner\n\n\nstruct ForeignHandle:\n\tint secret\n\tint* raw\n\n\nint foreign_handle_drops\n\n\nvoid __w_foreign_drop_ForeignHandle(ForeignHandle* value):\n\tforeign_handle_drops += 1\n\tfree(value.raw)\n\tfree(value)\n\n\n# Audited assertions: exclusive transfer and concurrent shared reads are safe.\nvoid __w_foreign_send_ForeignHandle(ForeignHandle* value):\n\tpass\n\n\nvoid __w_foreign_sync_ForeignHandle(ForeignHandle* value):\n\tpass\n\n\nown ForeignHandle* foreign_handle_new(int value):\n\tForeignHandle* handle = new ForeignHandle\n\thandle.raw = new int\n\t*handle.raw = value\n\treturn cast(own ForeignHandle*, handle)\n\n\nint foreign_handle_read(ref ForeignHandle* value):\n\treturn *value.raw\n\n\nvoid foreign_handle_write(refmut ForeignHandle* value, int number):\n\t*value.raw = number\n\n\nint foreign_handle_drop_count():\n\treturn foreign_handle_drops\n", 0, 0, 0, 0)

void test_foreign_shadow___w_foreign_owner_check():
	foreign_shadow_case(c"import @M unsafe \"@D\"\nint use():\n\tint __w_foreign_owner_check = 0\n\town ForeignHandle* h = foreign_handle_new(7)\n\treturn foreign_handle_read(h) + __w_foreign_owner_check\nint main():\n\tif use() != 7: return 2\n\treturn foreign_handle_drop_count() - 1\n", c"# Audited nominal foreign handle with explicit cleanup and threading rules.\nimport lib.safe_foreign_owner\n\n\nstruct ForeignHandle:\n\tint secret\n\tint* raw\n\n\nint foreign_handle_drops\n\n\nvoid __w_foreign_drop_ForeignHandle(ForeignHandle* value):\n\tforeign_handle_drops += 1\n\tfree(value.raw)\n\tfree(value)\n\n\n# Audited assertions: exclusive transfer and concurrent shared reads are safe.\nvoid __w_foreign_send_ForeignHandle(ForeignHandle* value):\n\tpass\n\n\nvoid __w_foreign_sync_ForeignHandle(ForeignHandle* value):\n\tpass\n\n\nown ForeignHandle* foreign_handle_new(int value):\n\tForeignHandle* handle = new ForeignHandle\n\thandle.raw = new int\n\t*handle.raw = value\n\treturn cast(own ForeignHandle*, handle)\n\n\nint foreign_handle_read(ref ForeignHandle* value):\n\treturn *value.raw\n\n\nvoid foreign_handle_write(refmut ForeignHandle* value, int number):\n\t*value.raw = number\n\n\nint foreign_handle_drop_count():\n\treturn foreign_handle_drops\n", 0, 0, 0, 0)

void test_foreign_shadow_drop_argument():
	foreign_shadow_case(c"import @M unsafe \"@D\"\nint use(int __w_foreign_drop_ForeignHandle):\n\town ForeignHandle* h = foreign_handle_new(7)\n\treturn foreign_handle_read(h) + __w_foreign_drop_ForeignHandle\nint main():\n\tif use(0) != 7: return 2\n\treturn foreign_handle_drop_count() - 1\n", c"# Audited nominal foreign handle with explicit cleanup and threading rules.\nimport lib.safe_foreign_owner\n\n\nstruct ForeignHandle:\n\tint secret\n\tint* raw\n\n\nint foreign_handle_drops\n\n\nvoid __w_foreign_drop_ForeignHandle(ForeignHandle* value):\n\tforeign_handle_drops += 1\n\tfree(value.raw)\n\tfree(value)\n\n\n# Audited assertions: exclusive transfer and concurrent shared reads are safe.\nvoid __w_foreign_send_ForeignHandle(ForeignHandle* value):\n\tpass\n\n\nvoid __w_foreign_sync_ForeignHandle(ForeignHandle* value):\n\tpass\n\n\nown ForeignHandle* foreign_handle_new(int value):\n\tForeignHandle* handle = new ForeignHandle\n\thandle.raw = new int\n\t*handle.raw = value\n\treturn cast(own ForeignHandle*, handle)\n\n\nint foreign_handle_read(ref ForeignHandle* value):\n\treturn *value.raw\n\n\nvoid foreign_handle_write(refmut ForeignHandle* value, int number):\n\t*value.raw = number\n\n\nint foreign_handle_drop_count():\n\treturn foreign_handle_drops\n", 0, 0, 0, 0)

void test_foreign_shadow_invalid_owner():
	foreign_shadow_case(c"import @M unsafe \"@D\"\nint main():\n\tint __w_foreign_owner_check = 0\n\town int* h = foreign_result()\n\treturn *h + __w_foreign_owner_check\n", c"own int* foreign_result():\n\treturn cast(own int*, 123456)\n", 0, 0, 0, c"foreign owner: result is not a live W allocation")

void test_foreign_shadow_pinned_drop():
	foreign_shadow_case(c"import @M unsafe \"@D\"\nimport lib.safe_vector\nimport lib.memory_debug\nint use():\n\tint __w_buffer_drop = 0\n\town WBuffer[int]* values = buffer_new[int]()\n\tbuffer_push[int](values, 7)\n\treturn buffer_get[int](values, 0) + __w_buffer_drop\nint main():\n\tint before = 0\n\tunsafe:\n\t\tmalloc_force_debug_mode()\n\t\tbefore = debug_alloc_report_leaks()\n\tif use() != 7: return 2\n\tint after = 0\n\tunsafe: after = debug_alloc_report_leaks()\n\treturn after - before\n", c"# Audited nominal foreign handle with explicit cleanup and threading rules.\nimport lib.safe_foreign_owner\n\n\nstruct ForeignHandle:\n\tint secret\n\tint* raw\n\n\nint foreign_handle_drops\n\n\nvoid __w_foreign_drop_ForeignHandle(ForeignHandle* value):\n\tforeign_handle_drops += 1\n\tfree(value.raw)\n\tfree(value)\n\n\n# Audited assertions: exclusive transfer and concurrent shared reads are safe.\nvoid __w_foreign_send_ForeignHandle(ForeignHandle* value):\n\tpass\n\n\nvoid __w_foreign_sync_ForeignHandle(ForeignHandle* value):\n\tpass\n\n\nown ForeignHandle* foreign_handle_new(int value):\n\tForeignHandle* handle = new ForeignHandle\n\thandle.raw = new int\n\t*handle.raw = value\n\treturn cast(own ForeignHandle*, handle)\n\n\nint foreign_handle_read(ref ForeignHandle* value):\n\treturn *value.raw\n\n\nvoid foreign_handle_write(refmut ForeignHandle* value, int number):\n\t*value.raw = number\n\n\nint foreign_handle_drop_count():\n\treturn foreign_handle_drops\n", 0, 0, 0, 0)

void test_foreign_shadow_plain_free():
	foreign_shadow_case(c"import @M unsafe \"@D\"\nimport lib.memory_debug\nint use():\n\tint free = 0\n\town int* value = new int\n\t*value = 7\n\treturn *value + free\nint main():\n\tint before = 0\n\tunsafe:\n\t\tmalloc_force_debug_mode()\n\t\tbefore = debug_alloc_report_leaks()\n\tif use() != 7: return 2\n\tint after = 0\n\tunsafe: after = debug_alloc_report_leaks()\n\treturn after - before\n", c"# Audited nominal foreign handle with explicit cleanup and threading rules.\nimport lib.safe_foreign_owner\n\n\nstruct ForeignHandle:\n\tint secret\n\tint* raw\n\n\nint foreign_handle_drops\n\n\nvoid __w_foreign_drop_ForeignHandle(ForeignHandle* value):\n\tforeign_handle_drops += 1\n\tfree(value.raw)\n\tfree(value)\n\n\n# Audited assertions: exclusive transfer and concurrent shared reads are safe.\nvoid __w_foreign_send_ForeignHandle(ForeignHandle* value):\n\tpass\n\n\nvoid __w_foreign_sync_ForeignHandle(ForeignHandle* value):\n\tpass\n\n\nown ForeignHandle* foreign_handle_new(int value):\n\tForeignHandle* handle = new ForeignHandle\n\thandle.raw = new int\n\t*handle.raw = value\n\treturn cast(own ForeignHandle*, handle)\n\n\nint foreign_handle_read(ref ForeignHandle* value):\n\treturn *value.raw\n\n\nvoid foreign_handle_write(refmut ForeignHandle* value, int number):\n\t*value.raw = number\n\n\nint foreign_handle_drop_count():\n\treturn foreign_handle_drops\n", 0, 0, 0, 0)
void test_foreign_shadow_bad_return():
	foreign_shadow_case(c"import @M unsafe \"@D\"\nint main():\n\town Handle* value = make_handle()\n\treturn 0\n", c"struct Handle:\n\tint value\nint __w_foreign_drop_Handle(Handle* value):\n\treturn 0\nown Handle* make_handle():\n\treturn cast(own Handle*, new Handle(3))\n", 0, c"safe: audited foreign hook requires void hook(Type*)")

void test_foreign_shadow_bad_arity():
	foreign_shadow_case(c"import @M unsafe \"@D\"\nint main():\n\town Handle* value = make_handle()\n\treturn 0\n", c"struct Handle:\n\tint value\nvoid __w_foreign_drop_Handle():\n\tpass\nown Handle* make_handle():\n\treturn cast(own Handle*, new Handle(3))\n", 0, c"safe: audited foreign hook requires void hook(Type*)")

void test_foreign_shadow_bad_checked():
	foreign_shadow_case(c"import @M unsafe \"@D\"\nint main():\n\town Handle* value = make_handle()\n\treturn 0\n", c"struct Handle:\n\tint value\nvoid __w_foreign_drop_Handle(ref Handle* value):\n\tpass\nown Handle* make_handle():\n\treturn cast(own Handle*, new Handle(3))\n", 0, c"safe: audited foreign hook requires void hook(Type*)")

void test_foreign_shadow_bad_depth():
	foreign_shadow_case(c"import @M unsafe \"@D\"\nint main():\n\town Handle* value = make_handle()\n\treturn 0\n", c"struct Handle:\n\tint value\nvoid __w_foreign_drop_Handle(Handle** value):\n\tpass\nown Handle* make_handle():\n\treturn cast(own Handle*, new Handle(3))\n", 0, c"safe: audited foreign hook requires void hook(Type*)")

void test_foreign_shadow_bad_pointee():
	foreign_shadow_case(c"import @M unsafe \"@D\"\nint main():\n\town Handle* value = make_handle()\n\treturn 0\n", c"struct Handle:\n\tint value\nvoid __w_foreign_drop_Handle(int* value):\n\tpass\nown Handle* make_handle():\n\treturn cast(own Handle*, new Handle(3))\n", 0, c"safe: audited foreign hook requires void hook(Type*)")

void test_foreign_shadow_bad_variable():
	foreign_shadow_case(c"import @M unsafe \"@D\"\nint main():\n\town Handle* value = make_handle()\n\treturn 0\n", c"struct Handle:\n\tint value\nint __w_foreign_drop_Handle\nown Handle* make_handle():\n\treturn cast(own Handle*, new Handle(3))\n", 0, c"safe: audited foreign hook requires void hook(Type*)")

void test_foreign_shadow_undefined():
	foreign_shadow_case(c"import @M unsafe \"@D\"\nint main():\n\town Handle* value = make_handle()\n\treturn 0\n", c"struct Handle:\n\tint value\nvoid __w_foreign_drop_Handle(Handle* value);\nown Handle* make_handle():\n\treturn cast(own Handle*, new Handle(3))\n", 0, c"safe: audited foreign hook requires a definition")

void test_foreign_shadow_forward():
	foreign_shadow_case(c"import @M unsafe \"@D\"\nint main():\n\tdrop_forward()\n\treturn drop_count() - 1\n", c"struct Handle:\n\tint value\nint drops\nvoid __w_foreign_drop_Handle(Handle* value);\nown Handle* make_handle():\n\treturn cast(own Handle*, new Handle(3))\nvoid drop_forward():\n\town Handle* h = make_handle()\nvoid __w_foreign_drop_Handle(Handle* value):\n\tdrops += 1\n\tfree(value)\nint drop_count():\n\treturn drops\n", 0, 0)
