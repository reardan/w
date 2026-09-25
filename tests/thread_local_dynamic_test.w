# wbuild: x64
import lib.testing
import lib.thread

/*
thread_local in a dynamically linked program (docs/projects/thread_local.md):
libc owns the thread pointer its own TLS hangs off (fs on x64, gs on
x86), so W's blocks ride the other segment register. libc calls that
read their own TLS (errno, the stack protector canary, stdio locks)
must keep working on the main thread after W installs its block.
*/
c_lib "libc.so.6"
extern int getppid()
extern int snprintf(char* buf, int n, char* fmt, ...)

thread_local int tl_value


void tl_worker(void* arg):
	int* out = cast(int*, arg)
	out[0] = tl_value
	tl_value = 99
	out[1] = tl_value


void test_libc_and_thread_local_coexist():
	tl_value = 5
	asserts(c"getppid", getppid() > 0)
	char* buf = cast(char*, malloc(64))
	snprintf(buf, 64, c"tl=%d", tl_value)
	assert_equal(0, strcmp(c"tl=5", buf))
	int* out = cast(int*, malloc(2 * __word_size__))
	wthread* t = thread_spawn(tl_worker, cast(void*, out))
	asserts(c"thread_spawn failed", cast(int, t) != 0)
	assert_equal(0, thread_join(t))
	assert_equal(0, out[0])
	assert_equal(99, out[1])
	assert_equal(5, tl_value)
	snprintf(buf, 64, c"tl=%d", tl_value)
	assert_equal(0, strcmp(c"tl=5", buf))
