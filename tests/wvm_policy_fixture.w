# wbuild: binary=wvm_policy_fixture arch=x64
import lib.lib
import lib.assert

int main(int argc, int argv):
	if (argc != 2): return 2
	char** args = cast(char**, argv)
	if (strcmp(args[1], c"services") == 0):
		assert_equal(-13, syscall7(56, 0, 0, 0, 0, 0, 0))
		assert_equal(-13, syscall7(202, 0, 0, 0, 0, 0, 0))
		char[64] data
		assert_equal(16, sys_getrandom(&data[0], 16, 0))
		assert_equal(0, sys_clock_gettime(1, cast(int, &data[16])))
		assert_equal(0, sys_clock_gettime(0, cast(int, &data[32])))
		assert_equal(3, read(0, &data[48], 3))
		assert_equal(51, write(1, &data[0], 51))
		return 0
	if (strcmp(args[1], c"budget") == 0):
		while (1): syscall(39, 0, 0, 0)
	if (strcmp(args[1], c"private") == 0):
		int fd = open(c"hello", 2, 0)
		asserts(c"open private lower", fd >= 3)
		char[5] data
		assert_equal(5, read(fd, &data[0], 5))
		assert_equal(0, syscall(8, fd, 0, 0))
		assert_equal(5, write(fd, c"upper", 5))
		assert_equal(0, close(fd))
		fd = open(c"fresh", 193, 384)
		asserts(c"create private file", fd >= 3)
		assert_equal(4, write(fd, c"data", 4))
		assert_equal(0, syscall(82, cast(int, c"fresh"), cast(int, c"final"), 0))
		assert_equal(0, unlink(c"final"))
		assert_equal(4, write(fd, c"more", 4)) # unlinked but still charged
		assert_equal(0, close(fd))
		assert_equal(0, syscall(83, cast(int, c"directory"), 448, 0))
		assert_equal(0, syscall(82, cast(int, c"directory"), cast(int, c"renamed"), 0))
		assert_equal(0, syscall(84, cast(int, c"renamed"), 0, 0))
		int directory = -100
		for depth in range(64):
			assert_equal(0, syscall(258, directory, cast(int, c"d"), 448))
			int next = syscall7(257, directory, cast(int, c"d"), 65536, 0, 0, 0)
			asserts(c"open bounded directory", next >= 3)
			if (directory != -100): close(directory)
			directory = next
		assert_equal(-36, syscall(258, directory, cast(int, c"d"), 448))
		close(directory)
		println(c"private OK")
		return 0
	return 2
