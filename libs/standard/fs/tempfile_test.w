# wbuild: x64
# wbuild: step="bin/tempfile_test" env="W_TEST_LEAKS=1" expect_stdout="0 failed, 0 skipped [leak check]"
import lib.testing
import lib.stat
import lib.dir
import libs.standard.fs.tempfile


# A private sandbox under bin/ for one test; remove with tt_done.
char* tt_sandbox():
	char* dir = tempfile_mkdtemp_in(c"bin", c"tempfile_test_", 0)
	assert1(dir != 0)
	return dir


void tt_done(char* dir):
	assert_equal(0, dir_remove_all(dir))
	assert_equal(0, path_exists(dir))
	free(dir)


int tt_perm(char* path):
	file_stat st
	assert_equal(0, file_stat_path(path, &st))
	return file_mode_perm(&st)


int tt_is_dir(char* path):
	file_stat st
	if (file_stat_path(path, &st) != 0): return 0
	return file_is_dir(&st)


# The name part between prefix and suffix is 8 chars of [a-z0-9_].
void tt_check_name(char* path, char* dir, char* prefix, char* suffix):
	char* base = path_basename(path)
	char* parent = path_dirname(path)
	assert_strings_equal(dir, parent)
	int plen = strlen(prefix)
	int slen = strlen(suffix)
	assert_equal(plen + 8 + slen, strlen(base))
	assert1(starts_with(base, prefix))
	assert1(ends_with(base, suffix))
	int i = 0
	while (i < 8):
		int c = base[plen + i]
		assert1(((c >= 'a') && (c <= 'z')) || ((c >= '0') && (c <= '9')) || (c == '_'))
		i = i + 1
	free(base)
	free(parent)


void test_choose_dir_order():
	char* box = tt_sandbox()
	char* other = tempfile_mkdtemp_in(box, c"other", 0)
	char* got = tempfile_choose_dir(box, other, 0)
	assert_strings_equal(box, got)
	free(got)
	# Unset, empty and non-directory values are skipped in order.
	got = tempfile_choose_dir(0, other, box)
	assert_strings_equal(other, got)
	free(got)
	got = tempfile_choose_dir(c"", c"/no/such/dir/tempfile_test", box)
	assert_strings_equal(box, got)
	free(got)
	got = tempfile_choose_dir(0, 0, 0)
	assert_strings_equal(c"/tmp", got)
	free(got)
	# A regular file is not a usable directory.
	char* file = 0
	int fd = tempfile_mkstemp_in(box, 0, 0, &file)
	assert1(fd >= 0)
	close(fd)
	got = tempfile_choose_dir(file, 0, 0)
	assert_strings_equal(c"/tmp", got)
	free(got)
	free(file)
	free(other)
	tt_done(box)


void test_choose_dir_relative_is_absolute():
	char* got = tempfile_choose_dir(c"bin", 0, 0)
	assert_equal('/', got[0])
	assert1(ends_with(got, c"/bin"))
	assert1(tt_is_dir(got))
	free(got)


void test_gettempdir_is_directory():
	char* dir = tempfile_gettempdir()
	assert1(dir != 0)
	assert_equal('/', dir[0])
	assert1(tt_is_dir(dir))
	char* alias = temp_dir()
	assert_strings_equal(dir, alias)
	free(alias)
	free(dir)


void test_mkstemp_in_creates_private_file():
	char* box = tt_sandbox()
	char* path = 0
	int fd = tempfile_mkstemp_in(box, c"pre_", c".txt", &path)
	assert1(fd >= 0)
	assert1(path != 0)
	tt_check_name(path, box, c"pre_", c".txt")
	assert_equal(384, tt_perm(path))
	# The descriptor is open read-write on an empty file.
	assert_equal(5, write(fd, c"hello", 5))
	assert_equal(0, seek(fd, 0, 0))
	char* buf = cast(char*, malloc(8))
	assert_equal(5, read(fd, buf, 8))
	assert_equal('h', buf[0])
	free(buf)
	close(fd)
	free(path)
	tt_done(box)


void test_mkstemp_defaults():
	char* box = tt_sandbox()
	char* path = 0
	int fd = tempfile_mkstemp_in(box, 0, 0, &path)
	assert1(fd >= 0)
	tt_check_name(path, box, c"tmp", c"")
	close(fd)
	free(path)
	# path_out may be 0: the file is still created (the sandbox cleanup
	# finds it).
	fd = tempfile_mkstemp_in(box, c"anon", 0, 0)
	assert1(fd >= 0)
	close(fd)
	list[char*] names = dir_names(box)
	assert_equal(2, names.length)
	for char* n in names: free(n)
	list_free[char*](names)
	tt_done(box)


void test_mkstemp_names_unique():
	char* box = tt_sandbox()
	list[char*] paths = new list[char*]
	int i = 0
	while (i < 40):
		char* path = 0
		int fd = tempfile_mkstemp_in(box, c"u", 0, &path)
		assert1(fd >= 0)
		close(fd)
		paths.push(path)
		i = i + 1
	i = 0
	while (i < paths.length):
		int j = i + 1
		while (j < paths.length):
			assert1(strcmp(paths[i], paths[j]) != 0)
			j = j + 1
		i = i + 1
	for char* p in paths: free(p)
	list_free[char*](paths)
	tt_done(box)


void test_mkstemp_missing_dir_fails():
	char* path = c"sentinel"
	int fd = tempfile_mkstemp_in(c"/no/such/dir/tempfile_test", c"x", 0, &path)
	assert_equal(0 - 2, fd)
	assert1(path == 0)


void test_mkstemp_relative_dir_returns_absolute():
	char* box = tempfile_mkdtemp_in(c"bin", c"tempfile_rel_", 0)
	assert_equal('/', box[0])
	char* path = 0
	int fd = tempfile_mkstemp_in(c"bin", c"tempfile_rel_file_", 0, &path)
	assert1(fd >= 0)
	close(fd)
	assert_equal('/', path[0])
	char* parent = path_dirname(path)
	assert1(ends_with(parent, c"/bin"))
	free(parent)
	assert_equal(0, unlink(path))
	free(path)
	tt_done(box)


void test_mkstemp_default_dir():
	char* path = tempfile_mkstemp(c"w_tempfile_test_", c".tmp")
	assert1(path != 0)
	assert_equal(0, tempfile_last_error)
	char* dir = tempfile_gettempdir()
	tt_check_name(path, dir, c"w_tempfile_test_", c".tmp")
	assert_equal(384, tt_perm(path))
	assert_equal(0, unlink(path))
	free(dir)
	free(path)


void test_mkdtemp_in_creates_private_dir():
	char* box = tt_sandbox()
	char* dir = tempfile_mkdtemp_in(box, c"d_", c"_s")
	assert1(dir != 0)
	assert_equal(0, tempfile_last_error)
	tt_check_name(dir, box, c"d_", c"_s")
	assert1(tt_is_dir(dir))
	assert_equal(448, tt_perm(dir))
	char* second = tempfile_mkdtemp_in(box, c"d_", c"_s")
	assert1(strcmp(dir, second) != 0)
	free(second)
	free(dir)
	tt_done(box)


void test_mkdtemp_missing_dir_fails():
	tempfile_last_error = 0
	char* dir = tempfile_mkdtemp_in(c"/no/such/dir/tempfile_test", 0, 0)
	assert1(dir == 0)
	assert_equal(0 - 2, tempfile_last_error)


void test_mkdtemp_default_dir():
	char* dir = tempfile_mkdtemp(c"w_tempfile_test_")
	assert1(dir != 0)
	char* parent = tempfile_gettempdir()
	tt_check_name(dir, parent, c"w_tempfile_test_", c"")
	assert1(tt_is_dir(dir))
	assert_equal(0, rmdir(dir))
	free(parent)
	free(dir)


void test_random_name_shape():
	char* a = tempfile_random_name(c"p", c"s")
	char* b = tempfile_random_name(c"p", c"s")
	assert_equal(10, strlen(a))
	assert_equal('p', a[0])
	assert_equal('s', a[9])
	assert1(strcmp(a, b) != 0)
	free(a)
	free(b)
