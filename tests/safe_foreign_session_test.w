# wbuild: x64 timeout=600000 deps=tests/safe_foreign_contract_module.w deps=tests/safe_foreign_session_fixture.w
# Persistent allocators start recording before the first entry, and reset or
# failed entries retract attestation and allocator-hook declarations together.
import lib.testing
import lib.process
import lib.file
import lib.str
import lib.sha256
import lib.env


char* foreign_session_repl
char* foreign_session_debugger


char* foreign_session_build(int debugger):
	if (debugger && foreign_session_debugger): return foreign_session_debugger
	if ((debugger == 0) && foreign_session_repl): return foreign_session_repl
	char* stem = c"bin/foreign_session_repl"
	char* source = c"repl.w"
	if (debugger):
		stem = c"bin/foreign_session_wdbg"
		source = c"debugger/debugger.w"
	char* binary = strjoin(stem, itoa(__word_size__ * 8))
	char** args = strv_new(6)
	strv_set(args, 0, c"bin/wv2")
	int at = 1
	if (__word_size__ == 8):
		strv_set(args, at, c"x64")
		at += 1
	strv_set(args, at, source)
	strv_set(args, at + 1, c"-o")
	strv_set(args, at + 2, binary)
	process_result* built = process_run(args[0], args, 0, 0, 600000)
	assert1(built != 0)
	if (built.status): println(built.stderr_text)
	assert_equal(0, built.status)
	process_result_free(built)
	free(cast(void*, args))
	if (debugger): foreign_session_debugger = binary
	else: foreign_session_repl = binary
	return binary


char* foreign_session_import():
	char* source = file_read_text(c"tests/safe_foreign_contract_module.w")
	assert1(source != 0)
	char[32] digest
	sha256(source, strlen(source), &digest[0])
	free(source)
	char[65] hex
	char* digits = c"0123456789abcdef"
	for i in range(32):
		int value = digest[i] & 255
		hex[i * 2] = digits[value >> 4]
		hex[i * 2 + 1] = digits[value & 15]
	hex[64] = 0
	return strjoin(strjoin(c"import tests.safe_foreign_contract_module unsafe \"", &hex[0]), c"\"\n")


process_result* foreign_session_run(char* input, int debugger = 0, int guards = 0):
	char** args = strv_new(3)
	strv_set(args, 0, foreign_session_build(debugger))
	if (debugger): strv_set(args, 1, c"tests/safe_foreign_session_fixture.w")
	spawn_options* options = spawn_options_new()
	if (guards): options.env = env_copy_with(env_current(), c"W_DEBUG_ALLOC", c"1")
	process_result* result = process_run(args[0], args, options, input, 300000)
	assert1(result != 0)
	if (result.status):
		println(result.stdout_text)
		println(result.stderr_text)
	assert_equal(0, result.status)
	free(cast(void*, args))
	return result


void test_foreign_session_late_attestation():
	char* input = strjoin(c"own int* pass_owner(own int* value): return value\nown int* before = new int\n*before = 42\n", foreign_session_import())
	input = strjoin(input, c"own int* after = pass_owner(before)\n*after\n:quit\n")
	for guards in range(2):
		process_result* result = foreign_session_run(input, 0, guards)
		assert_contains(result.stdout_text, c"42")
		assert_lacks(result.stderr_text, c"error:")
		assert_lacks(result.stderr_text, c"foreign owner:")
		process_result_free(result)


void test_foreign_session_reset_revokes_trust():
	char* input = strjoin(foreign_session_import(), c":reset\nimport tests.safe_foreign_contract_module\n:quit\n")
	process_result* result = foreign_session_run(input)
	assert_contains(result.stderr_text, c"safe: unsupported type or reference-bearing aggregate")
	process_result_free(result)


void test_foreign_session_failed_import_revokes_trust():
	# Parsing installs the attestation before digest validation fails. The
	# failed entry must not keep that digest attached to the later import.
	char* input = foreign_session_import()
	int digit = index_of(input, c"unsafe \"") + 8
	if (input[digit] == '0'): input[digit] = '1'
	else: input[digit] = '0'
	input = strjoin(input, c"import tests.safe_foreign_contract_module\n:quit\n")
	process_result* result = foreign_session_run(input)
	assert_contains(result.stderr_text, c"audited module differs from its attestation")
	assert_contains(result.stderr_text, c"safe: unsupported type or reference-bearing aggregate")
	process_result_free(result)


void test_foreign_session_reset_clears_thread_hooks():
	char* input = c"import lib.thread\nvoid worker(void* argument): pass\nwthread* worker_thread = thread_spawn(worker, 0)\nthread_join(worker_thread)\n:reset\nif ((malloc_provenance_lock_hook == 0) && (malloc_provenance_unlock_hook == 0)): println(c\"provenance-hooks-cleared\")\nown int* value = new int\n*value = 31\n*value\n:quit\n"
	for guards in range(2):
		process_result* result = foreign_session_run(input, 0, guards)
		assert_contains(result.stdout_text, c"provenance-hooks-cleared")
		assert_contains(result.stdout_text, c"31")
		assert_lacks(result.stderr_text, c"error:")
		process_result_free(result)


void test_foreign_debugger_late_attestation():
	char* input = strjoin(c"c\nrepl\n", foreign_session_import())
	input = strjoin(input, c":end\nc\n")
	for guards in range(2):
		process_result* result = foreign_session_run(input, 1, guards)
		assert_contains(result.stdout_text, c"debuggee main returned 0")
		assert_lacks(result.stderr_text, c"foreign owner:")
		process_result_free(result)
