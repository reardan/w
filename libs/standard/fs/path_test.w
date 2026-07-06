import lib.testing
import libs.standard.fs.path


void assert_fs_path(char* expected, char* actual):
	assert_strings_equal(expected, actual)
	free(actual)


void test_fs_path_join():
	assert_fs_path(c"tmp/file.txt", fs_path_join(c"tmp", c"file.txt"))
	assert_fs_path(c"/tmp/file.txt", fs_path_join(c"/tmp/", c"file.txt"))
	assert_fs_path(c"/var/log", fs_path_join(c"/tmp/base", c"/var/log"))
	assert_fs_path(c"file.txt", fs_path_join(c"", c"file.txt"))
	assert_fs_path(c"/tmp/", fs_path_join(c"/tmp", c""))
	assert_fs_path(c"", fs_path_join(c"", c""))


void test_fs_path_normpath_relative():
	assert_fs_path(c".", fs_path_normpath(c""))
	assert_fs_path(c".", fs_path_normpath(c"."))
	assert_fs_path(c".", fs_path_normpath(c"./"))
	assert_fs_path(c"a/b", fs_path_normpath(c"a//./b/"))
	assert_fs_path(c"b", fs_path_normpath(c"a/../b"))
	assert_fs_path(c"../b", fs_path_normpath(c"a/../../b"))
	assert_fs_path(c"../..", fs_path_normpath(c"../.."))
	assert_fs_path(c".", fs_path_normpath(c"a/.."))


void test_fs_path_normpath_absolute():
	assert_fs_path(c"/", fs_path_normpath(c"/"))
	assert_fs_path(c"/", fs_path_normpath(c"//"))
	assert_fs_path(c"/a/c", fs_path_normpath(c"/a//b/../c/."))
	assert_fs_path(c"/", fs_path_normpath(c"/.."))
	assert_fs_path(c"/b", fs_path_normpath(c"/a/../../b"))


void test_fs_path_basename():
	assert_fs_path(c"file.txt", fs_path_basename(c"/tmp/w/file.txt"))
	assert_fs_path(c"file.txt", fs_path_basename(c"file.txt"))
	assert_fs_path(c"", fs_path_basename(c"/tmp/w/"))
	assert_fs_path(c"", fs_path_basename(c"/"))
	assert_fs_path(c"", fs_path_basename(c""))


void test_fs_path_dirname():
	assert_fs_path(c"/tmp/w", fs_path_dirname(c"/tmp/w/file.txt"))
	assert_fs_path(c"/tmp/w", fs_path_dirname(c"/tmp/w/"))
	assert_fs_path(c"", fs_path_dirname(c"file.txt"))
	assert_fs_path(c"/", fs_path_dirname(c"/file.txt"))
	assert_fs_path(c"a", fs_path_dirname(c"a//b"))
	assert_fs_path(c"/", fs_path_dirname(c"//"))
	assert_fs_path(c"", fs_path_dirname(c""))


void test_fs_path_isabs():
	assert_equal(1, fs_path_isabs(c"/tmp"))
	assert_equal(0, fs_path_isabs(c"tmp"))
	assert_equal(0, fs_path_isabs(c""))


void test_fs_path_abspath():
	char* cwd = fs_path_abspath(c".")
	assert1(cwd != 0)
	assert_equal(1, fs_path_isabs(cwd))
	char* child = fs_path_abspath(c"libs/standard/fs/../fs/path.w")
	char* expected = fs_path_join(cwd, c"libs/standard/fs/path.w")
	assert_strings_equal(expected, child)
	free(cwd)
	free(child)
	free(expected)
