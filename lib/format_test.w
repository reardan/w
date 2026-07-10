# wbuild: x64
import lib.testing
import lib.format


void test_printf_smoke():
	printf(c"printf smoke test\n")
	printf2(c"%d plus %d", 1, 2)
	printf(c"\n")


void test_vfprintf_to_file():
	char* path = c"/tmp/w_format_test.txt"
	/* O_WRONLY|O_CREAT|O_TRUNC */
	int fd = open(path, 577, 493)
	asserts(c"could not create temp file", fd >= 0)
	int* args = malloc(3 * __word_size__)
	args[0] = 42
	args[1] = c"abc"
	args[2] = 'z'
	vfprintf(fd, c"d=%d s=%s c=%c %%", args, 3)
	free(args)
	close(fd)

	fd = open(path, 0, 0)
	char* buf = malloc(100)
	int n = read(fd, buf, 99)
	buf[n] = 0
	close(fd)
	assert_strings_equal(c"d=42 s=abc c=z %", buf)
	free(buf)


void test_hex_verb():
	char* path = c"/tmp/w_format_test.txt"
	int fd = open(path, 577, 493)
	int* args = malloc(__word_size__)
	args[0] = 255
	vfprintf(fd, c"%x", args, 1)
	free(args)
	close(fd)

	fd = open(path, 0, 0)
	char* buf = malloc(100)
	int n = read(fd, buf, 99)
	buf[n] = 0
	close(fd)
	assert_strings_equal(c"0x000000ff", buf)
	free(buf)


void test_ftoa():
	char* got = ftoa(-2.5)
	assert_strings_equal(c"-2.500000", got)
	free(got)
