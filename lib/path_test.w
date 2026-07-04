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
