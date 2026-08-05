# wbuild: x64
# End-to-end test for lib/inotify.w (issue #231 wbuildd stage-1
# prerequisite, docs/projects/wbuildd.md par. 2.3): watches a
# pid-scoped scratch directory under bin/ (the tests/vcs_cas_test.w
# isolation pattern), performs real create/modify/rename/delete
# filesystem operations, and asserts the parsed event stream -- wd,
# masks, names, and the cookie linking a rename's
# IN_MOVED_FROM/IN_MOVED_TO pair -- plus the parser's bounds checking
# on synthetic buffers. Linux-only behavior by construction: the
# non-Linux arch shims stub out (lib/stat.w convention), and this test
# only builds for the x86/x64 Linux targets.
import lib.testing
import lib.inotify
import structures.string


# The pid-and-word-size-scoped scratch root, so the 32- and 64-bit
# twins can run in parallel without colliding.
char* it_root_cache
char* it_root():
	if (it_root_cache == 0):
		string_builder* p = string_new()
		string_append(p, c"bin/inotify_test_")
		string_append_int(p, getpid())
		string_append_char(p, '_')
		string_append_int(p, __word_size__ * 8)
		it_root_cache = p.data
		free(p)
	return it_root_cache


# "<it_root()>_<suffix>": one scratch directory per test function.
char* it_dir(char* suffix):
	string_builder* p = string_new()
	string_append(p, it_root())
	string_append_char(p, '_')
	string_append(p, suffix)
	char* result = p.data
	free(p)
	return result


# "<dir>/<name>", for the filesystem operations (event names are the
# bare <name> relative to the watched directory).
char* it_path(char* dir, char* name):
	string_builder* p = string_new()
	string_append(p, dir)
	string_append_char(p, '/')
	string_append(p, name)
	char* result = p.data
	free(p)
	return result


void it_assert_ok(char* what, int result):
	if (result < 0):
		print_string(what, c" failed")
		translate_syscall_failure(result)
		exit(1)


# Parses the next record and asserts its shape in one step.
int it_expect_event(char* buf, int buf_end, int offset, int wd, int mask, char* name, inotify_event* out):
	int next = inotify_event_parse(buf, buf_end, offset, out)
	asserts(c"expected another inotify event", next > offset)
	assert_equal(wd, out.wd)
	assert_equal_hex(mask, out.mask)
	assert_strings_equal(name, out.name)
	assert_equal(strlen(name), out.name_length)
	return next


void test_inotify_watch_lifecycle():
	char* dir = it_dir(c"lifecycle")
	it_assert_ok(c"mkdir", mkdir(dir, 493))

	int fd = inotify_init()
	it_assert_ok(c"inotify_init", fd)
	int wd = inotify_add_watch(fd, dir, IN_ALL_EVENTS())
	it_assert_ok(c"inotify_add_watch", wd)
	it_assert_ok(c"inotify_rm_watch", inotify_rm_watch(fd, wd))

	# Removing the watch queues its final IN_IGNORED event: a record
	# with no name, exercising the len == 0 parse path (blocking read
	# is safe -- the event is already queued).
	char* buf = malloc(INOTIFY_BUF_SIZE())
	int got = read(fd, buf, INOTIFY_BUF_SIZE())
	assert_equal(INOTIFY_EVENT_HEADER_SIZE(), got)
	assert_equal(INOTIFY_EVENT_HEADER_SIZE(), inotify_event_record_size(buf, 0))

	inotify_event ev
	int next = inotify_event_parse(buf, got, 0, &ev)
	assert_equal(got, next)
	assert_equal(wd, ev.wd)
	assert_equal_hex(IN_IGNORED(), ev.mask)
	assert_equal(0, ev.name_length)
	assert_strings_equal(c"", ev.name)
	# The IN_IGNORED record was the whole buffer.
	assert_equal(-1, inotify_event_parse(buf, got, next, &ev))

	# Removing an already-removed watch fails with a negative errno.
	asserts(c"double rm_watch should fail", inotify_rm_watch(fd, wd) < 0)

	close(fd)
	free(buf)
	it_assert_ok(c"rmdir", rmdir(dir))


void test_inotify_event_stream():
	char* dir = it_dir(c"events")
	it_assert_ok(c"mkdir", mkdir(dir, 493))

	int fd = inotify_init_nonblocking()
	it_assert_ok(c"inotify_init_nonblocking", fd)
	int mask = IN_CREATE() | IN_MODIFY() | IN_DELETE() | IN_MOVED_FROM() | IN_MOVED_TO()
	int wd = inotify_add_watch(fd, dir, mask)
	it_assert_ok(c"inotify_add_watch", wd)

	# 1. create a.txt          -> IN_CREATE     "a.txt"
	# 2. write to a.txt        -> IN_MODIFY     "a.txt"
	# 3. rename a.txt -> b.txt -> IN_MOVED_FROM "a.txt" +
	#                             IN_MOVED_TO   "b.txt" (cookie-linked)
	# 4. delete b.txt          -> IN_DELETE     "b.txt"
	char* path_a = it_path(dir, c"a.txt")
	char* path_b = it_path(dir, c"b.txt")
	int file = create_file(path_a, 420)
	it_assert_ok(c"create_file", file)
	close(file)
	file = open(path_a, 1, 0)
	it_assert_ok(c"open for write", file)
	assert_equal(5, write(file, c"hello", 5))
	close(file)
	it_assert_ok(c"rename", rename(path_a, path_b))
	it_assert_ok(c"unlink", unlink(path_b))

	# Every event is already queued, so one read drains all five.
	char* buf = malloc(INOTIFY_BUF_SIZE())
	int got = read(fd, buf, INOTIFY_BUF_SIZE())
	asserts(c"expected queued inotify events", got > 0)

	inotify_event ev
	int offset = it_expect_event(buf, got, 0, wd, IN_CREATE(), c"a.txt", &ev)
	offset = it_expect_event(buf, got, offset, wd, IN_MODIFY(), c"a.txt", &ev)
	offset = it_expect_event(buf, got, offset, wd, IN_MOVED_FROM(), c"a.txt", &ev)
	int move_cookie = ev.cookie
	asserts(c"rename cookie should be nonzero", move_cookie != 0)
	offset = it_expect_event(buf, got, offset, wd, IN_MOVED_TO(), c"b.txt", &ev)
	assert_equal(move_cookie, ev.cookie)
	offset = it_expect_event(buf, got, offset, wd, IN_DELETE(), c"b.txt", &ev)
	assert_equal(got, offset)
	assert_equal(-1, inotify_event_parse(buf, got, offset, &ev))

	# The queue is drained: a nonblocking read reports EAGAIN (11).
	assert_equal(0 - 11, read(fd, buf, INOTIFY_BUF_SIZE()))

	close(fd)
	free(buf)
	free(path_a)
	free(path_b)
	it_assert_ok(c"rmdir", rmdir(dir))


void test_inotify_directory_events_carry_isdir():
	char* dir = it_dir(c"isdir")
	it_assert_ok(c"mkdir", mkdir(dir, 493))

	int fd = inotify_init_nonblocking()
	it_assert_ok(c"inotify_init_nonblocking", fd)
	int wd = inotify_add_watch(fd, dir, IN_CREATE() | IN_DELETE())
	it_assert_ok(c"inotify_add_watch", wd)

	char* subdir = it_path(dir, c"sub")
	it_assert_ok(c"mkdir sub", mkdir(subdir, 493))
	it_assert_ok(c"rmdir sub", rmdir(subdir))

	char* buf = malloc(INOTIFY_BUF_SIZE())
	int got = read(fd, buf, INOTIFY_BUF_SIZE())
	asserts(c"expected queued inotify events", got > 0)

	inotify_event ev
	int offset = it_expect_event(buf, got, 0, wd, IN_CREATE() | IN_ISDIR(), c"sub", &ev)
	offset = it_expect_event(buf, got, offset, wd, IN_DELETE() | IN_ISDIR(), c"sub", &ev)
	assert_equal(got, offset)

	close(fd)
	free(buf)
	free(subdir)
	it_assert_ok(c"rmdir", rmdir(dir))


void test_inotify_event_parse_bounds():
	# Synthetic buffer: one well-formed record (wd 7, IN_CREATE, cookie
	# 9, "abc" NUL-padded to len 8), checked against every truncation.
	char* buf = malloc(64)
	save_int32(buf, 7)
	save_int32(&buf[4], IN_CREATE())
	save_int32(&buf[8], 9)
	save_int32(&buf[12], 8)
	strcpy(&buf[16], c"abc")
	buf[20] = 0
	buf[21] = 0
	buf[22] = 0
	buf[23] = 0

	assert_equal(24, inotify_event_record_size(buf, 0))

	inotify_event ev
	assert_equal(24, inotify_event_parse(buf, 24, 0, &ev))
	assert_equal(7, ev.wd)
	assert_equal_hex(IN_CREATE(), ev.mask)
	assert_equal(9, ev.cookie)
	assert_strings_equal(c"abc", ev.name)
	assert_equal(3, ev.name_length)

	# No record starts at or past buf_end.
	assert_equal(-1, inotify_event_parse(buf, 24, 24, &ev))
	assert_equal(-1, inotify_event_parse(buf, 24, 25, &ev))
	assert_equal(-1, inotify_event_parse(buf, 24, -1, &ev))
	# Truncated header and truncated name are both rejected.
	assert_equal(-1, inotify_event_parse(buf, 15, 0, &ev))
	assert_equal(-1, inotify_event_parse(buf, 20, 0, &ev))
	free(buf)


void test_inotify_add_watch_missing_path_fails():
	int fd = inotify_init()
	it_assert_ok(c"inotify_init", fd)
	char* missing = it_path(it_root(), c"does_not_exist")
	asserts(c"watch on a missing path should fail", inotify_add_watch(fd, missing, IN_ALL_EVENTS()) < 0)
	close(fd)
	free(missing)
