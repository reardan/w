# wbuild: x64
# Also executed natively by tools/mac/run_fs_tests.sh.
import lib.testing
import tools.host_tools
import libs.standard.fs.glob

void test_host_files_metadata_copy_glob_and_cleanup():
	# Absolute mkdir recursion must stop at existing directories, including /.
	ht_mkdir(c"/")
	char* root = ht_temp()
	char* nested = path_join(root, c"nested/deeper")
	ht_mkdir(nested)
	ht_mkdir(nested)
	assert_equal(1, shutil_is_dir(nested))
	char* original = path_join(nested, c"original")
	char* copied = path_join(nested, c"copied")
	char* link = path_join(root, c"link")
	ht_write(original, c"payload", 7)
	assert_equal(0, chmod(original, 493))
	assert_equal(0, shutil_copy(original, copied))
	file_stat st
	assert_equal(0, file_stat_path(copied, &st))
	assert_equal(7, st.size)
	assert_equal(493, file_mode_perm(&st))
	assert_equal(1, st.ino > 0 && st.mtime > 0)
	ht_equal_file(copied, c"payload")
	assert_equal(1, glob_glob(path_join(nested, c"cop*")).length)
	assert_equal(0, symlink(c"nested/deeper/copied", link))
	assert_equal(0, file_stat_path(link, &st))
	assert_equal(1, file_is_reg(&st))
	assert_equal(0, file_lstat_path(link, &st))
	assert_equal(1, file_is_lnk(&st))
	assert_equal(0, unlink(copied))
	assert_equal(-2, file_stat_path(link, &st))
	assert_equal(0, file_lstat_path(link, &st))
	assert_equal(1, file_is_lnk(&st))
	ht_cleanup()
	assert_equal(0, path_exists(root))
