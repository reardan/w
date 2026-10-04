# wbuild: binary=wvm_fs_fixture arch=x64
import lib.lib
import lib.assert


int main(int argc, int argv):
	char** args = cast(char**, argv)
	assert_equal(2, argc)
	char* mode = args[1]
	if (strcmp(mode, c"default") == 0):
		assert_equal(-13, open(c"/hello", 0, 0))
		return 0
	char[256] buffer
	int fd = open(c"/hello", 0, 0)
	assert_equal(3, fd)
	assert_equal(5, read(fd, &buffer[0], 256))
	buffer[5] = 0
	assert_equal(0, strcmp(&buffer[0], c"hello"))
	assert_equal(0, syscall(8, fd, 0, 0))
	assert_equal(0, syscall(5, fd, cast(int, &buffer[0]), 0))
	assert_equal(5, load_int64(&buffer[48]))
	assert_equal(-14, read(fd, cast(char*, 4096), 5))
	assert_equal(0, close(fd))
	assert_equal(-9, read(fd, &buffer[0], 1))
	assert_equal(-9, read(63, &buffer[0], 1))
	assert_equal(-18, open(c"../outside", 0, 0))
	assert_equal(-18, open(c"/../outside", 0, 0))
	assert_equal(-40, open(c"escape", 0, 0))
	assert_equal(-40, open(c"local_link", 0, 0))
	assert_equal(-13, open(c"fifo", 0, 0))
	assert_equal(-14, open(cast(char*, 4096), 0, 0))
	fd = open(c".", 65536, 0)
	assert_equal(3, fd)
	asserts(c"directory enumeration", syscall(217, fd, cast(int, &buffer[0]), 256) > 0)
	int child = syscall7(257, fd, cast(int, c"hello"), 0, 0, 0, 0)
	assert_equal(4, child)
	assert_equal(0, close(child))
	assert_equal(0, close(fd))
	assert_equal(0, syscall(4, cast(int, c"hello"), cast(int, &buffer[0]), 0))
	assert_equal(5, load_int64(&buffer[48]))
	assert_equal(0, syscall7(332, -100, cast(int, c"hello"), 0, 2047, cast(int, &buffer[0]), 0))
	assert_equal(5, load_int64(&buffer[40]))
	assert_equal(-22, open(c"hello", 16384, 0))
	for i in range(61): assert_equal(i + 3, open(c"hello", 0, 0))
	assert_equal(-24, open(c"hello", 0, 0))
	for i in range(61): assert_equal(0, close(i + 3))
	if (strcmp(mode, c"read") == 0):
		assert_equal(-30, open(c"hello", 1, 0))
		assert_equal(-30, open(c"new", 577, 384))
		assert_equal(-30, open(c"hello", 512, 0))
		assert_equal(-30, unlink(c"hello"))
		assert_equal(-30, syscall(83, cast(int, c"newdir"), 448, 0))
		println(c"filesystem read OK")
		return 0
	assert_equal(0, strcmp(mode, c"write"))
	fd = open(c"created", 578, 384)
	assert_equal(3, fd)
	assert_equal(7, write(fd, c"payload", 7))
	assert_equal(-14, write(fd, cast(char*, 4096), 1))
	assert_equal(0, syscall(74, fd, 0, 0))
	assert_equal(0, syscall(77, fd, 4, 0))
	assert_equal(4, syscall7(17, fd, cast(int, &buffer[0]), 4, 0, 0, 0))
	buffer[4] = 0
	assert_equal(0, strcmp(&buffer[0], c"payl"))
	assert_equal(0, close(fd))
	assert_equal(0, syscall(83, cast(int, c"newdir"), 448, 0))
	assert_equal(0, syscall(82, cast(int, c"created"), cast(int, c"newdir/moved"), 0))
	fd = open(c"newdir", 65536, 0)
	assert_equal(3, fd)
	assert_equal(0, syscall(263, fd, cast(int, c"moved"), 0))
	assert_equal(0, close(fd))
	assert_equal(0, syscall(84, cast(int, c"newdir"), 0, 0))
	asserts(c"write traversal denied", open(c"../outside", 577, 384) < 0)
	asserts(c"write symlink denied", open(c"escape", 577, 384) < 0)
	asserts(c"unlink traversal denied", unlink(c"../outside") < 0)
	asserts(c"rename traversal denied", syscall(82, cast(int, c"hello"), cast(int, c"../outside"), 0) < 0)
	asserts(c"mkdir traversal denied", syscall(83, cast(int, c"../outside/newdir"), 448, 0) < 0)
	println(c"filesystem write OK")
	return 0
