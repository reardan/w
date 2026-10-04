# wbuild: binary=wvm_fixture arch=x64
import lib.lib
import lib.assert
import lib.env

thread_local int wvm_tls_value

int main(int argc, int argv):
	char** args = cast(char**, argv)
	if (argc < 2): return 2
	char* mode = args[1]
	if (strcmp(mode, c"smoke") == 0):
		assert_equal(3, argc)
		assert_equal(0, strcmp(args[2], c"payload"))
		asserts(c"guest argv terminated", args[argc] == 0)
		asserts(c"host environment not inherited", env_get(c"W_VM_HOST_SECRET") == 0)
		assert_equal(0, wvm_tls_value)
		wvm_tls_value = 81
		assert_equal(81, wvm_tls_value)
		char* allocated = malloc(1048576)
		allocated[1048575] = 37
		assert_equal(37, allocated[1048575])
		free(allocated)
		char[16] ts
		assert_equal(0, sys_clock_gettime(1, cast(int, &ts[0])))
		char[32] random
		assert_equal(32, sys_getrandom(&random[0], 32, 0))
		println(c"cell smoke OK")
		return 0
	if (strcmp(mode, c"deny") == 0):
		assert_equal(-13, open(c"/etc/passwd", 0, 0))
		assert_equal(-38, unlink(c"bin/wvm_host_sentinel"))
		assert_equal(-13, syscall(41, 2, 1, 0))
		assert_equal(-38, syscall(57, 0, 0, 0))
		assert_equal(-9, write(7, c"no", 2))
		assert_equal(-14, write(1, cast(char*, 4096), 1))
		assert_equal(-14, write(1, c"no", -1))
		assert_equal(0, write(1, cast(char*, 0), 0))
		assert_equal(-38, syscall(999999, 0, 0, 0))
		println(c"cell denials OK")
		return 0
	if (strcmp(mode, c"exit") == 0): return 37
	if (strcmp(mode, c"spin") == 0):
		while (1): wvm_tls_value = wvm_tls_value + 1
	if (strcmp(mode, c"input") == 0):
		char[64] buffer
		int count = read(0, &buffer[0], 64)
		asserts(c"stdin read", count >= 0)
		write(1, &buffer[0], count)
		return 0
	if (strcmp(mode, c"supervisor") == 0):
		char* p = cast(char*, 4096)
		return p[0]
	int memory = mmap(0, 8192, 3, 34)
	asserts(c"anonymous guest mapping", memory > 0)
	char* p = cast(char*, memory)
	p[0] = 19
	if (strcmp(mode, c"readonly") == 0):
		assert_equal(0, mprotect(memory, 8192, 1))
		p[0] = 20
	if (strcmp(mode, c"unmapped") == 0):
		assert_equal(0, munmap(memory, 8192))
		return p[0]
	if (strcmp(mode, c"nx") == 0):
		p[0] = 195 # ret, on a non-executable page
		int* fn = cast(int*, p)
		return fn()
	if (strcmp(mode, c"io") == 0):
		assert_equal(0, mprotect(memory, 8192, 7))
		p[0] = 230 # out 0xe9,al from CPL3 must fault
		p[1] = 233
		p[2] = 195
		int* fn = cast(int*, p)
		return fn()
	if (strcmp(mode, c"memory") == 0):
		assert_equal(0, mprotect(memory, 8192, 0))
		assert_equal(0, mprotect(memory, 8192, 3))
		assert_equal(19, p[0])
		assert_equal(-22, mprotect(memory + 1, 4096, 3))
		assert_equal(-12, mmap(0, 268435456, 3, 34))
		int current = brk(0)
		assert_equal(current, brk(cast(char*, 268435456)))
		assert_equal(0, close(2))
		assert_equal(-9, write(2, c"closed", 6))
		println(c"cell memory OK")
		return 0
	if (strcmp(mode, c"output") == 0):
		int big = mmap(0, 4198400, 3, 34)
		asserts(c"output buffer", big > 0)
		write(1, cast(char*, big), 4194305)
	return 99
