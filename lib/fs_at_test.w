# wbuild: x64 arch=arm64_darwin
# Confined descriptor-relative access (lib/fs_at.w): opens stay beneath
# the directory and refuse symlinks in any component, regular-file opens
# refuse directories and devices, rename/unlink take single names, and a
# directory opened here lists through dir_read_fd.
import lib.testing
import lib.fs_at
import lib.dir
import lib.file


char* fa_root = 0
int fa_fd = -1


char* fa_path(char* rel):
	return path_join(fa_root, rel)


# bin/fs_at_test_<pid>/ holding a.txt, sub/b.txt, a symlink link -> sub
# and file_link -> a.txt.
void fa_setup():
	string_builder* s = string_new()
	string_append(s, c"bin/fs_at_test_")
	string_append_int(s, getpid())
	fa_root = s.data
	dir_remove_all(fa_root)
	assert_equal(0, mkdir(fa_root, 493))
	assert_equal(0, mkdir(fa_path(c"sub"), 493))
	assert1(file_write_text(fa_path(c"a.txt"), c"alpha") != 0)
	assert1(file_write_text(fa_path(c"sub/b.txt"), c"beta") != 0)
	assert_equal(0, symlink(c"sub", fa_path(c"link")))
	assert_equal(0, symlink(c"a.txt", fa_path(c"file_link")))
	fa_fd = open(fa_root, FS_O_DIRECTORY | FS_O_CLOEXEC, 0)
	assert1(fa_fd >= 0)


# The regular file's contents through fs_at_open_regular, or 0.
char* fa_read(char* rel):
	file_stat st
	int fd = fs_at_open_regular(fa_fd, rel, &st)
	if (fd < 0): return 0
	char* text = cast(char*, malloc(st.size + 1))
	int count = read(fd, text, st.size)
	close(fd)
	if (count != st.size): return 0
	text[count] = 0
	return text


void test_fs_at_supported():
	fa_setup()
	assert_equal(1, fs_at_supported())


void test_fs_at_open_beneath_inside():
	int fd = fs_at_open_beneath(fa_fd, c"sub/b.txt", FS_O_RDONLY, 0)
	assert1(fd >= 0)
	close(fd)
	fd = fs_at_open_beneath(fa_fd, c".", FS_O_DIRECTORY, 0)
	assert1(fd >= 0)
	close(fd)
	# ".." that stays inside is still beneath the root.
	fd = fs_at_open_beneath(fa_fd, c"sub/../a.txt", FS_O_RDONLY, 0)
	assert1(fd >= 0)
	close(fd)
	assert_equal(-2, fs_at_open_beneath(fa_fd, c"missing", FS_O_RDONLY, 0))


void test_fs_at_open_beneath_refuses_escapes():
	assert1(fs_at_open_beneath(fa_fd, c"..", FS_O_DIRECTORY, 0) < 0)
	assert1(fs_at_open_beneath(fa_fd, c"sub/../..", FS_O_DIRECTORY, 0) < 0)
	assert1(fs_at_open_beneath(fa_fd, c"/", FS_O_DIRECTORY, 0) < 0)
	assert1(fs_at_open_beneath(fa_fd, c"/etc/hosts", FS_O_RDONLY, 0) < 0)


void test_fs_at_open_beneath_refuses_symlinks():
	assert1(fs_at_open_beneath(fa_fd, c"link/b.txt", FS_O_RDONLY, 0) < 0)
	assert1(fs_at_open_beneath(fa_fd, c"link", FS_O_DIRECTORY, 0) < 0)
	assert1(fs_at_open_beneath(fa_fd, c"file_link", FS_O_RDONLY, 0) < 0)
	assert1(fa_read(c"file_link") == 0)


void test_fs_at_open_regular():
	assert_strings_equal(c"alpha", fa_read(c"a.txt"))
	assert_strings_equal(c"beta", fa_read(c"sub/b.txt"))
	file_stat st
	assert_equal(-22, fs_at_open_regular(fa_fd, c"sub", &st))
	assert_equal(-2, fs_at_open_regular(fa_fd, c"missing", &st))
	# A device is refused without being read (/dev/null would read empty).
	int dev = open(c"/dev", FS_O_DIRECTORY | FS_O_CLOEXEC, 0)
	assert1(dev >= 0)
	assert_equal(-22, fs_at_open_regular(dev, c"null", &st))
	close(dev)


void test_fs_at_create_chmod_rename():
	int fd = fs_at_open_beneath(fa_fd, c"new.tmp", FS_O_WRONLY | FS_O_CREAT | FS_O_EXCL, 384)
	assert1(fd >= 0)
	assert_equal(5, write(fd, c"gamma", 5))
	assert_equal(0, fs_at_chmod(fd, 416))
	file_stat st
	assert_equal(0, fs_at_stat(fd, &st))
	assert_equal(416, file_mode_perm(&st))
	assert_equal(5, st.size)
	close(fd)
	assert1(fs_at_open_beneath(fa_fd, c"new.tmp", FS_O_WRONLY | FS_O_CREAT | FS_O_EXCL, 384) < 0)
	assert_equal(0, fs_at_rename(fa_fd, c"new.tmp", c"a.txt"))
	assert_strings_equal(c"gamma", fa_read(c"a.txt"))
	assert_equal(-2, fs_at_open_beneath(fa_fd, c"new.tmp", FS_O_RDONLY, 0))


void test_fs_at_leaf_only():
	assert_equal(-22, fs_at_rename(fa_fd, c"sub/b.txt", c"b.txt"))
	assert_equal(-22, fs_at_rename(fa_fd, c"a.txt", c"../a.txt"))
	assert_equal(-22, fs_at_unlink(fa_fd, c"sub/b.txt"))
	assert_equal(-22, fs_at_unlink(fa_fd, c".."))
	assert_equal(-22, fs_at_unlink(fa_fd, c""))
	assert_equal(0, fs_at_leaf(c"."))
	assert_equal(1, fs_at_leaf(c"..."))
	# Unlinking a symlink removes the link, not its target.
	assert_equal(0, fs_at_unlink(fa_fd, c"file_link"))
	assert_strings_equal(c"gamma", fa_read(c"a.txt"))


void test_fs_at_dir_read_fd():
	int fd = fs_at_open_beneath(fa_fd, c".", FS_O_DIRECTORY, 0)
	assert1(fd >= 0)
	list[dir_entry*] entries = dir_read_fd(fd)
	close(fd)
	assert1(entries != 0)
	assert_equal(3, entries.length)
	assert_strings_equal(c"a.txt", entries[0].name)
	assert_equal(DIR_KIND_FILE, entries[0].kind)
	assert_strings_equal(c"link", entries[1].name)
	assert_equal(DIR_KIND_LINK, entries[1].kind)
	assert_strings_equal(c"sub", entries[2].name)
	assert_equal(DIR_KIND_DIR, entries[2].kind)
	dir_entries_free(entries)
	fd = fs_at_open_beneath(fa_fd, c"a.txt", FS_O_RDONLY, 0)
	assert1(dir_read_fd(fd) == 0)
	close(fd)
	close(fa_fd)
	assert_equal(0, dir_remove_all(fa_root))
