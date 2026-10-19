# wbuild: binary=android_executor_signal tag=tests
# Device regression; ANDROID_SERIAL is honored by adb.
import tools.host_tools
import lib.str

char* aes_remote
int aes_parent
process* aes_runner

process_result* aes_adb(list[char*] args, int check = 1):
	list[char*] command = ht_argv(c"adb")
	for char* arg in args: command.push(arg)
	process_result* result = ht_run(command, 0, 0, 20000)
	if (check): ht_success(result)
	return result

process_result* aes_shell(char* command, int check = 1):
	return aes_adb(ht_argv(c"shell", command), check)

void aes_cleanup():
	if (aes_remote == 0): return
	print2(aes_shell(strjoin(c"cat ", strjoin(aes_remote, c"/run.out")), 0).stdout_text)
	if (aes_runner != 0 && process_try_wait(aes_runner) == process_status_running):
		if (aes_parent != 0): aes_shell(strjoin(c"kill -TERM ", itoa(aes_parent)), 0)
		process_wait_or_kill(aes_runner, 5000)
	aes_shell(strjoin(c"rm -rf ", ht_quote(aes_remote)), 0)

int aes_decimal(char* value):
	if (value[0] == 0): return 0
	for i in range(strlen(value)):
		if (value[i] < '0' || value[i] > '9'): return 0
	return atoi(value) > 0

int main(int argc, int argv):
	args_init(argc, argv)
	ht_require(argc == 2, c"usage: android_executor_signal <android-wexec>")
	char* local = ht_temp()
	aes_remote = strjoin(c"/data/local/tmp/", path_basename(local))
	ht_on_cleanup = aes_cleanup
	char* manifest = c"{\"dirs\":[\"bin\"],\"targets\":[{\"name\":\"hang\",\"steps\":[{\"cmd\":[\"/system/bin/sh\",\"-c\",\"sleep 600 & child=$!; echo $child > child.pid; wait\"],\"timeout_ms\":0}]}]}"
	char* path = path_join(local, c"manifest.json")
	ht_write(path, manifest, strlen(manifest))
	aes_shell(strjoin(c"mkdir -p ", path_join(aes_remote, c"bin")))
	aes_adb(ht_argv(c"push", ht_resolve(args_get(1)), path_join(aes_remote, c"wexec")))
	aes_adb(ht_argv(c"push", path, path_join(aes_remote, c"manifest.json")))
	aes_shell(strjoin(c"chmod 755 ", path_join(aes_remote, c"wexec")))
	char* machine = strip(aes_shell(c"uname -m").stdout_text)
	char* program = c"./wexec"
	if (strcmp(machine, c"aarch64") != 0 && strcmp(machine, c"arm64") != 0): program = strjoin(c"/system/bin/ndk_translation_program_runner_binfmt_misc_arm64 ", strjoin(path_join(aes_remote, c"wexec "), path_join(aes_remote, c"wexec")))
	char* command = strjoin(strjoin(c"cd ", aes_remote), strjoin(c"; ", strjoin(program, c" -j 1 -f manifest.json hang >run.out 2>&1; result=$?; echo $result >status.out")))
	spawn_options* options = spawn_options_new()
	options.new_group = 1
	aes_runner = ht_spawn(ht_argv(c"adb", c"shell", command), options)
	int deadline = process_monotonic_ms() + 20000
	int child = 0
	while (process_monotonic_ms() < deadline):
		list[char*] values = split(aes_shell(strjoin(strjoin(c"cd ", aes_remote), c"; cat bin/.wexec_lock; echo; cat child.pid"), 0).stdout_text)
		if (values.length > 0 && aes_decimal(values[0])): aes_parent = atoi(values[0])
		if (values.length == 2 && aes_decimal(values[0]) && aes_decimal(values[1])):
			child = atoi(values[1])
			break
		ht_require(process_try_wait(aes_runner) == process_status_running, c"executor exited before starting child")
		process_sleep_ms(100)
	ht_require(child != 0, c"executor did not start hanging child")
	aes_shell(strjoin(c"kill -TERM ", itoa(aes_parent)))
	ht_require(process_wait_or_kill(aes_runner, 15000) == 0, c"adb runner failed or timed out")
	ht_require(strcmp(strip(aes_shell(strjoin(c"cat ", path_join(aes_remote, c"status.out"))).stdout_text), c"143") == 0, c"SIGTERM exit status must be 143")
	ht_require(aes_shell(strjoin(c"test ! -e ", path_join(aes_remote, c"bin/.wexec_lock")), 0).status == 0, c"lock remained")
	deadline = process_monotonic_ms() + 3000
	while (1):
		process_result* stat = aes_shell(strjoin(strjoin(c"cat /proc/", itoa(child)), c"/stat"), 0)
		if (stat.status != 0 || contains(stat.stdout_text, c") Z ")): break
		ht_require(process_monotonic_ms() < deadline, c"step child survived")
		process_sleep_ms(50)
	ht_cleanup()
	println(c"Android executor SIGTERM: exit 143, child killed, lock released")
	return 0
