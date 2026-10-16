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


void path_test_splitext(char* input, char* want_root, char* want_ext):
	char* root = 0
	char* ext = 0
	path_splitext(input, &root, &ext)
	assert_strings_equal(want_root, root)
	assert_strings_equal(want_ext, ext)
	free(root)
	free(ext)


void test_path_splitext():
	path_test_splitext(c"a.tar.gz", c"a.tar", c".gz")
	path_test_splitext(c"/x/y/file.txt", c"/x/y/file", c".txt")
	path_test_splitext(c".bashrc", c".bashrc", c"")
	path_test_splitext(c"/home/u/.bashrc", c"/home/u/.bashrc", c"")
	path_test_splitext(c"..", c"..", c"")
	path_test_splitext(c"...x", c"...x", c"")
	path_test_splitext(c"..a.b", c"..a", c".b")
	path_test_splitext(c"a..b", c"a.", c".b")
	path_test_splitext(c"foo.", c"foo", c".")
	path_test_splitext(c"a.b/c", c"a.b/c", c"")
	path_test_splitext(c"a.b/", c"a.b/", c"")
	path_test_splitext(c"noext", c"noext", c"")
	path_test_splitext(c"", c"", c"")


void path_test_stem_suffix(char* input, char* want_stem, char* want_suffix):
	char* stem = path_stem(input)
	char* suffix = path_suffix(input)
	assert_strings_equal(want_stem, stem)
	assert_strings_equal(want_suffix, suffix)
	free(stem)
	free(suffix)


void test_path_stem_suffix():
	path_test_stem_suffix(c"a/b.tar.gz", c"b.tar", c".gz")
	path_test_stem_suffix(c"/x/file.txt", c"file", c".txt")
	path_test_stem_suffix(c"file.txt/", c"file", c".txt")
	path_test_stem_suffix(c"a/b.c/./", c"b", c".c")
	path_test_stem_suffix(c".bashrc", c".bashrc", c"")
	path_test_stem_suffix(c"dir.d/plain", c"plain", c"")
	path_test_stem_suffix(c"foo.", c"foo", c".")
	path_test_stem_suffix(c"..", c"..", c"")
	path_test_stem_suffix(c"/", c"", c"")
	path_test_stem_suffix(c".", c"", c"")
	path_test_stem_suffix(c"", c"", c"")


void path_test_rel(char* path, char* base, char* expected):
	char* got = path_relative_to(path, base)
	if (expected == 0):
		assert_equal(0, cast(int, got))
		return
	assert_strings_equal(expected, got)
	free(got)


void test_path_relative_to():
	path_test_rel(c"/etc/passwd", c"/etc", c"passwd")
	path_test_rel(c"/etc/a/b", c"/etc/", c"a/b")
	path_test_rel(c"/etc", c"/etc", c".")
	path_test_rel(c"/etc/", c"/etc", c".")
	path_test_rel(c"/etc/x", c"/", c"etc/x")
	path_test_rel(c"/", c"/", c".")
	path_test_rel(c"a/b/c", c"a", c"b/c")
	path_test_rel(c"a/./b/../c/", c"a", c"c")
	path_test_rel(c"a/b", c".", c"a/b")
	path_test_rel(c".", c".", c".")
	path_test_rel(c"/usr", c"/etc", 0)
	path_test_rel(c"/etcx", c"/etc", 0)
	path_test_rel(c"a", c"/a", 0)
	path_test_rel(c"/a", c"a", 0)
	path_test_rel(c"..", c".", 0)
	path_test_rel(c"a/../../b", c".", 0)


void test_path_is_absolute():
	assert_equal(1, path_is_absolute(c"/"))
	assert_equal(1, path_is_absolute(c"/usr/bin"))
	assert_equal(1, path_is_absolute(c"C:/x"))
	assert_equal(1, path_is_absolute(c"c:"))
	assert_equal(0, path_is_absolute(c""))
	assert_equal(0, path_is_absolute(c"usr/bin"))
	assert_equal(0, path_is_absolute(c"./x"))
	assert_equal(0, path_is_absolute(c"~/x"))
	assert_equal(0, path_is_absolute(c"1:x"))


void path_test_expand(char* input, char* expected):
	char* got = path_expand_user(input)
	assert_strings_equal(expected, got)
	free(got)


# Runs path_expand_user against a private two-entry environment vector,
# restoring the process environment afterwards.
void path_test_expand_with_home(char* home_entry, char* input, char* expected):
	int saved = environ_ptr
	char** envp = cast(char**, malloc(3 * __word_size__))
	envp[0] = c"PATH=/bin"
	envp[1] = home_entry
	envp[2] = 0
	environ_ptr = cast(int, envp)
	char* got = path_expand_user(input)
	environ_ptr = saved
	free(cast(void*, envp))
	assert_strings_equal(expected, got)
	free(got)


void test_path_expand_user():
	path_test_expand_with_home(c"HOME=/home/u", c"~", c"/home/u")
	path_test_expand_with_home(c"HOME=/home/u", c"~/src/w", c"/home/u/src/w")
	path_test_expand_with_home(c"HOME=/home/u/", c"~/x", c"/home/u/x")
	path_test_expand_with_home(c"HOME=/", c"~", c"/")
	path_test_expand_with_home(c"HOME=/", c"~/x", c"/x")
	path_test_expand_with_home(c"HOME=", c"~/x", c"/x")
	path_test_expand_with_home(c"HOME=/home/u", c"~other/x", c"~other/x")
	path_test_expand_with_home(c"HOME=/home/u", c"a/~/b", c"a/~/b")
	path_test_expand_with_home(c"HOME=/home/u", c"", c"")
	# HOME unset: unchanged.
	path_test_expand_with_home(c"USER=u", c"~/x", c"~/x")
	path_test_expand(c"/abs/path", c"/abs/path")


void path_test_parts(char* input, int count, char* p0, char* p1, char* p2, char* p3):
	list[char*] parts = path_split_parts(input)
	assert_equal(count, parts.length)
	char** want = cast(char**, malloc(4 * __word_size__))
	want[0] = p0
	want[1] = p1
	want[2] = p2
	want[3] = p3
	int i = 0
	for char* part in parts:
		if (i < 4): assert_strings_equal(want[i], part)
		i = i + 1
	free(cast(void*, want))
	path_parts_free(parts)


void test_path_split_parts():
	path_test_parts(c"/usr/bin/w", 4, c"/", c"usr", c"bin", c"w")
	path_test_parts(c"a//./b/../c/", 4, c"a", c"b", c"..", c"c")
	path_test_parts(c"/", 1, c"/", 0, 0, 0)
	path_test_parts(c"", 0, 0, 0, 0, 0)
	path_test_parts(c".", 0, 0, 0, 0, 0)
	path_test_parts(c"./x", 1, c"x", 0, 0, 0)
	path_test_parts(c"//a", 2, c"/", c"a", 0, 0)
