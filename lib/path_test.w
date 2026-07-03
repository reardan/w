import lib.testing
import lib.path


void test_path_join_relative():
	char* joined = path_join("tmp", "file.txt")
	assert_strings_equal("tmp/file.txt", joined)
	free(joined)


void test_path_join_existing_separator():
	char* joined = path_join("/tmp/", "file.txt")
	assert_strings_equal("/tmp/file.txt", joined)
	free(joined)

	joined = path_join("/", "x")
	assert_strings_equal("/x", joined)
	free(joined)


void test_path_join_absolute_right():
	char* joined = path_join("/tmp/base", "/var/log")
	assert_strings_equal("/var/log", joined)
	free(joined)


void test_path_join_empty_parts():
	char* joined = path_join("", "file.txt")
	assert_strings_equal("file.txt", joined)
	free(joined)

	joined = path_join("/tmp", "")
	assert_strings_equal("/tmp", joined)
	free(joined)


void test_path_basename():
	char* base = path_basename("/tmp/w/file.txt")
	assert_strings_equal("file.txt", base)
	free(base)

	base = path_basename("file.txt")
	assert_strings_equal("file.txt", base)
	free(base)

	base = path_basename(".")
	assert_strings_equal(".", base)
	free(base)

	base = path_basename("..")
	assert_strings_equal("..", base)
	free(base)

	base = path_basename("/tmp/w/")
	assert_strings_equal("w", base)
	free(base)

	base = path_basename("/")
	assert_strings_equal("/", base)
	free(base)

	base = path_basename("")
	assert_strings_equal(".", base)
	free(base)


void test_path_dirname():
	char* dir = path_dirname("/tmp/w/file.txt")
	assert_strings_equal("/tmp/w", dir)
	free(dir)

	dir = path_dirname("/tmp/w/")
	assert_strings_equal("/tmp", dir)
	free(dir)

	dir = path_dirname("file.txt")
	assert_strings_equal(".", dir)
	free(dir)

	dir = path_dirname("/file.txt")
	assert_strings_equal("/", dir)
	free(dir)

	dir = path_dirname("a//b")
	assert_strings_equal("a", dir)
	free(dir)

	dir = path_dirname("//")
	assert_strings_equal("/", dir)
	free(dir)

	dir = path_dirname("")
	assert_strings_equal(".", dir)
	free(dir)


void test_path_exists():
	assert_equal(1, path_exists("lib/path.w"))
	assert_equal(1, path_exists("."))
	assert_equal(0, path_exists("/tmp/w_path_helpers_missing_file_11aa"))
