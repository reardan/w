import lib.testing
import lib.format


void test_printf_smoke():
	printf("printf smoke test\n")
	printf2("%d plus %d", 1, 2)
	printf("\n")


void test_vfprintf_to_file():
	char* path = "/tmp/w_format_test.txt"
	/* O_WRONLY|O_CREAT|O_TRUNC */
	int fd = open(path, 577, 493)
	asserts("could not create temp file", fd >= 0)
	int* args = malloc(12)
	args[0] = 42
	args[1] = "abc"
	args[2] = 'z'
	vfprintf(fd, "d=%d s=%s c=%c %%", args, 3)
	free(args)
	close(fd)

	fd = open(path, 0, 0)
	char* buf = malloc(100)
	int n = read(fd, buf, 99)
	buf[n] = 0
	close(fd)
	assert_strings_equal("d=42 s=abc c=z %", buf)
	free(buf)


void test_hex_verb():
	char* path = "/tmp/w_format_test.txt"
	int fd = open(path, 577, 493)
	int* args = malloc(4)
	args[0] = 255
	vfprintf(fd, "%x", args, 1)
	free(args)
	close(fd)

	fd = open(path, 0, 0)
	char* buf = malloc(100)
	int n = read(fd, buf, 99)
	buf[n] = 0
	close(fd)
	assert_strings_equal("0x000000ff", buf)
	free(buf)
