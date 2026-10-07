# wbuild: target=wvm_debug_script_test tag=tests dep=wv2 dep=wvm_debug dep=wvm_debug_fixture dep=wdbg
# wbuild: step="bin/wv2 x64 tests/wvm_debug_script_test.w -o bin/wvm_debug_script_test"
# wbuild: step="bin/wvm_debug_script_test" timeout=30000
import lib.testing
import lib.process
import lib.kvm
import lib.ci_skip


int vmdbg_test_available():
	int fd = kvm_open_system()
	if (fd < 0):
		test_skip_kvm(c"SKIP: KVM unavailable for scripted guest debugger")
		return 0
	close(fd)
	return 1


process_result* vmdbg_test_run(int wrapper, char* mode, char* commands):
	char** args = strv_new(4)
	char* program = c"bin/wvm_debug"
	if (wrapper): program = c"bin/wdbg"
	int at = 0
	strv_set(args, at, program)
	at = at + 1
	if (wrapper):
		strv_set(args, at, c"vm")
		at = at + 1
	strv_set(args, at, c"bin/wvm_debug_fixture")
	strv_set(args, at + 1, mode)
	process_result* result = process_run(program, args, 0, commands, 10000)
	free(cast(void*, args))
	asserts(c"guest debugger launched", result != 0)
	asserts(c"guest debugger terminates", result.status != process_status_timeout)
	return result


void test_scripted_guest_break_step_memory_and_wrapper():
	if (vmdbg_test_available() == 0): return
	char* script = c"regs\nread $stack 4\nwrite $stack 01020304\nread $stack 4\nbreak vm_debug_target\ncontinue\nregs\nstep\nthreads\nthread 1\ndelete 0\ncontinue\nquit\n"
	for wrapper in range(2):
		process_result* result = vmdbg_test_run(wrapper, c"normal", script)
		if (result.status != 0): println(result.stdout_text)
		assert_equal(0, result.status)
		asserts(c"registers visible", assert_has(result.stdout_text, c"rip=0x"))
		asserts(c"checked memory write visible", assert_has(result.stdout_text, c"memory=01020304"))
		asserts(c"hardware breakpoint installed", assert_has(result.stdout_text, c"breakpoint 0"))
		asserts(c"thread selected", assert_has(result.stdout_text, c"selected thread 1"))
		asserts(c"guest completed", assert_has(result.stdout_text, c"exited status=0"))
		process_result_free(result)


void test_scripted_guest_thread_selection_and_fault():
	if (vmdbg_test_available() == 0): return
	process_result* result = vmdbg_test_run(0, c"thread", c"break vm_debug_target\ncontinue\nthreads\nthread 2\nregs\nstep\ndelete 0\ncontinue\nquit\n")
	if (result.status != 0): println(result.stdout_text)
	assert_equal(0, result.status)
	asserts(c"guest child selected", assert_has(result.stdout_text, c"selected thread 2"))
	process_result_free(result)
	result = vmdbg_test_run(0, c"fault", c"continue\nstatus\nquit\n")
	assert_equal(139, result.status)
	asserts(c"guest fault reported", assert_has(result.stdout_text, c"fault rip=0x"))
	asserts(c"guest fault symbolized", assert_has(result.stdout_text, c"main"))
	process_result_free(result)


void test_scripted_guest_rejects_invalid_memory_and_large_input():
	if (vmdbg_test_available() == 0): return
	process_result* result = vmdbg_test_run(0, c"normal", c"read 4096 4\nwrite $entry 00\nread 0xffffffffffffffff 1\nquit\n")
	assert_equal(2, result.status)
	asserts(c"invalid memory rejected", assert_has(result.stdout_text, c"error: invalid command"))
	process_result_free(result)
	char* huge = cast(char*, malloc(4099))
	for i in range(4097): huge[i] = 'x'
	huge[4097] = 10
	huge[4098] = 0
	result = vmdbg_test_run(0, c"normal", huge)
	assert_equal(2, result.status)
	free(huge)
	process_result_free(result)
