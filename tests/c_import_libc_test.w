# wbuild: x64
import lib.testing

# Broad system headers imported together: overlapping typedefs, structs and
# functions across headers must be skipped, not redefined. W's own symbols
# (open/read/write/close/malloc/strcmp/...) always win over libc's.
c_import "libc.so.6" c"/usr/include/stdio.h"
c_import "libc.so.6" c"/usr/include/stdlib.h"
c_import "libc.so.6" c"/usr/include/string.h"
c_import "libc.so.6" c"/usr/include/unistd.h"
c_import "libc.so.6" c"/usr/include/fcntl.h"
c_import "libc.so.6" c"/usr/include/errno.h"
c_import "libc.so.6" c"/usr/include/time.h"
c_import "libc.so.6" c"/usr/include/signal.h"
c_import "libc.so.6" c"/usr/include/ctype.h"
c_import "libc.so.6" c"/usr/include/math.h"
c_import "libc.so.6" c"/usr/include/dirent.h"
c_import "libc.so.6" c"/usr/include/locale.h"
c_import "libc.so.6" c"/usr/include/x86_64-linux-gnu/sys/stat.h"


void test_libc_stdio_file_round_trip():
	char* path = c"bin/c_import_libc_test.tmp"
	FILE* out = fopen(path, c"w")
	assert1(out != 0)
	assert1(fputs(c"c_import line\x0a", out) >= 0)
	assert_equal(0, fclose(out))
	FILE* in = fopen(path, c"r")
	assert1(in != 0)
	char* buf = malloc(64)
	assert1(fgets(buf, 64, in) != 0)
	assert_equal(0, fclose(in))
	assert_equal(0, strcmp(c"c_import line\x0a", buf))
	free(buf)
	assert_equal(0, remove(path))


void test_libc_process_and_ctype():
	assert1(getpid() > 0)
	assert1(isalpha('w') != 0)
	assert_equal(0, isalpha('7'))
	assert1(isdigit('7') != 0)
	assert_equal('W', toupper('w'))


void test_libc_struct_tm_fields():
	int now = time(0)
	assert1(now > 0)
	tm* t = localtime(&now)
	assert1(t != 0)
	# tm_year counts from 1900; anything since 2020 proves field offsets work
	assert1(t.tm_year >= 120)
	assert1(t.tm_mon >= 0)
	assert1(t.tm_mon <= 11)
	assert1(t.tm_mday >= 1)
	assert1(t.tm_mday <= 31)


void test_libc_macro_constants():
	assert_equal(2, SEEK_END)
	assert_equal(0 - 1, EOF)
	assert_equal(64, O_CREAT)
	assert_equal(2, ENOENT)
	assert_equal(13, EACCES)
	assert_equal(9, SIGKILL)
	assert_equal(6, LC_ALL)
	assert_equal(8, DT_REG)


# stdout/stderr import as data objects (COPY relocations): glibc
# initializes them statically, so a null pointer means the import failed.
void test_libc_extern_data_stdio():
	assert1(stdout != 0)
	assert1(stderr != 0)
	assert1(fputs(c"", stdout) >= 0)
	assert1(fprintf(stdout, c"") >= 0)


# snprintf imports as a variadic function: direct calls pass any number
# of extra arguments, with floats promoted to float64 per the C ABI.
void test_libc_variadic_snprintf():
	char* buf = malloc(64)
	assert_equal(9, snprintf(buf, 64, c"%d %s", 42, c"vararg"))
	assert_equal(0, strcmp(c"42 vararg", buf))
	assert_equal(6, snprintf(buf, 64, c"%.1f %d", 1.5, 27))
	assert_equal(0, strcmp(c"1.5 27", buf))
	free(buf)


void test_libc_strtol_and_qsort_absent_collisions():
	# strtol comes from libc; W's own atoi/strcmp/malloc stay in charge
	assert_equal(1234, strtol(c"1234", 0, 10))
	assert_equal(255, strtol(c"ff", 0, 16))
	assert_equal(42, atoi(c"42"))
	char* copy = malloc(8)
	strcpy(copy, c"seven")
	assert_equal(0, strcmp(c"seven", copy))
	free(copy)


# The kernel fills struct stat, so a correct st_size read proves the
# imported struct layout (padding and 64-bit members included) matches the
# C ABI on this target.
void test_libc_fstat_struct_layout():
	char* path = c"bin/c_import_stat.tmp"
	int file = open(path, 577, 420)
	assert_equal(9, write(file, c"ninebytes", 9))
	assert_equal(0, close(file))
	file = open(path, 0, 0)
	stat st_buf
	assert_equal(0, fstat(file, &st_buf))
	assert_equal(0, close(file))
	assert_equal(9, st_buf.st_size)
	assert1(st_buf.st_nlink >= 1)
	assert_equal(0, remove(path))


void test_libc_w_syscall_wrappers_still_win():
	# W's open/read/write/close are syscall wrappers; unistd.h/fcntl.h must
	# not have replaced them
	char* path = c"bin/c_import_libc_wrapper.tmp"
	int file = open(path, 577, 420)
	assert1(file >= 0)
	assert_equal(5, write(file, c"hello", 5))
	assert_equal(0, close(file))
	file = open(path, 0, 0)
	char* buf = malloc(8)
	assert_equal(5, read(file, buf, 8))
	assert_equal(0, close(file))
	buf[5] = 0
	assert_equal(0, strcmp(c"hello", buf))
	free(buf)
	assert_equal(0, remove(path))
