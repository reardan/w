# wbuild: x64 group=arm64_smoke_test@arm64
import lib.testing
import lib.dir
import lib.file


char* dt_root = 0


char* dt_path(char* rel):
	return path_join(dt_root, rel)


void dt_write(char* rel):
	assert1(file_write_text(dt_path(rel), rel) != 0)


# bin/dir_test_<pid>/ holding b.txt, a/{z.w, y/x.w}, c/ (empty) and a
# symlink l -> a.
void dt_setup():
	string_builder* s = string_new()
	string_append(s, c"bin/dir_test_")
	string_append_int(s, getpid())
	dt_root = s.data
	dir_remove_all(dt_root)
	assert_equal(0, mkdir(dt_root, 493))
	assert_equal(0, mkdir(dt_path(c"a"), 493))
	assert_equal(0, mkdir(dt_path(c"a/y"), 493))
	assert_equal(0, mkdir(dt_path(c"c"), 493))
	dt_write(c"b.txt")
	dt_write(c"a/z.w")
	dt_write(c"a/y/x.w")
	assert_equal(0, symlink(c"a", dt_path(c"l")))


void test_dir_read_sorted_kinds():
	dt_setup()
	list[dir_entry*] entries = dir_read(dt_root)
	assert1(entries != 0)
	assert_equal(4, entries.length)
	assert_strings_equal(c"a", entries[0].name)
	assert_equal(DIR_KIND_DIR, entries[0].kind)
	assert_strings_equal(c"b.txt", entries[1].name)
	assert_equal(DIR_KIND_FILE, entries[1].kind)
	assert_strings_equal(c"c", entries[2].name)
	assert_equal(DIR_KIND_DIR, entries[2].kind)
	assert_strings_equal(c"l", entries[3].name)
	assert_equal(DIR_KIND_LINK, entries[3].kind)
	dir_entries_free(entries)


void test_dir_read_missing_and_empty():
	assert1(dir_read(dt_path(c"missing")) == 0)
	assert1(dir_read(dt_path(c"b.txt")) == 0)
	list[char*] names = dir_names(dt_path(c"c"))
	assert1(names != 0)
	assert_equal(0, names.length)


void test_dir_walk_files():
	list[char*] files = new list[char*]
	dir_walk_files(dt_root, files)
	assert_equal(3, files.length)
	assert_strings_equal(dt_path(c"a/y/x.w"), files[0])
	assert_strings_equal(dt_path(c"a/z.w"), files[1])
	assert_strings_equal(dt_path(c"b.txt"), files[2])


void test_dir_remove_all():
	# A symlink to a directory goes, not the directory behind it.
	assert_equal(0, dir_remove_all(dt_path(c"l")))
	assert1(path_exists(dt_path(c"a/z.w")))
	assert_equal(0, dir_remove_all(dt_path(c"b.txt")))
	assert_equal(0, path_exists(dt_path(c"b.txt")))
	assert_equal(0, dir_remove_all(dt_root))
	assert_equal(0, path_exists(dt_root))
	# Missing is success.
	assert_equal(0, dir_remove_all(dt_root))
