# wbuild: binary=wvm arch=x64
# Local cell runner. Source compilation happens on the host; only the
# resulting static x64 program executes in KVM. No host-exec fallback.
import tools.__arch__.wvm_platform
import lib.vmm.cell
import lib.vmm.box
import lib.vmm.workspace
import lib.vmm.faults
import lib.process
import lib.file
import lib.str


void wvm_error(char* message):
	write(2, c"wvm: ", 5)
	write(2, message, strlen(message))
	write(2, c"\n", 1)


int wvm_timeout(char* text):
	int value = 0
	int i = 0
	while (text[i]):
		if (text[i] < '0' || text[i] > '9' || value > 600000): return -1
		value = value * 10 + text[i] - '0'
		i = i + 1
	if (value < 1 || value > 600000): return -1
	return value


int wvm_bounded_number(char* text, int maximum):
	int value = 0
	if (text[0] == 0): return -1
	int at = 0
	while (text[at]):
		int digit = cast(int, text[at]) - '0'
		if (digit < 0 || digit > 9 || value > (maximum - digit) / 10): return -1
		value = value * 10 + digit
		at = at + 1
	return value


# Checked, size-bounded read of a regular executable.
char* wvm_read_image(char* path, int* length):
	int fd = open(path, 2048, 0) # O_NONBLOCK: reject FIFOs without waiting for a writer
	if (fd < 0): return 0
	int size = cell_fs_size(fd) # descriptor-based fstat rejects non-regular inputs
	if (size < 64 || size > 67108864 || seek(fd, 0, 0) != 0):
		close(fd)
		return 0
	char* image = cast(char*, malloc(size))
	int have = 0
	while (have < size):
		int n = read(fd, image + have, size - have)
		if (n == -4): continue
		if (n <= 0):
			free(image)
			close(fd)
			return 0
		have = have + n
	close(fd)
	*length = size
	return image


int wvm_box(int argc, char** args):
	vm_box_options* options = box_options_new()
	int at = 2
	int valid = 1
	char* workspace_source = 0
	int workspace_mb = 64
	char* cwd = 0
	char** command = 0
	while (at < argc && valid):
		char* option = args[at]
		at = at + 1
		if (strcmp(option, c"--exec") == 0):
			if (at >= argc): valid = 0
			else: command = args + at * __word_size__
			break
		if (strcmp(option, c"--network-restricted") == 0): options.network = 2
		else if (strcmp(option, c"--network") == 0): options.network = 1
		else if (strcmp(option, c"--fs-write") == 0): options.fs_write = 1
		else if (at >= argc): valid = 0
		else:
			char* value = args[at]
			at = at + 1
			if (strcmp(option, c"--kernel") == 0): options.kernel = value
			else if (strcmp(option, c"--initrd") == 0): options.initrd = value
			else if (strcmp(option, c"--append") == 0): options.command_line = value
			else if (strcmp(option, c"--fs-root") == 0): options.fs_root = value
			else if (strcmp(option, c"--workspace") == 0): workspace_source = value
			else if (strcmp(option, c"--workspace-mb") == 0): workspace_mb = wvm_timeout(value)
			else if (strcmp(option, c"--cwd") == 0): cwd = value
			else if (strcmp(option, c"--cpus") == 0): options.cpus = wvm_timeout(value)
			else if (strcmp(option, c"--memory-mb") == 0): options.memory_mb = wvm_timeout(value)
			else if (strcmp(option, c"--timeout-ms") == 0): options.timeout_ms = wvm_timeout(value)
			else: valid = 0
	if (workspace_source != 0 && (options.fs_root != 0 || options.fs_write)): valid = 0
	if (cwd != 0 && command == 0): valid = 0
	if (workspace_source != 0 && command == 0): valid = 0
	if (workspace_mb < 1 || workspace_mb > 1024): valid = 0
	if (valid == 0 || box_options_valid(options) == 0):
		wvm_error(c"usage: wvm box --kernel FILE --initrd FILE [--append TEXT] [--cpus 1..64] [--memory-mb 64..32768] [--timeout-ms N] [--fs-root DIR [--fs-write] | --workspace DIR [--workspace-mb N]] [--network | --network-restricted] [--cwd DIR] [--exec /COMMAND args...]")
		free(options)
		return 2
	vm_workspace* workspace = 0
	if (workspace_source != 0):
		workspace = workspace_create(workspace_source, 1073741824, 100000, 60000)
		if (workspace == 0):
			wvm_error(c"workspace preparation failed (1 GiB, 100000 entries, 60s; regular files/directories only)")
			free(options)
			return 125
		options.fs_root = workspace.path
		options.workspace_mb = workspace_mb
	int status = 125
	if (command == 0): status = box_run(options)
	else:
		vm_box_session* session = box_session_open(options)
		if (session != 0):
			process_result* result = box_session_exec(session, command, cwd, options.timeout_ms, box_channel_max_output)
			if (result != 0):
				status = result.status
				io_result written
				if (io_write_all(1, result.stdout_text, result.stdout_length, &written) != IO_OK): status = 125
				if (io_write_all(2, result.stderr_text, result.stderr_length, &written) != IO_OK): status = 125
				if (status == process_status_timeout): status = 124
				if (status == box_status_output_limit): wvm_error(c"guest output limit exceeded")
				if (status < 0): status = 125
				process_result_free(result)
			box_session_close(session)
	if (workspace != 0):
		if (workspace_destroy(workspace) != 0):
			wvm_error(c"workspace cleanup failed")
			status = 125
	free(options)
	if (status == 124): wvm_error(c"Linux guest deadline exceeded")
	if (status == 125): wvm_error(c"Linux guest setup, command channel, or execution failed; requires /dev/kvm, QEMU and compatible image")
	return status


# A null cell validates the endpoint before checking host KVM access.
int wvm_net_option(vm_cell* cell, char* endpoint):
	int split = 0
	while (endpoint[split] != 0 && endpoint[split] != ':'): split = split + 1
	if (split == 0 || split > 15 || endpoint[split] != ':'): return 0
	char[16] address
	mem_copy[char](&address[0], endpoint, split)
	address[split] = 0
	int port = wvm_timeout(endpoint + split + 1)
	if (port < 1 || port > 65535): return 0
	if (cell_net_ipv4(&address[0]) < 0): return 0
	if (cell == 0): return 1
	return cell_net_allow(cell, &address[0], port)


int main(int argc, int argv):
	char** args = cast(char**, argv)
	int platform_status = wvm_platform_main(argc, args)
	if (platform_status >= 0): return platform_status
	if (argc >= 2 && strcmp(args[1], c"box") == 0): return wvm_box(argc, args)
	if (argc == 2 && strcmp(args[1], c"available") == 0):
		kvm_machine machine
		int available = kvm_create(&machine)
		kvm_destroy(&machine)
		if (available): return 0
		wvm_error(c"Linux x64 KVM is unavailable")
		return 77
	if (argc < 3 || strcmp(args[1], c"run") != 0):
		wvm_error(c"usage: wvm run [--timeout-ms N] [--fs-root DIR [--fs-write|--fs-private]] [--net-allow IPV4:PORT] [--max-threads N] [--max-syscalls N] [--max-instructions N] [--seed N [--record FILE|--replay FILE]] <file.w|static-x64-elf> [guest args...]")
		return 2
	int at = 2
	int timeout = 5000
	char* fs_root = 0
	int fs_write = 0
	int fs_private = 0
	int seed = -1
	int seeded = 0
	int max_syscalls = 1000000
	int max_instructions = 0
	int threads_explicit = 0
	char* record_path = 0
	char* replay_path = 0
	int max_threads = 16
	int policy_end = 2
	while (at < argc && args[at][0] == '-'):
		char* option = args[at]
		at = at + 1
		if (strcmp(option, c"--") == 0): break
		if (strcmp(option, c"--fs-write") == 0):
			fs_write = 1
			continue
		if (strcmp(option, c"--fs-private") == 0):
			fs_private = 1
			continue
		if (at >= argc):
			wvm_error(c"missing option value")
			return 2
		char* value = args[at]
		at = at + 1
		if (strcmp(option, c"--timeout-ms") == 0): timeout = wvm_timeout(value)
		else if (strcmp(option, c"--fs-root") == 0): fs_root = value
		else if (strcmp(option, c"--max-threads") == 0):
			threads_explicit = 1
			max_threads = wvm_timeout(value)
		else if (strcmp(option, c"--max-syscalls") == 0): max_syscalls = wvm_bounded_number(value, 1000000000)
		else if (strcmp(option, c"--max-instructions") == 0): max_instructions = wvm_bounded_number(value, 1000000000)
		else if (strcmp(option, c"--seed") == 0):
			seeded = 1
			seed = wvm_bounded_number(value, 2147483646)
		else if (strcmp(option, c"--record") == 0): record_path = value
		else if (strcmp(option, c"--replay") == 0): replay_path = value
		else if (strcmp(option, c"--net-allow") == 0):
			if (wvm_net_option(0, value) == 0):
				wvm_error(c"invalid --net-allow endpoint; expected IPV4:PORT")
				return 125
		else:
			wvm_error(c"unknown run option")
			return 2
	policy_end = at
	if (max_instructions < 0 || (max_instructions > 0 && threads_explicit && max_threads != 1)):
		wvm_error(c"instruction limit must be 0..1000000000 and requires one thread")
		return 2
	if (max_instructions > 0): max_threads = 1
	if (at >= argc || timeout < 1 || max_threads < 1 || max_threads > 64 || max_syscalls < 1 || ((fs_write || fs_private) && fs_root == 0) || (fs_write && fs_private) || (seeded && seed < 0) || ((record_path != 0 || replay_path != 0) && seeded == 0)):
		wvm_error(c"missing image or invalid policy: timeout 1..600000, threads 1..64, syscalls 1..1000000000, seed 0..2147483646; --fs-write requires --fs-root; --fs-private requires --fs-root and excludes --fs-write; record/replay require --seed")
		return 2
	int probe = kvm_open_system()
	if (probe < 0):
		wvm_error(c"cannot open /dev/kvm; Linux x64 KVM access is required")
		return 125
	close(probe)
	char* path = args[at]
	string_builder* scratch = 0
	char* compiled = 0
	int n = strlen(path)
	if (n >= 2 && strcmp(path + n - 2, c".w") == 0):
		scratch = string_new()
		string_append(scratch, c"bin/wvm_")
		string_append_int(scratch, getpid())
		if (mkdir(scratch.data, 448) < 0):
			wvm_error(c"cannot create compilation directory under bin/")
			string_free(scratch)
			return 125
		compiled = strjoin(scratch.data, c"/guest")
		char** command = strv_new(5)
		strv_set(command, 0, c"bin/wv2")
		strv_set(command, 1, c"x64")
		strv_set(command, 2, path)
		strv_set(command, 3, c"-o")
		strv_set(command, 4, compiled)
		process_result* result = process_run(command[0], command, 0, 0, 60000)
		free(cast(void*, command))
		int ok = result != 0
		if (ok): ok = result.status == 0
		if (ok == 0):
			if (result != 0): write(2, result.stderr_text, result.stderr_length)
			wvm_error(c"guest compilation failed")
			if (result != 0): process_result_free(result)
			unlink(compiled)
			rmdir(scratch.data)
			free(compiled)
			string_free(scratch)
			return 125
		process_result_free(result)
		path = compiled
	int length = 0
	char* image = wvm_read_image(path, &length)
	if (compiled != 0):
		unlink(compiled)
		rmdir(scratch.data)
		free(compiled)
		string_free(scratch)
	if (image == 0):
		wvm_error(c"cannot read image (requires a regular ELF file up to 64 MiB)")
		return 125
	vm_cell* cell = cell_new()
	if (cell == 0):
		free(image)
		wvm_error(c"cannot allocate guest RAM")
		return 125
	cell.max_threads = max_threads
	cell.max_syscalls = max_syscalls
	cell.max_instructions = max_instructions
	int configured = 1
	if (fs_private): configured = cell_fs_configure_private(cell, fs_root, 67108864, 10000, 60000)
	else if (fs_root != 0): configured = cell_fs_configure(cell, fs_root, fs_write)
	int option_at = 2
	while (option_at < policy_end && configured):
		char* option = args[option_at]
		option_at = option_at + 1
		if (strcmp(option, c"--") == 0): break
		if (strcmp(option, c"--fs-write") == 0 || strcmp(option, c"--fs-private") == 0): continue
		if (strcmp(option, c"--net-allow") == 0):
			configured = wvm_net_option(cell, args[option_at])
			if (configured == 0): cell_fail(cell, c"invalid --net-allow endpoint; expected IPV4:PORT")
		option_at = option_at + 1
	if (configured && seeded): configured = cell_deterministic_configure(cell, seed)
	if (configured && replay_path != 0):
		int replay_length = 0
		char* replay = wvm_read_image(replay_path, &replay_length)
		if (replay == 0): configured = cell_fail(cell, c"cannot read syscall transcript")
		else:
			configured = cell_replay_configure(cell, replay, replay_length)
			free(replay)
	int loaded = 0
	if (configured): loaded = cell_elf_load(cell, image, length)
	if (loaded): loaded = cell_stack(cell, argc - at, args + at * __word_size__)
	if (loaded): cell_run(cell, timeout)
	if (record_path != 0 && cell.started && cell.deterministic):
		int fd = open(record_path, 193, 384) # O_WRONLY|O_CREAT|O_EXCL, private transcript
		io_result result
		int saved = fd >= 0
		if (saved): saved = io_write_all(fd, cell.transcript.data, cell.transcript.length, &result) == IO_OK
		if (fd >= 0): close(fd)
		if (saved == 0):
			if (fd >= 0): unlink(record_path)
			cell_fail(cell, c"cannot create syscall transcript (path must not exist)")
			cell.status = 125
	io_result written
	if (io_write_all(1, cell.output.data, cell.output.length, &written) != IO_OK):
		cell_fail(cell, c"cannot write guest stdout")
		cell.status = 125
	if (io_write_all(2, cell.errors.data, cell.errors.length, &written) != IO_OK):
		cell_fail(cell, c"cannot write guest stderr")
		cell.status = 125
	if (cell.error != 0):
		wvm_error(cell.error)
		if (cell.fault_vector >= 0):
			string_builder* detail = string_new()
			string_append(detail, c"exception vector ")
			string_append_int(detail, cell.fault_vector)
			string_append(detail, c" at guest RIP ")
			string_append(detail, hex(cell.fault_rip))
			char* symbol = cell_fault_symbol(image, length, cell.fault_rip)
			if (symbol[0]):
				string_append(detail, c" in ")
				string_append(detail, symbol)
			free(symbol)
			wvm_error(detail.data)
			string_free(detail)
		else if (cell.exited == 0 && cell.last_exit != 0):
			string_builder* detail = string_new()
			string_append(detail, c"KVM exit reason: ")
			string_append_int(detail, cell.last_exit)
			wvm_error(detail.data)
			string_free(detail)
	if (cell.unsupported_syscall >= 0):
		string_builder* detail = string_new()
		string_append(detail, c"unsupported guest syscall (ENOSYS): ")
		string_append_int(detail, cell.unsupported_syscall)
		wvm_error(detail.data)
		string_free(detail)
	int status = cell.status
	free(image)
	cell_free(cell)
	return status
