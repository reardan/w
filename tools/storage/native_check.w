# wbuild: binary=storage_native_check tag=tests
# SIGKILL tests process recovery; it does not simulate a power failure.
import tools.host_tools

process_result* sn_run(char* binary, char* mode, char* prefix, char* trace):
	list[char*] command = new list[char*]
	if (trace != 0):
		command = ht_command(c"strace -qq -o")
		command.push(strjoin(prefix, c".trace"))
		command.push(c"-e")
		command.push(trace)
	command.push(binary)
	command.push(mode)
	command.push(prefix)
	return ht_run(command, 0, 0, 15000)

void sn_case(char* binary, char* directory, int index, char* mode, char* trace):
	char* prefix = path_join(directory, itoa(index))
	ht_success(sn_run(binary, c"init", prefix, 0))
	process_result* result = sn_run(binary, mode, prefix, trace)
	int status = result.status
	ht_require(status == 0 || status == 3 || status == 4 || status == 8 || status == 137, strjoin(c"unexpected recovery fixture status: ", itoa(status)))
	if (trace != 0):
		string_builder* log = ht_read(strjoin(prefix, c".trace"))
		ht_require(!ht_contains(result.stderr_text, c"ptrace"), result.stderr_text)
		if (ht_contains(trace, c"when=1")):
			ht_require(ht_contains(log.data, c"INJECTED") || ht_contains(log.data, c"SIGKILL"), strjoin(c"fault was not injected: ", trace))
			if (!ht_contains(trace, c"error=EINTR")): ht_require(status != 0, c"failure released success")
	ht_success(sn_run(binary, c"verify", prefix, 0))

int main(int argc, int argv):
	args_init(argc, argv)
	ht_require(argc == 2, c"usage: storage_native_check binary")
	char* binary = tempfile_abspath(args_get(1))
	char* directory = ht_temp()
	sn_case(binary, directory, 0, c"advance", 0)
	sn_case(binary, directory, 1, c"compact", 0)
	int count = 2
	if (process_which(c"strace") != 0):
		for char* syscall in ht_command(c"write fsync rename"):
			char* mode = c"compact"
			if (strcmp(syscall, c"write") == 0): mode = c"advance"
			for nth in range(1, 5):
				for char* fault in ht_command(c"error=EIO signal=SIGKILL"):
					char* trace = strjoin(strjoin(strjoin(strjoin(c"inject=", syscall), c":"), fault), strjoin(c":when=", itoa(nth)))
					sn_case(binary, directory, count, mode, trace)
					count = count + 1
		for char* fault in ht_command(c"error=EINTR error=ENOSPC retval=0"):
			sn_case(binary, directory, count, c"advance", strjoin(strjoin(c"inject=write:", fault), c":when=1"))
			count = count + 1
	else: println(c"storage_native_test: strace unavailable; syscall injection skipped")
	ht_cleanup()
	println(strjoin(strjoin(c"storage_native_test: ", itoa(count)), c" independent-process scenarios passed"))
	return 0
