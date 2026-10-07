# wbuild: x64
/*
RELRO at run time (issue #537). This dynamically linked program's GOT
sits in whole pages just below the data base (0x09048000) and is
covered by PT_GNU_RELRO (tests/elf_wx_segment_test.w checks the
headers). After ld.so has written every GOT slot it mprotects those
pages read-only, so:

- the libc calls through the GOT still work,
- COPY-relocated data (optind) lives above the RELRO pages and stays
  writable,
- /proc/self/maps shows the GOT page r--p, ending exactly at the data
  base, followed by the rw-p data,
- a write into the GOT page faults (checked in a forked child).
*/
import lib.testing
import lib.str

c_lib "libc.so.6"

extern int puts(char* s)
extern int optind


int relro_data_base():
	st_init(cast(int, relro_data_base))
	return 0x09048000 + st_slide


char* relro_data_hex():
	char* h = hex_fixed(relro_data_base(), __word_size__ * 2)
	int i = 2
	while ((h[i] == '0') && (strlen(h + i) > 8)): i = i + 1
	return h + i


# The first /proc/self/maps line containing needle, or 0. Mapping
# addresses print as at least 8 lowercase hex digits, so the data base
# reads "09048000" on both widths.
char* relro_maps_line(char* needle):
	int fd = open(c"/proc/self/maps", 0, 0)
	asserts(c"/proc/self/maps opened", fd >= 0)
	char* buf = cast(char*, malloc(65537))
	int total = 0
	int n = read(fd, buf, 65536)
	while (n > 0):
		total = total + n
		n = 0
		if (total < 65536): n = read(fd, &buf[total], 65536 - total)
	close(fd)
	buf[total] = 0
	int at = index_of(buf, needle)
	if (at < 0): return 0
	int line = at
	while ((line > 0) && (buf[line - 1] != 10)): line = line - 1
	int end = at
	while ((buf[end] != 10) && (buf[end] != 0)): end = end + 1
	return substring(buf, line, end)


void test_imports_still_work():
	asserts(c"puts through the GOT", puts(c"elf_relro_test: puts via the read-only GOT") >= 0)
	optind = 7
	assert_equal(7, optind)
	optind = 1


void test_got_page_is_read_only():
	char* got = relro_maps_line(strjoin(strjoin(c"-", relro_data_hex()), c" "))
	asserts(c"a mapping ends at the data base", got != 0)
	assert_contains(got, c" r--p ")
	char* data = relro_maps_line(strjoin(relro_data_hex(), c"-"))
	asserts(c"the data mapping starts at the data base", data != 0)
	assert_contains(data, c" rw-p ")


void test_got_write_faults():
	int pid = fork()
	asserts(c"fork", pid >= 0)
	if (pid == 0):
		# Restore the default SIGSEGV action quietly: the crash report
		# lib/testing.w installed would only add noise to the log.
		int[5] dfl
		for i in range(5): dfl[i] = 0
		rt_sigaction(11, &dfl[0], 0)
		int* slot = cast(int*, relro_data_base() - __word_size__)
		*slot = 0
		exit(3)
	int status = 0
	asserts(c"wait4", wait4(pid, &status, 0, 0) == pid)
	assert_equal(11, status & 127)   /* SIGSEGV: the GOT is read-only */
