# wbuild: binary=wvm_box_fixture arch=x64
import lib.file
import lib.thread

int box_worker_result


void box_worker(void* arg):
	box_worker_result = cast(int, arg)


int main():
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
