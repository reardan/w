# Static Linux AArch64 guest, executed only inside a Darwin Hypervisor cell.
# wbuild: binary=wvm_darwin_fixture arch=arm64 tag=tests_arm64
import lib.lib
import lib.assert
import lib.env

int darwin_fixture_tls

int main(int argc, int argv):
	char** args = cast(char**, argv)
	if (argc < 2): return 2
	char* mode = args[1]
	if (strcmp(mode, c"hello") == 0):
		println(c"hello from an ARM64 cell")
		return 7
	if (strcmp(mode, c"argv") == 0):
		assert_equal(3, argc)
		assert_equal(0, strcmp(args[2], c"payload"))
		asserts(c"argv terminated", args[argc] == 0)
		asserts(c"environment private", env_get(c"W_VM_HOST_SECRET") == 0)
		println(c"cell argv OK")
		return 0
	if (strcmp(mode, c"alloc") == 0 || strcmp(mode, c"smoke") == 0):
		assert_equal(0, darwin_fixture_tls)
		darwin_fixture_tls = 81
		assert_equal(81, darwin_fixture_tls)
		char* memory = cast(char*, malloc(1048576))
		memory[1048575] = 37
		assert_equal(37, memory[1048575])
		free(memory)
		map[int, int] values = new map[int, int]
		for i in range(1000): values[i] = i * 3
		assert_equal(2997, values[999])
		values.free()
		float a = 1.5
		float b = 2.0
		asserts(c"FP initialized", a * b == 3.0)
		char[16] ts
		assert_equal(0, sys_clock_gettime(1, cast(int, &ts[0])))
		char[32] random
		assert_equal(32, sys_getrandom(&random[0], 32, 0))
		println(c"cell allocator containers FP OK")
		return 0
	if (strcmp(mode, c"deny") == 0 || strcmp(mode, c"invalid-buffer") == 0):
		assert_equal(-13, open(c"/etc/passwd", 0, 0))
		assert_equal(-13, syscall(198, 2, 1, 0))
		assert_equal(-38, syscall(220, 0, 0, 0))
		assert_equal(-38, syscall(999999, 0, 0, 0))
		assert_equal(-9, write(7, c"bad", 3))
		assert_equal(-14, write(1, cast(char*, 4096), 1))
		assert_equal(-14, write(1, c"bad", -1))
		assert_equal(-14, write(1, cast(char*, -4096), 8192))
		assert_equal(0, write(1, cast(char*, 0), 0))
		println(c"cell denials OK")
		return 0
	if (strcmp(mode, c"exit") == 0): return 37
	if (strcmp(mode, c"spin") == 0):
		while (1): darwin_fixture_tls = darwin_fixture_tls + 1
	if (strcmp(mode, c"input") == 0):
		char[64] buffer
		int count = read(0, &buffer[0], 64)
		asserts(c"bounded input", count >= 0)
		write(1, &buffer[0], count)
		return 0
	if (strcmp(mode, c"monitor") == 0):
		char* p = cast(char*, 4096)
		return p[0]
	int memory = mmap(0, 8192, 3, 34)
	asserts(c"anonymous mapping", memory > 0)
	char* p = cast(char*, memory)
	p[0] = 19
	if (strcmp(mode, c"pages") == 0):
		assert_equal(0, mprotect(memory, 4096, 1))
		p[4096] = 31 # same 16KiB host page, different 4KiB guest permission
		assert_equal(31, p[4096])
		assert_equal(0, munmap(memory + 4096, 4096))
		assert_equal(-14, write(1, p + 4095, 2))
		assert_equal(-14, read(0, p, 1))
		println(c"cell page boundaries OK")
		return 0
	if (strcmp(mode, c"readonly") == 0):
		assert_equal(0, mprotect(memory, 4096, 1))
		p[0] = 20
	if (strcmp(mode, c"unmapped") == 0):
		assert_equal(0, munmap(memory, 8192))
		return p[0]
	if (strcmp(mode, c"nx") == 0 || strcmp(mode, c"hvc") == 0):
		save_int32(p, cast(int, 0xd65f03c0)) # ret
		if (strcmp(mode, c"hvc") == 0):
			save_int32(p, cast(int, 0xd4000002)) # forged hvc #0 at EL0
			assert_equal(0, mprotect(memory, 8192, 7))
		int* function = cast(int*, p)
		return function()
	if (strcmp(mode, c"memory") == 0):
		assert_equal(0, mprotect(memory, 8192, 0))
		assert_equal(-14, write(1, p, 1))
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
	if (strcmp(mode, c"burst") == 0):
		int big = mmap(0, 1048576, 3, 34)
		asserts(c"bounded burst allocation", big > 0)
		assert_equal(1048576, write(1, cast(char*, big), 1048576))
		return 0
	if (strcmp(mode, c"output") == 0):
		int big = mmap(0, 4198400, 3, 34)
		asserts(c"output allocation", big > 0)
		write(1, cast(char*, big), 4194305)
	return 99
