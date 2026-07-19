# wbuild: x64
import lib.testing
import lib.stat
import lib.path
import lib.file


char* st_work_root


char* st_work():
	if (st_work_root == 0):
		st_work_root = c"bin/stat_test_work"
		mkdir(c"bin", 493)
		rmdir(st_work_root)
		assert_equal(0, mkdir(st_work_root, 493))
	return st_work_root


char* st_join(char* name):
	return path_join(st_work(), name)


void st_write(char* path, char* text):
	assert_equal(1, file_write_text(path, text))


void test_file_stat_regular_file():
	char* path = st_join(c"hello.txt")
	st_write(path, c"hello")
	assert_equal(0, file_chmod(path, 420))
	file_stat st
	assert_equal(0, file_stat_path(path, &st))
	assert_equal(1, file_is_reg(&st))
	assert_equal(0, file_is_dir(&st))
	assert_equal(0, file_is_lnk(&st))
	assert_equal(5, st.size)
	assert_equal(1, st.mtime > 0)
	assert_equal(420, file_mode_perm(&st))
	unlink(path)


void test_file_stat_directory():
	char* path = st_join(c"subdir")
	assert_equal(0, mkdir(path, 493))
	assert_equal(0, file_chmod(path, 493))
	file_stat st
	assert_equal(0, file_stat_path(path, &st))
	assert_equal(1, file_is_dir(&st))
	assert_equal(0, file_is_reg(&st))
	assert_equal(493, file_mode_perm(&st))
	rmdir(path)


void test_file_stat_missing():
	char* path = st_join(c"missing.txt")
	unlink(path)
	file_stat st
	assert_equal(0 - 2, file_stat_path(path, &st))


void test_file_chmod():
	char* path = st_join(c"chmod_me.txt")
	st_write(path, c"x")
	assert_equal(0, file_chmod(path, 384))
	file_stat st
	assert_equal(0, file_stat_path(path, &st))
	assert_equal(384, file_mode_perm(&st))
	unlink(path)


void test_file_touch_creates_and_updates():
	char* path = st_join(c"touch_me.txt")
	unlink(path)
	assert_equal(0, file_touch(path, 1))
	file_stat st
	assert_equal(0, file_stat_path(path, &st))
	assert_equal(1, file_is_reg(&st))
	assert_equal(0, st.size)
	int first_mtime = st.mtime
	assert_equal(0, file_touch(path, 0))
	assert_equal(0, file_stat_path(path, &st))
	assert_equal(1, st.mtime >= first_mtime)
	unlink(path)


void test_file_lstat_and_readlink():
	char* target = st_join(c"link_target.txt")
	char* linkpath = st_join(c"the_link")
	st_write(target, c"payload")
	unlink(linkpath)
	assert_equal(0, file_symlink(c"link_target.txt", linkpath))
	file_stat followed
	file_stat link_st
	assert_equal(0, file_stat_path(linkpath, &followed))
	assert_equal(1, file_is_reg(&followed))
	assert_equal(7, followed.size)
	assert_equal(0, file_lstat_path(linkpath, &link_st))
	assert_equal(1, file_is_lnk(&link_st))
	char* buf = malloc(256)
	int n = file_readlink(linkpath, buf, 256)
	assert_equal(1, n > 0)
	assert_equal(0, strcmp(buf, c"link_target.txt"))
	free(buf)
	unlink(linkpath)
	unlink(target)
