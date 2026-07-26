# wbuild: x64
/*
getchar_checked/getchar_unbuffered_checked distinguish end-of-file
(GETCHAR_EOF, -1) from a failed read() (GETCHAR_READ_ERROR, -2), which
the legacy getchar()/getchar_unbuffered() collapse into the same -1
(docs/projects/ai_tooling_next_steps.md). EOF comes from a real file; a
genuine mid-file I/O failure is not portably triggerable, so read() on a
closed or never-opened fd (EBADF) stands in for the error path.
*/
import lib.testing
import structures.string


char* gct_path_cache


# Pid-scoped fixture file under bin/ holding the 3 bytes "ABC",
# recreated (truncated) on every call.
char* gct_path():
	if (gct_path_cache == 0):
		mkdir(c"bin", 493)
		string_builder* p = string_new()
		string_append(p, c"bin/getchar_checked_test_")
		string_append_int(p, getpid())
		string_append(p, c".txt")
		gct_path_cache = p.data
		free(p)
	int fd = create_file(gct_path_cache, 420)
	assert1(fd >= 0)
	assert_equal(3, write(fd, c"ABC", 3))
	close(fd)
	return gct_path_cache


void test_checked_returns_bytes_then_sticky_eof():
	int fd = open(gct_path(), 0, 0)
	assert1(fd >= 0)
	getchar_reset(fd)
	assert_equal('A', getchar_checked(fd))
	assert_equal('B', getchar_checked(fd))
	assert_equal('C', getchar_checked(fd))
	assert_equal(GETCHAR_EOF(), getchar_checked(fd))
	# EOF is sticky, not an error
	assert_equal(GETCHAR_EOF(), getchar_checked(fd))
	close(fd)


void test_checked_shares_buffer_state_with_getchar():
	int fd = open(gct_path(), 0, 0)
	assert1(fd >= 0)
	getchar_reset(fd)
	assert_equal('A', getchar(fd))
	assert_equal('B', getchar_checked(fd))
	assert_equal('C', getchar(fd))
	assert_equal((-1), getchar(fd))
	assert_equal(GETCHAR_EOF(), getchar_checked(fd))
	close(fd)


void test_unbuffered_checked_eof():
	int fd = open(gct_path(), 0, 0)
	assert1(fd >= 0)
	assert_equal('A', getchar_unbuffered_checked(fd))
	assert_equal('B', getchar_unbuffered_checked(fd))
	assert_equal('C', getchar_unbuffered_checked(fd))
	assert_equal(GETCHAR_EOF(), getchar_unbuffered_checked(fd))
	close(fd)


void test_checked_reports_read_error_on_closed_fd():
	int fd = open(gct_path(), 0, 0)
	assert1(fd >= 0)
	getchar_reset(fd)
	close(fd)
	# read() fails with EBADF: the checked variant reports it distinctly,
	# the legacy getchar() collapses the same failure into -1.
	assert_equal(GETCHAR_READ_ERROR(), getchar_checked(fd))
	assert_equal((-1), getchar(fd))


void test_unbuffered_checked_reports_read_error():
	# fd 300 is above GETCHAR_MAX_FD (so getchar_checked routes to the
	# unbuffered path) and never opened by this process.
	assert_equal(GETCHAR_READ_ERROR(), getchar_unbuffered_checked(300))
	assert_equal(GETCHAR_READ_ERROR(), getchar_checked(300))
	assert_equal((-1), getchar_unbuffered(300))
