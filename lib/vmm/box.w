# Linux guests use QEMU's microvm machine with hardware KVM acceleration.
# No shell invocation and no software-emulation fallback. Kernel/initramfs
# are caller-supplied artifacts; nothing is downloaded at runtime.
import lib.process
import lib.kvm

struct vm_box_options:
	char* kernel
	char* initrd
	char* command_line
	char* fs_root
	int fs_write
	int network
	int cpus
	int memory_mb
	int timeout_ms


vm_box_options* box_options_new():
	vm_box_options* options = malloc(sizeof(vm_box_options))
	mem_fill[char](cast(char*, options), 0, sizeof(vm_box_options))
	options.cpus = 2
	options.memory_mb = 256
	options.timeout_ms = 30000
	return options


int box_options_valid(vm_box_options* options):
	if (options == 0): return 0
	if (options.kernel == 0 || options.initrd == 0): return 0
	if (options.kernel[0] == 0 || options.initrd[0] == 0): return 0
	if (options.cpus < 1 || options.cpus > 64): return 0
	if (options.memory_mb < 64 || options.memory_mb > 32768): return 0
	if (options.timeout_ms < 1 || options.timeout_ms > 600000): return 0
	if (options.fs_write != 0 && options.fs_root == 0): return 0
	return 1


# QEMU key/value options escape a literal comma by doubling it.
void box_append_path(string_builder* builder, char* path):
	for i in range(strlen(path)):
		string_append_char(builder, path[i])
		if (path[i] == ','): string_append_char(builder, ',')


void box_arg(char** args, int* count, char* value):
	strv_set(args, *count, strjoin(value, c""))
	*count = *count + 1


void box_command_free(char** args):
	if (args == 0): return
	int i = 0
	while (args[i] != 0):
		free(args[i])
		i = i + 1
	free(cast(void*, args))


# Exposed separately so policy/device selection is testable without KVM.
char** box_command(vm_box_options* options, char* qemu):
	if (box_options_valid(options) == 0 || qemu == 0): return 0
	char** args = strv_new(48)
	int count = 0
	box_arg(args, &count, qemu)
	box_arg(args, &count, c"-machine")
	box_arg(args, &count, c"microvm,accel=kvm")
	box_arg(args, &count, c"-cpu")
	box_arg(args, &count, c"host")
	box_arg(args, &count, c"-m")
	string_builder* value = string_new()
	string_append_int(value, options.memory_mb)
	box_arg(args, &count, value.data)
	string_clear(value)
	string_append_int(value, options.cpus)
	box_arg(args, &count, c"-smp")
	box_arg(args, &count, value.data)
	box_arg(args, &count, c"-nodefaults")
	box_arg(args, &count, c"-no-user-config")
	box_arg(args, &count, c"-display")
	box_arg(args, &count, c"none")
	box_arg(args, &count, c"-monitor")
	box_arg(args, &count, c"none")
	box_arg(args, &count, c"-serial")
	box_arg(args, &count, c"stdio")
	box_arg(args, &count, c"-no-reboot")
	box_arg(args, &count, c"-kernel")
	box_arg(args, &count, options.kernel)
	box_arg(args, &count, c"-initrd")
	box_arg(args, &count, options.initrd)
	box_arg(args, &count, c"-append")
	string_clear(value)
	string_append(value, c"console=ttyS0 reboot=t panic=-1")
	if (options.command_line != 0):
		string_append_char(value, ' ')
		string_append(value, options.command_line)
	box_arg(args, &count, value.data)
	if (options.fs_root != 0):
		string_clear(value)
		string_append(value, c"local,id=work,security_model=mapped-xattr,multidevs=forbid,path=")
		box_append_path(value, options.fs_root)
		if (options.fs_write == 0): string_append(value, c",readonly=on")
		box_arg(args, &count, c"-fsdev")
		box_arg(args, &count, value.data)
		box_arg(args, &count, c"-device")
		box_arg(args, &count, c"virtio-9p-device,fsdev=work,mount_tag=work")
	if (options.network):
		box_arg(args, &count, c"-netdev")
		box_arg(args, &count, c"user,id=net")
		box_arg(args, &count, c"-device")
		box_arg(args, &count, c"virtio-net-device,netdev=net")
	string_free(value)
	return args


# Console streams directly to the caller's stdio, avoiding unbounded host
# capture. Status is QEMU's status, NOT an init command's exit code.
int box_run(vm_box_options* options):
	if (box_options_valid(options) == 0): return 2
	int probe = kvm_open_system()
	if (probe < 0): return 125
	close(probe)
	char* qemu = process_which(c"qemu-system-x86_64")
	if (qemu == 0): return 125
	char** args = box_command(options, qemu)
	# QEMU's stdio backend makes an attached terminal raw. SIGKILL on a
	# deadline bypasses its cleanup, so preserve the Linux termios here.
	char[64] terminal
	int restore_terminal = syscall(16, 0, 21505, cast(int, &terminal[0])) == 0
	process* child = process_spawn(qemu, args, 0)
	box_command_free(args)
	free(qemu)
	if (child == 0): return 125
	int status = process_wait_or_kill(child, options.timeout_ms)
	process_free(child)
	if (restore_terminal): syscall(16, 0, 21506, cast(int, &terminal[0]))
	if (status == process_status_timeout): return 124
	if (status < 0): return 125
	return status
