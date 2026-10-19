# Observation helpers for the ownership-preserving optimization fixtures
# (tests/safe_opt_*_fixture.w, driven by tests/safe_opt_diff_test.w).
#
# safe_opt_log_install() routes free() through safe_opt_log_free, which
# prints "drop <n>" for every released block whose first word is a tag
# safe_opt_tag(n) = 7340000 + n (n in 0..99999) and then frees it as usual. Checked
# programs give every owner they want to observe such a tag, so the
# program's stdout is a log of destruction order that the harness can
# compare between optimization configurations and against the manual
# cleanup twins. safe_opt_mark(n) prints "mark <n>" for transfer points
# and deferred work; safe_opt_case() reads the SAFE_OPT_CASE environment
# variable (0 when unset) so one checked program can host several trap
# scenarios without a raw argv parameter. Raw operations stay inside unsafe blocks, so a
# checked (--safe) program can import this module too.
import lib.lib
import lib.safe


int safe_opt_tag(int n):
	return 7340000 + n


# One line "<word> <n>" on stdout, written byte by byte: the free hook
# must not allocate, and stdout keeps marks and drops in one stream.
void safe_opt_log_line(int word, int n):
	if word == 'd':
		put_char('d')
		put_char('r')
		put_char('o')
		put_char('p')
	else:
		put_char('m')
		put_char('a')
		put_char('r')
		put_char('k')
	put_char(' ')
	safe_print_int(n)
	put_char(10)


int safe_opt_log_free(int p):
	int result = 0
	unsafe:
		if (p != 0):
			int tag = *cast(int*, p) - 7340000
			if ((tag >= 0) && (tag < 100000)):
				safe_opt_log_line('d', tag)
		result = malloc_backend_free(cast(void*, p))
	return result


void safe_opt_log_install():
	unsafe:
		malloc_hook_set(0, cast(int, safe_opt_log_free), 0)


void safe_opt_mark(int n):
	safe_opt_log_line('m', n)


# Reads /proc/self/environ through the audited lib.lib/lib.linux closure
# (lib.env is not part of it, so a --safe program could not import it).
int safe_opt_case():
	int result = 0
	unsafe:
		int fd = open(c"/proc/self/environ", 0, 0)
		if (fd >= 0):
			int cap = 65536
			char* buf = cast(char*, malloc(cap))
			int n = read(fd, buf, cap - 1)
			close(fd)
			char* needle = c"SAFE_OPT_CASE="
			int i = 0
			while (i < n):
				int j = 0
				while ((j < 14) && (i + j < n) && (buf[i + j] == needle[j])): j = j + 1
				if (j == 14):
					int k = i + 14
					while ((k < n) && (buf[k] >= '0') && (buf[k] <= '9')):
						result = result * 10 + buf[k] - '0'
						k = k + 1
				while ((i < n) && (buf[i] != 0)): i = i + 1
				i = i + 1
			free(buf)
	return result
