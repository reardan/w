# wbuild: binary=wvm arch=x64
# Local cell runner. Source compilation happens on the host; only the
# resulting static x64 program executes in KVM. No host-exec fallback.
import lib.vmm.cell
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


# Checked, size-bounded read of a regular executable.
char* wvm_read_image(char* path, int* length):
	int fd = open(path, 0, 0)
	if (fd < 0): return 0
	int size = seek(fd, 0, 2)
	if (size < 64 || size > 67108864 || seek(fd, 0, 0) != 0):
		close(fd)
		return 0
	char* image = malloc(size)
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


int main(int argc, int argv):
	char** args = cast(char**, argv)
	if (argc == 2 && strcmp(args[1], c"available") == 0):
		kvm_machine machine
		int available = kvm_create(&machine)
		kvm_destroy(&machine)
		if (available): return 0
		wvm_error(c"Linux x64 KVM is unavailable")
		return 77
	if (argc < 3 || strcmp(args[1], c"run") != 0):
		wvm_error(c"usage: wvm run [--timeout-ms N] <file.w|static-x64-elf> [guest args...]")
		return 2
	int at = 2
	int timeout = 5000
	if (strcmp(args[at], c"--timeout-ms") == 0):
		if (argc < 5):
			wvm_error(c"--timeout-ms needs a value and an image")
			return 2
		timeout = wvm_timeout(args[at + 1])
		at = at + 2
		if (timeout < 0):
			wvm_error(c"timeout must be 1..600000 ms")
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
	int loaded = cell_elf_load(cell, image, length)
	free(image)
	if (loaded): loaded = cell_stack(cell, argc - at, args + at * __word_size__)
	if (loaded): cell_run(cell, timeout)
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
	cell_free(cell)
	return status
