# wbuild: target=wvm_cli_test tag=tests dep=wv2 dep=wvm dep=wvm_fixture
# wbuild: step="bin/wv2 x64 tests/wvm_cli_test.w -o bin/wvm_cli_test"
# wbuild: step="bin/wvm_cli_test" timeout=30000
import lib.testing
import lib.vmm.cell
import lib.process
import lib.str
import lib.ci_skip

process_result* vm_cli_call(char* option, char* path):
	char** args = strv_new(10)
	args[0] = c"bin/wvm"
	args[1] = c"run"
	args[2] = c"--seed"
	args[3] = c"42"
	args[4] = option
	args[5] = path
	args[6] = c"bin/wvm_fixture"
	args[7] = c"smoke"
	args[8] = c"payload"
	process_result* result = process_run(args[0], args, 0, 0, 10000)
	free(cast(void*, args))
	asserts(c"CLI completed", result != 0)
	return result

void test_vm_cli_record_replay_and_limits():
	int fd = kvm_open_system()
	if (fd < 0):
		test_skip_kvm(c"SKIP: KVM unavailable for CLI replay")
		return
	close(fd)
	char* path = c"bin/wvm_cli_test.transcript"
	unlink(path)
	process_result* result = vm_cli_call(c"--record", path)
	assert_equal(0, result.status)
	assert_strings_equal(c"cell smoke OK\n", result.stdout_text)
	process_result_free(result)
	result = vm_cli_call(c"--replay", path)
	assert_equal(0, result.status)
	assert_strings_equal(c"cell smoke OK\n", result.stdout_text)
	process_result_free(result)
	result = vm_cli_call(c"--record", path)
	assert_equal(125, result.status)
	asserts(c"record never overwrites", contains(result.stderr_text, c"path must not exist"))
	process_result_free(result)
	fd = open(path, 1, 0)
	asserts(c"open transcript", fd >= 0)
	assert_equal(1, write(fd, c"!", 1))
	close(fd)
	result = vm_cli_call(c"--replay", path)
	assert_equal(125, result.status)
	asserts(c"replay corruption rejected", contains(result.stderr_text, c"replay"))
	process_result_free(result)
	unlink(path)
	result = vm_cli_call(c"--max-syscalls", c"1")
	assert_equal(125, result.status)
	asserts(c"budget enforced", contains(result.stderr_text, c"syscall limit"))
	process_result_free(result)
	result = vm_cli_call(c"--seed", c"2147483647")
	assert_equal(2, result.status)
	process_result_free(result)
	result = vm_cli_call(c"--max-instructions", c"1")
	assert_equal(125, result.status)
	asserts(c"instruction budget enforced", contains(result.stderr_text, c"instruction limit"))
	process_result_free(result)
