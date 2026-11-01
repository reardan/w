# wbuild: x64
# wbuild: deps=lib/safe_foreign_owner.w
# Audited foreign boundaries: attested imports and foreign owners. Every
# contract is checked and compiled with and without --safe, and a rejection
# must leave no executable. A case may write an audited module beside it: @M
# in the source names that module and @D is the SHA-256 of its bytes.
import lib.testing
import lib.process
import lib.file
import lib.str
import lib.sha256


int foreign_contract_case_number


void foreign_contract_result(process_result* result, char* diagnostic, int checking, char* path):
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


char* foreign_contract_digest(char* text):
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
process_result* foreign_contract_run(int checking, int safe, char* root, char* full, char* output):
	char** argv = strv_new(13)
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
void foreign_contract_case(char* source, char* module, int mode, char* diagnostic, char* safe_diagnostic = 0, char* runtime_diagnostic = 0):
	foreign_contract_case_number = foreign_contract_case_number + 1
	char* number = itoa(foreign_contract_case_number)
	char* tag = c"32_"
	if (__word_size__ == 8): tag = c"64_"
	char* stem = strjoin(c"foreign_contract_case", tag)
	char* full = strjoin(strjoin(c"bin/", strjoin(stem, number)), c".w")
	char* output = strjoin(full, c".out")
	char* name = strjoin(strjoin(c"foreign_contract_module", tag), number)
	char* module_path = strjoin(strjoin(c"bin/", name), c".w")
	char* root = 0
	char* shadow = 0
	if (module != 0):
		source = replace(source, c"@D", foreign_contract_digest(module))
		source = replace(source, c"@M", strjoin(c"bin.", name))
		if (mode == 1): module = strjoin(module, c"# edited after review\n")
		assert1(file_write_text(module_path, module))
		if (mode == 2):
			root = strjoin(c"bin/foreign_contract_shadow", tag)
			mkdir(root, 493)
			mkdir(strjoin(root, c"/bin"), 493)
			shadow = strjoin(strjoin(root, c"/"), module_path)
			assert1(file_write_text(shadow, strjoin(module, c"# shadow\n")))
	assert1(file_write_text(full, source))
	for safe in range(2):
		char* expected = diagnostic
		if (safe && safe_diagnostic): expected = safe_diagnostic
		unlink(output)
		process_result* checked = foreign_contract_run(1, safe, root, full, output)
		foreign_contract_result(checked, expected, 1, full)
		process_result_free(checked)
		process_result* compiled = foreign_contract_run(0, safe, root, full, output)
		foreign_contract_result(compiled, expected, 0, full)
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


void test_foreign_contract_cleanup():
	foreign_contract_case(c"import @M unsafe \"@D\"\n\nint use():\n\town ForeignHandle* handle = foreign_handle_new(7)\n\tforeign_handle_write(handle, 8)\n\treturn foreign_handle_read(handle)\n\nint main():\n\tif (use() != 8): return 1\n\treturn foreign_handle_drop_count() - 1\n", c"# Audited nominal foreign handle with explicit cleanup and threading rules.\nimport lib.safe_foreign_owner\n\n\nstruct ForeignHandle:\n\tint secret\n\tint* raw\n\n\nint foreign_handle_drops\n\n\nvoid __w_foreign_drop_ForeignHandle(ForeignHandle* value):\n\tforeign_handle_drops += 1\n\tfree(value.raw)\n\tfree(value)\n\n\n# Audited assertions: exclusive transfer and concurrent shared reads are safe.\nvoid __w_foreign_send_ForeignHandle(ForeignHandle* value):\n\tpass\n\n\nvoid __w_foreign_sync_ForeignHandle(ForeignHandle* value):\n\tpass\n\n\nown ForeignHandle* foreign_handle_new(int value):\n\tForeignHandle* handle = new ForeignHandle\n\thandle.raw = new int\n\t*handle.raw = value\n\treturn cast(own ForeignHandle*, handle)\n\n\nint foreign_handle_read(ref ForeignHandle* value):\n\treturn *value.raw\n\n\nvoid foreign_handle_write(refmut ForeignHandle* value, int number):\n\t*value.raw = number\n\n\nint foreign_handle_drop_count():\n\treturn foreign_handle_drops\n", 0, 0)

void test_foreign_contract_nested_cleanup():
	foreign_contract_case(c"import @M unsafe \"@D\"\n\nstruct Holder:\n\town ForeignHandle* value\n\nint use():\n\town Holder* h = new Holder(foreign_handle_new(3))\n\treturn foreign_handle_read(h.value)\n\nint main():\n\tif (use() != 3): return 1\n\treturn foreign_handle_drop_count() - 1\n", c"# Audited nominal foreign handle with explicit cleanup and threading rules.\nimport lib.safe_foreign_owner\n\n\nstruct ForeignHandle:\n\tint secret\n\tint* raw\n\n\nint foreign_handle_drops\n\n\nvoid __w_foreign_drop_ForeignHandle(ForeignHandle* value):\n\tforeign_handle_drops += 1\n\tfree(value.raw)\n\tfree(value)\n\n\n# Audited assertions: exclusive transfer and concurrent shared reads are safe.\nvoid __w_foreign_send_ForeignHandle(ForeignHandle* value):\n\tpass\n\n\nvoid __w_foreign_sync_ForeignHandle(ForeignHandle* value):\n\tpass\n\n\nown ForeignHandle* foreign_handle_new(int value):\n\tForeignHandle* handle = new ForeignHandle\n\thandle.raw = new int\n\t*handle.raw = value\n\treturn cast(own ForeignHandle*, handle)\n\n\nint foreign_handle_read(ref ForeignHandle* value):\n\treturn *value.raw\n\n\nvoid foreign_handle_write(refmut ForeignHandle* value, int number):\n\t*value.raw = number\n\n\nint foreign_handle_drop_count():\n\treturn foreign_handle_drops\n", 0, 0)

void test_foreign_contract_opaque_field():
	foreign_contract_case(c"import @M unsafe \"@D\"\n\nint main():\n\town ForeignHandle* h = foreign_handle_new(1)\n\treturn h.secret\n", c"# Audited nominal foreign handle with explicit cleanup and threading rules.\nimport lib.safe_foreign_owner\n\n\nstruct ForeignHandle:\n\tint secret\n\tint* raw\n\n\nint foreign_handle_drops\n\n\nvoid __w_foreign_drop_ForeignHandle(ForeignHandle* value):\n\tforeign_handle_drops += 1\n\tfree(value.raw)\n\tfree(value)\n\n\n# Audited assertions: exclusive transfer and concurrent shared reads are safe.\nvoid __w_foreign_send_ForeignHandle(ForeignHandle* value):\n\tpass\n\n\nvoid __w_foreign_sync_ForeignHandle(ForeignHandle* value):\n\tpass\n\n\nown ForeignHandle* foreign_handle_new(int value):\n\tForeignHandle* handle = new ForeignHandle\n\thandle.raw = new int\n\t*handle.raw = value\n\treturn cast(own ForeignHandle*, handle)\n\n\nint foreign_handle_read(ref ForeignHandle* value):\n\treturn *value.raw\n\n\nvoid foreign_handle_write(refmut ForeignHandle* value, int number):\n\t*value.raw = number\n\n\nint foreign_handle_drop_count():\n\treturn foreign_handle_drops\n", 0, c"safe: opaque collection metadata is not accessible")

void test_foreign_contract_opaque_new():
	foreign_contract_case(c"import @M unsafe \"@D\"\n\nint main():\n\town ForeignHandle* h = new ForeignHandle\n\treturn 0\n", c"# Audited nominal foreign handle with explicit cleanup and threading rules.\nimport lib.safe_foreign_owner\n\n\nstruct ForeignHandle:\n\tint secret\n\tint* raw\n\n\nint foreign_handle_drops\n\n\nvoid __w_foreign_drop_ForeignHandle(ForeignHandle* value):\n\tforeign_handle_drops += 1\n\tfree(value.raw)\n\tfree(value)\n\n\n# Audited assertions: exclusive transfer and concurrent shared reads are safe.\nvoid __w_foreign_send_ForeignHandle(ForeignHandle* value):\n\tpass\n\n\nvoid __w_foreign_sync_ForeignHandle(ForeignHandle* value):\n\tpass\n\n\nown ForeignHandle* foreign_handle_new(int value):\n\tForeignHandle* handle = new ForeignHandle\n\thandle.raw = new int\n\t*handle.raw = value\n\treturn cast(own ForeignHandle*, handle)\n\n\nint foreign_handle_read(ref ForeignHandle* value):\n\treturn *value.raw\n\n\nvoid foreign_handle_write(refmut ForeignHandle* value, int number):\n\t*value.raw = number\n\n\nint foreign_handle_drop_count():\n\treturn foreign_handle_drops\n", 0, c"safe: opaque collections require an audited constructor")

void test_foreign_contract_opaque_copy():
	foreign_contract_case(c"import @M unsafe \"@D\"\n\nint main():\n\town ForeignHandle* h = foreign_handle_new(1)\n\tForeignHandle value = *h\n\treturn 0\n", c"# Audited nominal foreign handle with explicit cleanup and threading rules.\nimport lib.safe_foreign_owner\n\n\nstruct ForeignHandle:\n\tint secret\n\tint* raw\n\n\nint foreign_handle_drops\n\n\nvoid __w_foreign_drop_ForeignHandle(ForeignHandle* value):\n\tforeign_handle_drops += 1\n\tfree(value.raw)\n\tfree(value)\n\n\n# Audited assertions: exclusive transfer and concurrent shared reads are safe.\nvoid __w_foreign_send_ForeignHandle(ForeignHandle* value):\n\tpass\n\n\nvoid __w_foreign_sync_ForeignHandle(ForeignHandle* value):\n\tpass\n\n\nown ForeignHandle* foreign_handle_new(int value):\n\tForeignHandle* handle = new ForeignHandle\n\thandle.raw = new int\n\t*handle.raw = value\n\treturn cast(own ForeignHandle*, handle)\n\n\nint foreign_handle_read(ref ForeignHandle* value):\n\treturn *value.raw\n\n\nvoid foreign_handle_write(refmut ForeignHandle* value, int number):\n\t*value.raw = number\n\n\nint foreign_handle_drop_count():\n\treturn foreign_handle_drops\n", 0, c"safe: unsupported type or reference-bearing aggregate")

void test_foreign_contract_loop_cleanup():
	foreign_contract_case(c"import @M unsafe \"@D\"\n\nint main():\n\tfor i in range(6):\n\t\town ForeignHandle* h = foreign_handle_new(i)\n\t\tif (i == 2): continue\n\t\tif (i == 4): break\n\treturn foreign_handle_drop_count() - 5\n", c"# Audited nominal foreign handle with explicit cleanup and threading rules.\nimport lib.safe_foreign_owner\n\n\nstruct ForeignHandle:\n\tint secret\n\tint* raw\n\n\nint foreign_handle_drops\n\n\nvoid __w_foreign_drop_ForeignHandle(ForeignHandle* value):\n\tforeign_handle_drops += 1\n\tfree(value.raw)\n\tfree(value)\n\n\n# Audited assertions: exclusive transfer and concurrent shared reads are safe.\nvoid __w_foreign_send_ForeignHandle(ForeignHandle* value):\n\tpass\n\n\nvoid __w_foreign_sync_ForeignHandle(ForeignHandle* value):\n\tpass\n\n\nown ForeignHandle* foreign_handle_new(int value):\n\tForeignHandle* handle = new ForeignHandle\n\thandle.raw = new int\n\t*handle.raw = value\n\treturn cast(own ForeignHandle*, handle)\n\n\nint foreign_handle_read(ref ForeignHandle* value):\n\treturn *value.raw\n\n\nvoid foreign_handle_write(refmut ForeignHandle* value, int number):\n\t*value.raw = number\n\n\nint foreign_handle_drop_count():\n\treturn foreign_handle_drops\n", 0, 0)

void test_foreign_contract_shared_threads():
	foreign_contract_case(c"import @M unsafe \"@D\"\n\nimport lib.safe_thread\n\ntype Read = fn[](ref ForeignHandle*) -> int\n\nint read_handle(ref ForeignHandle* h):\n\treturn foreign_handle_read(h)\n\nint main():\n\town ForeignHandle* h = foreign_handle_new(4)\n\tref ForeignHandle* a = h\n\tref ForeignHandle* b = h\n\tRead* read = read_handle\n\treturn safe_thread_fork_join(read, a, b) - 8\n", c"# Audited nominal foreign handle with explicit cleanup and threading rules.\nimport lib.safe_foreign_owner\n\n\nstruct ForeignHandle:\n\tint secret\n\tint* raw\n\n\nint foreign_handle_drops\n\n\nvoid __w_foreign_drop_ForeignHandle(ForeignHandle* value):\n\tforeign_handle_drops += 1\n\tfree(value.raw)\n\tfree(value)\n\n\n# Audited assertions: exclusive transfer and concurrent shared reads are safe.\nvoid __w_foreign_send_ForeignHandle(ForeignHandle* value):\n\tpass\n\n\nvoid __w_foreign_sync_ForeignHandle(ForeignHandle* value):\n\tpass\n\n\nown ForeignHandle* foreign_handle_new(int value):\n\tForeignHandle* handle = new ForeignHandle\n\thandle.raw = new int\n\t*handle.raw = value\n\treturn cast(own ForeignHandle*, handle)\n\n\nint foreign_handle_read(ref ForeignHandle* value):\n\treturn *value.raw\n\n\nvoid foreign_handle_write(refmut ForeignHandle* value, int number):\n\t*value.raw = number\n\n\nint foreign_handle_drop_count():\n\treturn foreign_handle_drops\n", 0, 0)

void test_foreign_contract_no_sync():
	foreign_contract_case(c"import @M unsafe \"@D\"\n\nimport lib.safe_thread\n\ntype Read = fn[](ref ForeignHandle*) -> int\n\nint read_handle(ref ForeignHandle* h):\n\treturn foreign_handle_read(h)\n\nint main():\n\town ForeignHandle* h = foreign_handle_new(4)\n\tref ForeignHandle* a = h\n\tref ForeignHandle* b = h\n\tRead* read = read_handle\n\treturn safe_thread_fork_join(read, a, b)\n", c"# Audited nominal foreign handle with explicit cleanup and threading rules.\nimport lib.safe_foreign_owner\n\n\nstruct ForeignHandle:\n\tint secret\n\tint* raw\n\n\nint foreign_handle_drops\n\n\nvoid __w_foreign_drop_ForeignHandle(ForeignHandle* value):\n\tforeign_handle_drops += 1\n\tfree(value.raw)\n\tfree(value)\n\n\n# Audited assertions: exclusive transfer and concurrent shared reads are safe.\nvoid __w_foreign_send_ForeignHandle(ForeignHandle* value):\n\tpass\n\n\nvoid not_sync(ForeignHandle* value):\n\tpass\n\n\nown ForeignHandle* foreign_handle_new(int value):\n\tForeignHandle* handle = new ForeignHandle\n\thandle.raw = new int\n\t*handle.raw = value\n\treturn cast(own ForeignHandle*, handle)\n\n\nint foreign_handle_read(ref ForeignHandle* value):\n\treturn *value.raw\n\n\nvoid foreign_handle_write(refmut ForeignHandle* value, int number):\n\t*value.raw = number\n\n\nint foreign_handle_drop_count():\n\treturn foreign_handle_drops\n", 0, c"is a foreign object without a shared thread contract")

void test_foreign_contract_spawn():
	foreign_contract_case(c"import @M unsafe \"@D\"\n\nimport lib.safe_thread\n\ntype Run = fn[](own ForeignHandle*) -> int\n\nint run(own ForeignHandle* h):\n\treturn foreign_handle_read(h)\n\nint main():\n\tRun* work = run\n\toptown WSafeThread* thread = safe_thread_spawn(work, foreign_handle_new(9))\n\tif (!thread): return 1\n\town WSafeThread* joined = thread\n\treturn safe_thread_join(joined) - 9\n", c"# Audited nominal foreign handle with explicit cleanup and threading rules.\nimport lib.safe_foreign_owner\n\n\nstruct ForeignHandle:\n\tint secret\n\tint* raw\n\n\nint foreign_handle_drops\n\n\nvoid __w_foreign_drop_ForeignHandle(ForeignHandle* value):\n\tforeign_handle_drops += 1\n\tfree(value.raw)\n\tfree(value)\n\n\n# Audited assertions: exclusive transfer and concurrent shared reads are safe.\nvoid __w_foreign_send_ForeignHandle(ForeignHandle* value):\n\tpass\n\n\nvoid __w_foreign_sync_ForeignHandle(ForeignHandle* value):\n\tpass\n\n\nown ForeignHandle* foreign_handle_new(int value):\n\tForeignHandle* handle = new ForeignHandle\n\thandle.raw = new int\n\t*handle.raw = value\n\treturn cast(own ForeignHandle*, handle)\n\n\nint foreign_handle_read(ref ForeignHandle* value):\n\treturn *value.raw\n\n\nvoid foreign_handle_write(refmut ForeignHandle* value, int number):\n\t*value.raw = number\n\n\nint foreign_handle_drop_count():\n\treturn foreign_handle_drops\n", 0, 0)

void test_foreign_contract_no_send():
	foreign_contract_case(c"import @M unsafe \"@D\"\n\nimport lib.safe_thread\n\ntype Run = fn[](own ForeignHandle*) -> int\n\nint run(own ForeignHandle* h):\n\treturn foreign_handle_read(h)\n\nint main():\n\tRun* work = run\n\toptown WSafeThread* thread = safe_thread_spawn(work, foreign_handle_new(9))\n\treturn 0\n", c"# Audited nominal foreign handle with explicit cleanup and threading rules.\nimport lib.safe_foreign_owner\n\n\nstruct ForeignHandle:\n\tint secret\n\tint* raw\n\n\nint foreign_handle_drops\n\n\nvoid __w_foreign_drop_ForeignHandle(ForeignHandle* value):\n\tforeign_handle_drops += 1\n\tfree(value.raw)\n\tfree(value)\n\n\n# Audited assertions: exclusive transfer and concurrent shared reads are safe.\nvoid not_send(ForeignHandle* value):\n\tpass\n\n\nvoid __w_foreign_sync_ForeignHandle(ForeignHandle* value):\n\tpass\n\n\nown ForeignHandle* foreign_handle_new(int value):\n\tForeignHandle* handle = new ForeignHandle\n\thandle.raw = new int\n\t*handle.raw = value\n\treturn cast(own ForeignHandle*, handle)\n\n\nint foreign_handle_read(ref ForeignHandle* value):\n\treturn *value.raw\n\n\nvoid foreign_handle_write(refmut ForeignHandle* value, int number):\n\t*value.raw = number\n\n\nint foreign_handle_drop_count():\n\treturn foreign_handle_drops\n", 0, c"is a foreign object without a thread contract")

void test_foreign_provenance_null():
	foreign_contract_case(c"import @M unsafe \"@D\"\n\nint main():\n\town int* value = foreign_result()\n\treturn *value - 7\n", c"own int* foreign_result():\n\treturn cast(own int*, 0)\n", 0, 0, 0, c"foreign owner: non-null result is null")

void test_foreign_provenance_unmapped():
	foreign_contract_case(c"import @M unsafe \"@D\"\n\nint main():\n\town int* value = foreign_result()\n\treturn *value - 7\n", c"own int* foreign_result():\n\treturn cast(own int*, 123456)\n", 0, 0, 0, c"foreign owner: result is not a live W allocation")

void test_foreign_provenance_tombstone():
	foreign_contract_case(c"import @M unsafe \"@D\"\n\nint main():\n\town int* value = foreign_result()\n\treturn *value - 7\n", c"own int* foreign_result():\n\treturn cast(own int*, 1)\n", 0, 0, 0, c"foreign owner: result is not a live W allocation")

void test_foreign_provenance_interior():
	foreign_contract_case(c"import @M unsafe \"@D\"\n\nint main():\n\town int* value = foreign_result()\n\treturn *value - 7\n", c"own int* foreign_result():\n\tint* p = new int[4]\n\treturn cast(own int*, p + 4)\n", 0, 0, 0, c"foreign owner: result is not a live W allocation")

void test_foreign_provenance_freed():
	foreign_contract_case(c"import @M unsafe \"@D\"\n\nint main():\n\town int* value = foreign_result()\n\treturn *value - 7\n", c"own int* foreign_result():\n\tint* p = new int\n\tfree(p)\n\treturn cast(own int*, p)\n", 0, 0, 0, c"foreign owner: result is not a live W allocation")

void test_foreign_provenance_small():
	foreign_contract_case(c"import @M unsafe \"@D\"\n\nint main():\n\town int* value = foreign_result()\n\treturn *value - 7\n", c"own int* foreign_result():\n\tvoid* p = malloc(1)\n\treturn cast(own int*, p)\n", 0, 0, 0, c"foreign owner: result is not a live W allocation")

void test_foreign_provenance_valid():
	foreign_contract_case(c"import @M unsafe \"@D\"\n\nint main():\n\town int* value = foreign_result()\n\treturn *value - 7\n", c"own int* foreign_result():\n\tint* p = new int\n\t*p = 7\n\treturn cast(own int*, p)\n", 0, 0, 0, 0)

void test_foreign_provenance_resized():
	foreign_contract_case(c"import @M unsafe \"@D\"\n\nint main():\n\town int* value = foreign_result()\n\treturn *value - 7\n", c"own int* foreign_result():\n\tvoid* p = malloc(1)\n\tp = realloc(p, 1, sizeof(int))\n\t*cast(int*, p) = 7\n\treturn cast(own int*, p)\n", 0, 0, 0, 0)

void test_foreign_provenance_indirect():
	foreign_contract_case(c"type Make = fn[]() -> own int*\n\nint invoke(Make* make):\n\town int* value = make()\n\treturn *value\n\nimport @M unsafe \"@D\"\n\nint main():\n\tMake* make = foreign_result\n\treturn invoke(make)\n", c"own int* foreign_result():\n\treturn cast(own int*, 123456)\n", 0, 0, 0, c"foreign owner: result is not a live W allocation")

void test_foreign_contract_changed_module():
	foreign_contract_case(c"import @M unsafe \"@D\"\n\nint main():\n\town ForeignHandle* h = foreign_handle_new(1)\n\treturn 0\n", c"# Audited nominal foreign handle with explicit cleanup and threading rules.\nimport lib.safe_foreign_owner\n\n\nstruct ForeignHandle:\n\tint secret\n\tint* raw\n\n\nint foreign_handle_drops\n\n\nvoid __w_foreign_drop_ForeignHandle(ForeignHandle* value):\n\tforeign_handle_drops += 1\n\tfree(value.raw)\n\tfree(value)\n\n\n# Audited assertions: exclusive transfer and concurrent shared reads are safe.\nvoid __w_foreign_send_ForeignHandle(ForeignHandle* value):\n\tpass\n\n\nvoid __w_foreign_sync_ForeignHandle(ForeignHandle* value):\n\tpass\n\n\nown ForeignHandle* foreign_handle_new(int value):\n\tForeignHandle* handle = new ForeignHandle\n\thandle.raw = new int\n\t*handle.raw = value\n\treturn cast(own ForeignHandle*, handle)\n\n\nint foreign_handle_read(ref ForeignHandle* value):\n\treturn *value.raw\n\n\nvoid foreign_handle_write(refmut ForeignHandle* value, int number):\n\t*value.raw = number\n\n\nint foreign_handle_drop_count():\n\treturn foreign_handle_drops\n", 1, c"safe: audited module differs from its attestation")

void test_foreign_contract_shadowed_module():
	foreign_contract_case(c"import @M unsafe \"@D\"\n\nint main():\n\town ForeignHandle* h = foreign_handle_new(1)\n\treturn 0\n", c"# Audited nominal foreign handle with explicit cleanup and threading rules.\nimport lib.safe_foreign_owner\n\n\nstruct ForeignHandle:\n\tint secret\n\tint* raw\n\n\nint foreign_handle_drops\n\n\nvoid __w_foreign_drop_ForeignHandle(ForeignHandle* value):\n\tforeign_handle_drops += 1\n\tfree(value.raw)\n\tfree(value)\n\n\n# Audited assertions: exclusive transfer and concurrent shared reads are safe.\nvoid __w_foreign_send_ForeignHandle(ForeignHandle* value):\n\tpass\n\n\nvoid __w_foreign_sync_ForeignHandle(ForeignHandle* value):\n\tpass\n\n\nown ForeignHandle* foreign_handle_new(int value):\n\tForeignHandle* handle = new ForeignHandle\n\thandle.raw = new int\n\t*handle.raw = value\n\treturn cast(own ForeignHandle*, handle)\n\n\nint foreign_handle_read(ref ForeignHandle* value):\n\treturn *value.raw\n\n\nvoid foreign_handle_write(refmut ForeignHandle* value, int number):\n\t*value.raw = number\n\n\nint foreign_handle_drop_count():\n\treturn foreign_handle_drops\n", 2, c"safe: audited module differs from its attestation")

void test_foreign_contract_alias():
	foreign_contract_case(c"import @M as handles unsafe \"@D\"\n\nint main():\n\town ForeignHandle* h = handles.foreign_handle_new(7)\n\treturn handles.foreign_handle_read(h) - 7\n", c"# Audited nominal foreign handle with explicit cleanup and threading rules.\nimport lib.safe_foreign_owner\n\n\nstruct ForeignHandle:\n\tint secret\n\tint* raw\n\n\nint foreign_handle_drops\n\n\nvoid __w_foreign_drop_ForeignHandle(ForeignHandle* value):\n\tforeign_handle_drops += 1\n\tfree(value.raw)\n\tfree(value)\n\n\n# Audited assertions: exclusive transfer and concurrent shared reads are safe.\nvoid __w_foreign_send_ForeignHandle(ForeignHandle* value):\n\tpass\n\n\nvoid __w_foreign_sync_ForeignHandle(ForeignHandle* value):\n\tpass\n\n\nown ForeignHandle* foreign_handle_new(int value):\n\tForeignHandle* handle = new ForeignHandle\n\thandle.raw = new int\n\t*handle.raw = value\n\treturn cast(own ForeignHandle*, handle)\n\n\nint foreign_handle_read(ref ForeignHandle* value):\n\treturn *value.raw\n\n\nvoid foreign_handle_write(refmut ForeignHandle* value, int number):\n\t*value.raw = number\n\n\nint foreign_handle_drop_count():\n\treturn foreign_handle_drops\n", 0, 0)

void test_foreign_contract_mutable_conflict():
	foreign_contract_case(c"import @M unsafe \"@D\"\n\nint main():\n\town ForeignHandle* h = foreign_handle_new(1)\n\tref ForeignHandle* view = h\n\tforeign_handle_write(h, 2)\n\treturn foreign_handle_read(view)\n", c"# Audited nominal foreign handle with explicit cleanup and threading rules.\nimport lib.safe_foreign_owner\n\n\nstruct ForeignHandle:\n\tint secret\n\tint* raw\n\n\nint foreign_handle_drops\n\n\nvoid __w_foreign_drop_ForeignHandle(ForeignHandle* value):\n\tforeign_handle_drops += 1\n\tfree(value.raw)\n\tfree(value)\n\n\n# Audited assertions: exclusive transfer and concurrent shared reads are safe.\nvoid __w_foreign_send_ForeignHandle(ForeignHandle* value):\n\tpass\n\n\nvoid __w_foreign_sync_ForeignHandle(ForeignHandle* value):\n\tpass\n\n\nown ForeignHandle* foreign_handle_new(int value):\n\tForeignHandle* handle = new ForeignHandle\n\thandle.raw = new int\n\t*handle.raw = value\n\treturn cast(own ForeignHandle*, handle)\n\n\nint foreign_handle_read(ref ForeignHandle* value):\n\treturn *value.raw\n\n\nvoid foreign_handle_write(refmut ForeignHandle* value, int number):\n\t*value.raw = number\n\n\nint foreign_handle_drop_count():\n\treturn foreign_handle_drops\n", 0, c"safe: conflicting access while a borrow is live")

void test_foreign_contract_unaudited_hook():
	foreign_contract_case(c"import @M\n\nint main():\n\town ForeignHandle* h = foreign_handle_new(1)\n\treturn 0\n", c"# Audited nominal foreign handle with explicit cleanup and threading rules.\nimport lib.safe_foreign_owner\n\n\nstruct ForeignHandle:\n\tint secret\n\tint* raw\n\n\nint foreign_handle_drops\n\n\nvoid __w_foreign_drop_ForeignHandle(ForeignHandle* value):\n\tforeign_handle_drops += 1\n\tfree(value.raw)\n\tfree(value)\n\n\n# Audited assertions: exclusive transfer and concurrent shared reads are safe.\nvoid __w_foreign_send_ForeignHandle(ForeignHandle* value):\n\tpass\n\n\nvoid __w_foreign_sync_ForeignHandle(ForeignHandle* value):\n\tpass\n\n\nown ForeignHandle* foreign_handle_new(int value):\n\tForeignHandle* handle = new ForeignHandle\n\thandle.raw = new int\n\t*handle.raw = value\n\treturn cast(own ForeignHandle*, handle)\n\n\nint foreign_handle_read(ref ForeignHandle* value):\n\treturn *value.raw\n\n\nvoid foreign_handle_write(refmut ForeignHandle* value, int number):\n\t*value.raw = number\n\n\nint foreign_handle_drop_count():\n\treturn foreign_handle_drops\n", 0, c"safe: unsupported type or reference-bearing aggregate", c"safe: global storage is not supported")

void test_foreign_contract_plain_field():
	foreign_contract_case(c"import @M unsafe \"@D\"\n\nint main():\n\town Secret* secret = secret_new()\n\treturn secret.value\n", c"struct Secret:\n\tint value\n\nvoid __w_foreign_drop_Secret(Secret* value):\n\tfree(value)\n\nown Secret* secret_new():\n\treturn cast(own Secret*, new Secret(7))\n", 0, c"safe: opaque collection metadata is not accessible")

void test_foreign_contract_plain_copy():
	foreign_contract_case(c"import @M unsafe \"@D\"\n\nint main():\n\town Secret* secret = secret_new()\n\tSecret copied = *secret\n\treturn 0\n", c"struct Secret:\n\tint value\n\nvoid __w_foreign_drop_Secret(Secret* value):\n\tfree(value)\n\nown Secret* secret_new():\n\treturn cast(own Secret*, new Secret(7))\n", 0, c"safe: unsupported type or reference-bearing aggregate")

void test_foreign_provenance_generic_0():
	foreign_contract_case(c"import @M unsafe \"@D\"\n\nint main():\n\town int* result = foreign_result(1)\n\treturn *result\n", c"own T* foreign_result[T](T ignored):\n\treturn cast(own T*, 123456)\n", 0, 0, 0, c"foreign owner: result is not a live W allocation")

void test_foreign_provenance_generic_1():
	foreign_contract_case(c"import @M unsafe \"@D\"\n\nint main():\n\town int* result = foreign_result[int](1)\n\treturn *result\n", c"own T* foreign_result[T](T ignored):\n\treturn cast(own T*, 123456)\n", 0, 0, 0, c"foreign owner: result is not a live W allocation")

void test_foreign_provenance_opaque_0():
	foreign_contract_case(c"import @M unsafe \"@D\"\n\nint main():\n\town ForeignNull* result = foreign_result()\n\treturn 0\n", c"struct ForeignNull:\n\tint value\n\nvoid __w_foreign_drop_ForeignNull(ForeignNull* value):\n\tpass\n\nown ForeignNull* foreign_result():\n\treturn cast(own ForeignNull*, 0)\n", 0, 0, 0, c"foreign owner: non-null result is null")

void test_foreign_provenance_opaque_1():
	foreign_contract_case(c"import @M unsafe \"@D\"\n\nint main():\n\town ForeignNull* result = foreign_result()\n\treturn 0\n", c"struct ForeignNull:\n\tint value\n\nvoid __w_foreign_drop_ForeignNull(ForeignNull* value):\n\tpass\n\nown ForeignNull* foreign_result():\n\treturn cast(own ForeignNull*, 1)\n", 0, 0, 0, c"foreign owner: result is misaligned")

void test_foreign_contract_wrapped_thread():
	foreign_contract_case(c"import @M unsafe \"@D\"\n\nimport lib.safe_thread\n\nstruct Job:\n\town WForeign[ThreadCounter]* counter\n\ntype Run = fn[](own Job*) -> int\n\nint run(own Job* job):\n\treturn read_counter(job.counter)\n\nint main():\n\toptown WForeign[ThreadCounter]* handle = make_counter(7)\n\tif (!handle): return 1\n\town WForeign[ThreadCounter]* held = handle\n\tRun* work = run\n\toptown WSafeThread* thread = safe_thread_spawn(work, new Job(held))\n\tif (!thread): return 2\n\town WSafeThread* joined = thread\n\treturn safe_thread_join(joined) - 7\n", c"import lib.safe_foreign_owner\n\nstruct ThreadCounter:\n\tint value\n\nvoid __w_foreign_send_ThreadCounter(ThreadCounter* value):\n\tpass\n\nvoid __w_foreign_sync_ThreadCounter(ThreadCounter* value):\n\tpass\n\nvoid counter_drop(void* value):\n\tfree(value)\n\noptown WForeign[ThreadCounter]* make_counter(int value):\n\tThreadCounter* raw = new ThreadCounter(value)\n\treturn foreign_adopt[ThreadCounter](raw, cast(WForeignRelease*, counter_drop))\n\nint read_counter(ref WForeign[ThreadCounter]* value):\n\treturn foreign_raw[ThreadCounter](value).value\n", 0, 0)
