# wbuild: x64
# wbuild: step="bin/path_test" env="W_TEST_LEAKS=1" expect_stdout="0 failed, 0 skipped [leak check]"
import lib.testing
import lib.path


void test_path_join_relative():
	char* joined = path_join(c"tmp", c"file.txt")
	assert_strings_equal(c"tmp/file.txt", joined)
	free(joined)


void test_path_join_existing_separator():
	char* joined = path_join(c"/tmp/", c"file.txt")
	assert_strings_equal(c"/tmp/file.txt", joined)
	free(joined)

	joined = path_join(c"/", c"x")
	assert_strings_equal(c"/x", joined)
	free(joined)


void test_path_join_absolute_right():
	char* joined = path_join(c"/tmp/base", c"/var/log")
	assert_strings_equal(c"/var/log", joined)
	free(joined)


void test_path_join_empty_parts():
	char* joined = path_join(c"", c"file.txt")
	assert_strings_equal(c"file.txt", joined)
	free(joined)

	joined = path_join(c"/tmp", c"")
	assert_strings_equal(c"/tmp", joined)
	free(joined)


void path_test_norm(char* input, char* expected):
	char* got = path_normalize(input)
	assert_strings_equal(expected, got)
	free(got)


void test_path_normalize():
	path_test_norm(c"", c".")
	path_test_norm(c".", c".")
	path_test_norm(c"./", c".")
	path_test_norm(c"/", c"/")
	path_test_norm(c"//", c"/")
	path_test_norm(c"a//b/./c", c"a/b/c")
	path_test_norm(c"a/b/../c", c"a/c")
	path_test_norm(c"a/..", c".")
	path_test_norm(c"a/../..", c"..")
	path_test_norm(c"../a/../../b", c"../../b")
	path_test_norm(c"/..", c"/")
	path_test_norm(c"/../../etc", c"/etc")
	path_test_norm(c"/srv/static/../../etc/passwd", c"/etc/passwd")
	path_test_norm(c"a/b/", c"a/b/")
	path_test_norm(c"a/b/..", c"a")
	path_test_norm(c"a/b/../", c"a/")
	path_test_norm(c"...", c"...")
	path_test_norm(c"a/..b/.c", c"a/..b/.c")


void test_path_join_normalizes():
	char* joined = path_join(c"/srv/static", c"../../etc/passwd")
	assert_strings_equal(c"/etc/passwd", joined)
	free(joined)

	joined = path_join(c"/srv/static/", c"./css/../index.html")
	assert_strings_equal(c"/srv/static/index.html", joined)
	free(joined)

	joined = path_join(c"bin", c"../tools/x")
	assert_strings_equal(c"tools/x", joined)
	free(joined)

	joined = path_join(c".", c"../x")
	assert_strings_equal(c"../x", joined)
	free(joined)


void test_path_is_within():
	assert_equal(1, path_is_within(c"/srv/static", c"/srv/static"))
	assert_equal(1, path_is_within(c"/srv/static", c"/srv/static/a/b"))
	assert_equal(1, path_is_within(c"/srv/static/", c"/srv/static/a/../b"))
	assert_equal(0, path_is_within(c"/srv/static", c"/srv/staticx"))
	assert_equal(0, path_is_within(c"/srv/static", c"/srv/static/../x"))
	assert_equal(0, path_is_within(c"/srv/static", c"/etc/passwd"))
	assert_equal(1, path_is_within(c"/", c"/etc"))
	assert_equal(0, path_is_within(c"/", c"etc"))
	assert_equal(1, path_is_within(c".", c"a/b"))
	assert_equal(0, path_is_within(c".", c"a/../../b"))
	assert_equal(0, path_is_within(c".", c"/a"))
	assert_equal(1, path_is_within(c"static", c"static/a"))
	assert_equal(0, path_is_within(c"static", c"static/../a"))


void test_path_join_within():
	char* p = path_join_within(c"/srv/static", c"/css/site.css")
	assert_strings_equal(c"/srv/static/css/site.css", p)
	free(p)

	p = path_join_within(c"/srv/static", c"a/../b.txt")
	assert_strings_equal(c"/srv/static/b.txt", p)
	free(p)

	assert_equal(0, cast(int, path_join_within(c"/srv/static", c"../../etc/passwd")))
	assert_equal(0, cast(int, path_join_within(c"/srv/static", c"/../etc/passwd")))
	assert_equal(0, cast(int, path_join_within(c"/srv/static", c"a/../../static2/x")))
	assert_equal(0, cast(int, path_join_within(c"static", c"..")))


void test_path_basename():
	char* base = path_basename(c"/tmp/w/file.txt")
	assert_strings_equal(c"file.txt", base)
	free(base)

	base = path_basename(c"file.txt")
	assert_strings_equal(c"file.txt", base)
	free(base)

	base = path_basename(c".")
	assert_strings_equal(c".", base)
	free(base)

	base = path_basename(c"..")
	assert_strings_equal(c"..", base)
	free(base)

	base = path_basename(c"/tmp/w/")
	assert_strings_equal(c"w", base)
	free(base)

	base = path_basename(c"/")
	assert_strings_equal(c"/", base)
	free(base)

	base = path_basename(c"")
	assert_strings_equal(c".", base)
	free(base)


void test_path_dirname():
	char* dir = path_dirname(c"/tmp/w/file.txt")
	assert_strings_equal(c"/tmp/w", dir)
	free(dir)

	dir = path_dirname(c"/tmp/w/")
	assert_strings_equal(c"/tmp", dir)
	free(dir)

	dir = path_dirname(c"file.txt")
	assert_strings_equal(c".", dir)
	free(dir)

	dir = path_dirname(c"/file.txt")
	assert_strings_equal(c"/", dir)
	free(dir)

	dir = path_dirname(c"a//b")
	assert_strings_equal(c"a", dir)
	free(dir)

	dir = path_dirname(c"//")
	assert_strings_equal(c"/", dir)
	free(dir)

	dir = path_dirname(c"")
	assert_strings_equal(c".", dir)
	free(dir)


void test_path_exists():
	assert_equal(1, path_exists(c"lib/path.w"))
	assert_equal(1, path_exists(c"."))
	assert_equal(0, path_exists(c"/tmp/w_path_helpers_missing_file_11aa"))
