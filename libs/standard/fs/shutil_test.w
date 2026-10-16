# wbuild: x64
# wbuild: step="bin/shutil_test" env="W_TEST_LEAKS=1" expect_stdout="0 failed, 0 skipped [leak check]"
import lib.testing
import lib.file
import libs.standard.fs.tempfile
import libs.standard.fs.shutil


# A private mkdtemp sandbox under bin/ for one test; remove with st_done.
char* st_sandbox():
	char* dir = tempfile_mkdtemp_in(c"bin", c"shutil_test_", 0)
	assert1(dir != 0)
	return dir


void st_done(char* dir):
	assert_equal(0, dir_remove_all(dir))
	assert_equal(0, path_exists(dir))
	free(dir)


# box/rel, malloc'd.
char* st_path(char* box, char* rel):
	return path_join(box, rel)


void st_write(char* box, char* rel, char* text):
	char* p = st_path(box, rel)
	assert1(file_write_text(p, text))
	free(p)


void st_mkdir(char* box, char* rel, int mode):
	char* p = st_path(box, rel)
	assert_equal(0, mkdir(p, mode))
	free(p)


# Asserts box/rel holds exactly text.
void st_expect(char* box, char* rel, char* text):
	char* p = st_path(box, rel)
	char* got = file_read_text(p)
	assert1(got != 0)
	assert_equal(strlen(text), strlen(got))
	assert_strings_equal(text, got)
	free(got)
	free(p)


int st_exists(char* box, char* rel):
	char* p = st_path(box, rel)
	file_stat st
	int ok = file_lstat_path(p, &st) == 0
	free(p)
	return ok


int st_perm(char* box, char* rel):
	char* p = st_path(box, rel)
	file_stat st
	assert_equal(0, file_stat_path(p, &st))
	free(p)
	return file_mode_perm(&st)


int st_lkind_is_reg(char* box, char* rel):
	char* p = st_path(box, rel)
	file_stat st
	assert_equal(0, file_lstat_path(p, &st))
	free(p)
	return file_is_reg(&st)


# n bytes of a non-zero repeating pattern (NUL-terminated).
char* st_pattern(int n):
	char* s = cast(char*, malloc(n + 1))
	int i = 0
	while (i < n):
		s[i] = 1 + (i % 251)
		i = i + 1
	s[n] = 0
	return s


void st_copy_with(int strategy, int size):
	char* box = st_sandbox()
	char* text = st_pattern(size)
	st_write(box, c"src", text)
	char* src = st_path(box, c"src")
	char* dst = st_path(box, c"dst")
	assert_equal(0, shutil_copyfile_with(src, dst, strategy))
	st_expect(box, c"dst", text)
	if (strategy == SHUTIL_COPY_READ_WRITE): assert_equal(SHUTIL_COPY_READ_WRITE, shutil_last_copy_method)
	assert1((shutil_last_copy_method >= SHUTIL_COPY_RANGE) && (shutil_last_copy_method <= SHUTIL_COPY_READ_WRITE))
	free(src)
	free(dst)
	free(text)
	st_done(box)


void test_copyfile_each_strategy():
	st_copy_with(SHUTIL_COPY_AUTO, 200000)
	st_copy_with(SHUTIL_COPY_RANGE, 200000)
	st_copy_with(SHUTIL_COPY_SENDFILE, 200000)
	st_copy_with(SHUTIL_COPY_READ_WRITE, 200000)
	st_copy_with(SHUTIL_COPY_READ_WRITE, 65536)
	st_copy_with(SHUTIL_COPY_AUTO, 1)


void test_copyfile_fast_path_used_on_linux():
	# copy_file_range or sendfile handles a regular file on every Linux
	# kernel the tests run on; read/write is only the fallback.
	char* box = st_sandbox()
	st_write(box, c"src", c"fast path contents")
	char* src = st_path(box, c"src")
	char* dst = st_path(box, c"dst")
	assert_equal(0, shutil_copyfile(src, dst))
	assert1(shutil_last_copy_method != SHUTIL_COPY_READ_WRITE)
	assert_equal(0, shutil_copyfile_with(src, dst, SHUTIL_COPY_SENDFILE))
	assert_equal(SHUTIL_COPY_SENDFILE, shutil_last_copy_method)
	st_expect(box, c"dst", c"fast path contents")
	free(src)
	free(dst)
	st_done(box)


void test_copyfile_empty_falls_back():
	char* box = st_sandbox()
	st_write(box, c"empty", c"")
	char* src = st_path(box, c"empty")
	char* dst = st_path(box, c"copy")
	assert_equal(0, shutil_copyfile(src, dst))
	assert_equal(SHUTIL_COPY_READ_WRITE, shutil_last_copy_method)
	st_expect(box, c"copy", c"")
	free(src)
	free(dst)
	st_done(box)


void test_copyfile_procfs_falls_back():
	# /proc files report size 0 and copy_file_range copies nothing; the
	# copy must still carry their contents (Python's procfs case).
	char* box = st_sandbox()
	char* dst = st_path(box, c"status")
	assert_equal(0, shutil_copyfile(c"/proc/self/status", dst))
	char* got = file_read_text(dst)
	assert1(got != 0)
	assert1(starts_with(got, c"Name:"))
	free(got)
	free(dst)
	st_done(box)


void test_copyfile_truncates_existing_dst():
	char* box = st_sandbox()
	st_write(box, c"src", c"short")
	st_write(box, c"dst", c"a much longer previous body")
	char* src = st_path(box, c"src")
	char* dst = st_path(box, c"dst")
	assert_equal(0, shutil_copyfile(src, dst))
	st_expect(box, c"dst", c"short")
	free(src)
	free(dst)
	st_done(box)


void test_copyfile_errors():
	char* box = st_sandbox()
	st_write(box, c"f", c"x")
	st_mkdir(box, c"d", 493)
	char* f = st_path(box, c"f")
	char* d = st_path(box, c"d")
	char* missing = st_path(box, c"missing")
	char* out = st_path(box, c"out")
	char* bad_dst = st_path(box, c"no/such/out")
	assert_equal(0 - 2, shutil_copyfile(missing, out))
	assert_equal(0 - 21, shutil_copyfile(d, out))
	assert_equal(0 - 21, shutil_copyfile(f, d))
	assert_equal(0 - 22, shutil_copyfile(f, f))
	assert_equal(0 - 2, shutil_copyfile(f, bad_dst))
	assert_equal(0, st_exists(box, c"out"))
	free(f)
	free(d)
	free(missing)
	free(out)
	free(bad_dst)
	st_done(box)


void test_copymode_and_copy():
	char* box = st_sandbox()
	st_write(box, c"tool", c"#!/bin/sh\n")
	char* tool = st_path(box, c"tool")
	assert_equal(0, chmod(tool, 489))     # 0751
	char* plain = st_path(box, c"plain")
	assert_equal(0, shutil_copyfile(tool, plain))
	assert1(st_perm(box, c"plain") != 489)
	assert_equal(0, shutil_copymode(tool, plain))
	assert_equal(489, st_perm(box, c"plain"))
	# shutil_copy into a directory keeps the basename and the mode.
	st_mkdir(box, c"bin", 493)
	char* bindir = st_path(box, c"bin")
	assert_equal(0, shutil_copy(tool, bindir))
	st_expect(box, c"bin/tool", c"#!/bin/sh\n")
	assert_equal(489, st_perm(box, c"bin/tool"))
	# ... and to an explicit file name.
	char* named = st_path(box, c"bin/renamed")
	assert_equal(0, shutil_copy(tool, named))
	assert_equal(489, st_perm(box, c"bin/renamed"))
	char* missing = st_path(box, c"missing")
	assert_equal(0 - 2, shutil_copymode(missing, plain))
	assert_equal(0 - 2, shutil_copy(missing, bindir))
	free(missing)
	free(named)
	free(bindir)
	free(plain)
	free(tool)
	st_done(box)


# src/{top.txt, a/{b/c.txt, exec.sh (0700)}, empty/ (0750), link -> top.txt}
char* st_tree(char* box):
	st_mkdir(box, c"src", 493)
	st_write(box, c"src/top.txt", c"top")
	st_mkdir(box, c"src/a", 493)
	st_mkdir(box, c"src/a/b", 493)
	st_write(box, c"src/a/b/c.txt", c"deep")
	st_write(box, c"src/a/exec.sh", c"run")
	char* exec = st_path(box, c"src/a/exec.sh")
	assert_equal(0, chmod(exec, 448))
	free(exec)
	st_mkdir(box, c"src/empty", 488)
	char* link = st_path(box, c"src/link")
	assert_equal(0, symlink(c"top.txt", link))
	free(link)
	return st_path(box, c"src")


void test_copytree_copies_everything():
	char* box = st_sandbox()
	char* src = st_tree(box)
	char* dst = st_path(box, c"dst")
	assert_equal(0, shutil_copytree(src, dst))
	st_expect(box, c"dst/top.txt", c"top")
	st_expect(box, c"dst/a/b/c.txt", c"deep")
	st_expect(box, c"dst/a/exec.sh", c"run")
	assert_equal(448, st_perm(box, c"dst/a/exec.sh"))
	assert_equal(488, st_perm(box, c"dst/empty"))
	# The symlink is followed: a regular file with the target's bytes.
	st_expect(box, c"dst/link", c"top")
	assert1(st_lkind_is_reg(box, c"dst/link"))
	# The source is untouched.
	st_expect(box, c"src/a/b/c.txt", c"deep")
	free(src)
	free(dst)
	st_done(box)


void test_copytree_errors():
	char* box = st_sandbox()
	char* src = st_tree(box)
	st_mkdir(box, c"exists", 493)
	char* exists = st_path(box, c"exists")
	char* missing = st_path(box, c"missing")
	char* file = st_path(box, c"src/top.txt")
	char* out = st_path(box, c"out")
	assert_equal(0 - 17, shutil_copytree(src, exists))
	assert_equal(0 - 2, shutil_copytree(missing, out))
	assert_equal(0 - 20, shutil_copytree(file, out))
	assert_equal(0, st_exists(box, c"out"))
	free(src)
	free(exists)
	free(missing)
	free(file)
	free(out)
	st_done(box)


void test_rmtree_refuses_dangerous_roots():
	assert_equal(0 - 22, shutil_rmtree(c""))
	assert_equal(0 - 22, shutil_rmtree(c"/"))
	assert_equal(0 - 22, shutil_rmtree(c"//"))
	assert_equal(0 - 22, shutil_rmtree(c"."))
	assert_equal(0 - 22, shutil_rmtree(c"./"))
	assert_equal(0 - 22, shutil_rmtree(c".."))
	assert_equal(0 - 22, shutil_rmtree(c"a/.."))
	assert_equal(0 - 22, shutil_rmtree(0))
	assert1(path_exists(c"lib/lib.w"))


void test_rmtree_removes_tree_not_link_targets():
	char* box = st_sandbox()
	char* src = st_tree(box)
	st_mkdir(box, c"keep", 493)
	st_write(box, c"keep/precious", c"safe")
	char* keep = st_path(box, c"keep")
	char* link = st_path(box, c"src/a/keep_link")
	assert_equal(0, symlink(keep, link))
	assert_equal(0, shutil_rmtree(src))
	assert_equal(0, st_exists(box, c"src"))
	st_expect(box, c"keep/precious", c"safe")
	free(keep)
	free(link)
	free(src)
	st_done(box)


void test_rmtree_errors():
	char* box = st_sandbox()
	st_write(box, c"file", c"x")
	st_mkdir(box, c"dir", 493)
	char* file = st_path(box, c"file")
	char* dir = st_path(box, c"dir")
	char* link = st_path(box, c"dirlink")
	char* missing = st_path(box, c"missing")
	assert_equal(0, symlink(dir, link))
	assert_equal(0 - 2, shutil_rmtree(missing))
	assert_equal(0 - 20, shutil_rmtree(file))
	assert_equal(0 - 20, shutil_rmtree(link))
	assert1(st_exists(box, c"file"))
	assert1(st_exists(box, c"dir"))
	assert1(st_exists(box, c"dirlink"))
	free(file)
	free(dir)
	free(link)
	free(missing)
	st_done(box)


void test_move_file_and_into_dir():
	char* box = st_sandbox()
	st_write(box, c"a.txt", c"alpha")
	st_mkdir(box, c"d", 493)
	char* a = st_path(box, c"a.txt")
	char* b = st_path(box, c"b.txt")
	char* d = st_path(box, c"d")
	assert_equal(0, shutil_move(a, b))
	assert_equal(0, st_exists(box, c"a.txt"))
	st_expect(box, c"b.txt", c"alpha")
	assert_equal(0, shutil_move(b, d))
	st_expect(box, c"d/b.txt", c"alpha")
	# A same-named entry already in the directory is not overwritten.
	st_write(box, c"b.txt", c"second")
	assert_equal(0 - 17, shutil_move(b, d))
	st_expect(box, c"d/b.txt", c"alpha")
	st_expect(box, c"b.txt", c"second")
	free(a)
	free(b)
	free(d)
	st_done(box)


void test_move_directory():
	char* box = st_sandbox()
	char* src = st_tree(box)
	char* moved = st_path(box, c"moved")
	char* inner = st_path(box, c"moved/a/inside")
	assert_equal(0, shutil_move(src, moved))
	assert_equal(0, st_exists(box, c"src"))
	st_expect(box, c"moved/a/b/c.txt", c"deep")
	# Never into itself.
	assert_equal(0 - 22, shutil_move(moved, inner))
	st_expect(box, c"moved/a/b/c.txt", c"deep")
	char* missing = st_path(box, c"missing")
	assert_equal(0 - 2, shutil_move(missing, src))
	free(missing)
	free(inner)
	free(moved)
	free(src)
	st_done(box)


void test_move_copy_fallback():
	# The EXDEV branch of shutil_move, driven directly (the test cannot
	# rely on two filesystems being available).
	char* box = st_sandbox()
	char* src = st_tree(box)
	char* dst = st_path(box, c"copied")
	assert_equal(0, shutil_move_copy(src, dst))
	assert_equal(0, st_exists(box, c"src"))
	st_expect(box, c"copied/a/b/c.txt", c"deep")
	assert_equal(448, st_perm(box, c"copied/a/exec.sh"))
	char* f = st_path(box, c"copied/a/exec.sh")
	char* g = st_path(box, c"exec_moved")
	assert_equal(0, shutil_move_copy(f, g))
	assert_equal(0, st_exists(box, c"copied/a/exec.sh"))
	st_expect(box, c"exec_moved", c"run")
	assert_equal(448, st_perm(box, c"exec_moved"))
	free(f)
	free(g)
	free(src)
	free(dst)
	st_done(box)


void test_disk_usage():
	char* box = st_sandbox()
	shutil_usage u
	assert_equal(0, shutil_disk_usage(box, &u))
	assert1(u.block_size > 0)
	assert1(u.total_blocks > 0)
	assert1(u.total > 0)
	assert1(u.free <= u.total)
	assert1(u.used <= u.total)
	assert1(u.used >= 0)
	assert1(u.avail_blocks <= u.free_blocks)
	char* missing = st_path(box, c"missing")
	assert_equal(0 - 2, shutil_disk_usage(missing, &u))
	free(missing)
	st_done(box)


void test_blocks_to_bytes_clamps():
	assert_equal(0, shutil_blocks_to_bytes(0, 4096))
	assert_equal(0, shutil_blocks_to_bytes(-1, 4096))
	assert_equal(8192, shutil_blocks_to_bytes(2, 4096))
	int max = (1 << ((__word_size__ * 8) - 2)) - 1
	max = max + max + 1
	assert_equal(max, shutil_blocks_to_bytes(max / 2, 4096))
