# wbuild: binary=wvm_init arch=x64
# Small Linux PID 1 for supplied initramfs images. The kernel passes
# arguments following '--' to /init; default command is /bin/sh.
import lib.process
import lib.file
import lib.vmm.guest_agent


int main(int argc, int argv):
	if (getpid() != 1):
		println(c"wvm-init: must run as guest PID 1")
		return 125
	mkdir(c"/proc", 493)
	mkdir(c"/sys", 493)
	mkdir(c"/dev", 493)
	syscall7(165, cast(int, c"proc"), cast(int, c"/proc"), cast(int, c"proc"), 14, 0, 0)
	syscall7(165, cast(int, c"sysfs"), cast(int, c"/sys"), cast(int, c"sysfs"), 14, 0, 0)
	syscall7(165, cast(int, c"devtmpfs"), cast(int, c"/dev"), cast(int, c"devtmpfs"), 2, 0, 0)
	char** args = cast(char**, argv)
	if (argc > 1 && strcmp(args[1], c"--agent") == 0):
		# Guest commands share uid 0; protect the privileged service from
		# ptrace and /proc/1/mem after their capability drop.
		if (syscall7(157, 4, 0, 0, 0, 0, 0) < 0): return 125
		int mount_ok = 1
		int workspace_mb = 0
		int has_work = 0
		for i in range(2, argc):
			if (strcmp(args[i], c"--work") == 0): has_work = 1
			if (strcmp(args[i], c"--workspace-mb") == 0 && i + 1 < argc):
				workspace_mb = atoi(args[i + 1])
		if (has_work): mount_ok = box_guest_workspace(workspace_mb)
		int port = -1
		int deadline = process_monotonic_ms() + 30000
		while (mount_ok && port < 0 && deadline - process_monotonic_ms() > 0):
			port = open(c"/dev/vport0p1", 2050, 0)
			if (port < 0): process_sleep_ms(10)
		if (port >= 0):
			box_guest_serve(port, 0)
			close(port)
		# A lost or malformed control channel terminates the guest.
		syscall7(169, cast(int, 0xfee1dead), 0x28121969, 0x01234567, 0, 0, 0)
		while (1): process_sleep_ms(1000)

	char** command = strv_new(1)
	strv_set(command, 0, c"/bin/sh")
	char** selected = command
	if (argc > 1): selected = args + __word_size__
	process* child = process_spawn(selected[0], selected, 0)
	int status = 125
	if (child != 0):
		status = process_wait(child)
		process_free(child)
	free(cast(void*, command))
	string_builder* result = string_new()
	string_append(result, c"wvm-init: exit ")
	string_append_int(result, status)
	println(result.data)
	string_free(result)
	syscall(162, 0, 0, 0) # sync explicit writable shares
	syscall7(169, cast(int, 0xfee1dead), 0x28121969, 0x01234567, 0, 0, 0)
	while (1): process_sleep_ms(1000)
	return 125
