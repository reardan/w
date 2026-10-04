# wbuild: binary=wvm_init arch=x64
# Small Linux PID 1 for supplied initramfs images. The kernel passes
# arguments following '--' to /init; default command is /bin/sh.
import lib.process
import lib.file


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
