# wbuild: binary=wvm_box_fixture arch=x64
import lib.file
import lib.thread
import lib.process
import lib.mem

int box_worker_result


void box_worker(void* arg):
	box_worker_result = cast(int, arg)


int main(int argc, int argv):
	char** args = cast(char**, argv)
	if (argc > 1):
		if (strcmp(args[1], c"caps") == 0):
			if (syscall7(157, 23, 21, 0, 0, 0, 0) != 0): return 20
			if (syscall7(157, 39, 0, 0, 0, 0, 0) != 1): return 21
			if (syscall7(165, cast(int, c"tmpfs"), cast(int, c"/sys"), cast(int, c"tmpfs"), 0, 0, 0) != -1): return 22
			return 0
		if (strcmp(args[1], c"workspace") == 0):
			char* base = file_read_text(c"/work/base.txt")
			if (base == 0): return 30
			int same = strcmp(base, c"immutable base") == 0
			free(base)
			if (same == 0): return 31
			if (file_write_text(c"/work/private.txt", c"private edit") == 0): return 32
			return 0
		if (strcmp(args[1], c"workspace-full") == 0):
			char* edit = file_read_text(c"/work/private.txt")
			if (edit == 0): return 33
			free(edit)
			int fd = open(c"/work/fill", 65, 420)
			if (fd < 0): return 34
			char[4096] block
			mem_fill[char](&block[0], 0, 4096)
			int filled = 0
			while (filled < 2097152):
				int count = write(fd, &block[0], 4096)
				if (count == -28):
					close(fd)
					return 0
				if (count <= 0): break
				filled = filled + count
			close(fd)
			return 35
		if (strcmp(args[1], c"wait") == 0):
			process_sleep_ms(5000)
			return 0
		if (strcmp(args[1], c"output") == 0):
			write(1, c"a\0b", 3)
			write(2, c"guest stderr", 12)
			return 9
		if (strcmp(args[1], c"flood") == 0):
			while (1): write(1, c"1234567890", 10)

	if (file_write_text(c"/guest-file", c"linux filesystem") == 0): return 10
	char* text = file_read_text(c"/guest-file")
	if (text == 0): return 11
	int equal = strcmp(text, c"linux filesystem") == 0
	free(text)
	if (equal == 0): return 12
	wthread* worker = thread_spawn(box_worker, cast(void*, 42))
	if (worker == 0): return 13
	if (thread_join(worker) != 0 || box_worker_result != 42): return 14
	char* version = file_read_text(c"/proc/version")
	if (version == 0): return 15
	println(version)
	free(version)
	println(c"Linux guest filesystem and threads passed")
	return 7
