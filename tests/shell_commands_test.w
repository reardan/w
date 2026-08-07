# wbuild: x64
/*
Unit tests for the REPL shell mode MVP (issue #335,
docs/projects/repl_shell_mode.md): the pure translation logic in
repl/shell_translate.w (recognition test, tokenizer, flag/positional
mapping, code generation) and the native tools themselves in
lib/shell_commands.w, exercised directly -- no REPL process involved.
The scripted end-to-end coverage (":sh" toggle, prompt change, the '!'
round trip, cd/export, native fallback) lives in build.base.json's
repl_test/repl_test_x64.
*/
import lib.testing
import lib.shell_commands
import repl.shell_translate
import lib.file
import lib.path
import lib.str
import lib.stat


# ---------------------------------------------------------------------------
# Scratch files/dirs, one set per process (getpid()-suffixed so the x86
# and x64 twins, or two local runs, never collide on the same path).

char* shtest_scratch_path(char* suffix):
	char* pid_str = itoa(getpid())
	char* base = strjoin(c"/tmp/w_shell_commands_test_", pid_str)
	free(pid_str)
	char* full = strjoin(base, suffix)
	free(base)
	return full


# ---------------------------------------------------------------------------
# Capture a native tool's own stdout/stderr writes: redirect the real fd
# to a scratch file for the span of the call, then read it back. Mirrors
# repl.w's repl_eval_json capture (same saved-fd-above-90 idiom).

int shtest_saved_stdout
int shtest_saved_stderr

void shtest_capture_stdout_start(char* path):
	shtest_saved_stdout = 90
	dup2(1, shtest_saved_stdout)
	int cap = create_file(path, 511)
	dup2(cap, 1)
	close(cap)


char* shtest_read_and_delete(char* path):
	char* text = file_read_text(path)
	unlink(path)
	if (text == 0):
		return strclone(c"")
	return text


char* shtest_capture_stdout_end(char* path):
	dup2(shtest_saved_stdout, 1)
	close(shtest_saved_stdout)
	return shtest_read_and_delete(path)


void shtest_capture_stderr_start(char* path):
	shtest_saved_stderr = 91
	dup2(2, shtest_saved_stderr)
	int cap = create_file(path, 511)
	dup2(cap, 2)
	close(cap)


char* shtest_capture_stderr_end(char* path):
	dup2(shtest_saved_stderr, 2)
	close(shtest_saved_stderr)
	return shtest_read_and_delete(path)


# ---------------------------------------------------------------------------
# lib/shell_commands.w: the native tools themselves.

void test_pwd_prints_the_current_directory():
	char* cwd = malloc(4096)
	getcwd(cwd, 4096)

	char* cap = shtest_scratch_path(c"_pwd.out")
	shtest_capture_stdout_start(cap)
	pwd()
	char* got = shtest_capture_stdout_end(cap)

	char* want = strjoin(cwd, c"\x0a")
	assert_strings_equal(want, got)
	free(cwd)
	free(want)
	free(got)
	free(cap)


void test_ls_bare_lists_sorted_and_hides_dotfiles():
	char* dir = shtest_scratch_path(c"_ls_dir")
	mkdir(dir, 493)
	file_write_text(path_join(dir, c"beta.txt"), c"b")
	file_write_text(path_join(dir, c"alpha.txt"), c"a")
	file_write_text(path_join(dir, c".hidden"), c"h")

	char* cap = shtest_scratch_path(c"_ls_bare.out")
	shtest_capture_stdout_start(cap)
	ls(dir, false, false)
	char* got = shtest_capture_stdout_end(cap)

	assert_strings_equal(c"alpha.txt\x0abeta.txt\x0a", got)
	free(got)
	free(cap)
	free(dir)


void test_ls_all_shows_dotfiles_sorted_first():
	char* dir = shtest_scratch_path(c"_ls_all_dir")
	mkdir(dir, 493)
	file_write_text(path_join(dir, c"alpha.txt"), c"a")
	file_write_text(path_join(dir, c".hidden"), c"h")

	char* cap = shtest_scratch_path(c"_ls_all.out")
	shtest_capture_stdout_start(cap)
	ls(dir, true, false)
	char* got = shtest_capture_stdout_end(cap)

	assert_strings_equal(c".hidden\x0aalpha.txt\x0a", got)
	free(got)
	free(cap)
	free(dir)


void test_ls_missing_directory_reports_cannot_access():
	char* missing = c"/no/such/w_shell_commands_test_dir_xyz"
	char* out_cap = shtest_scratch_path(c"_ls_missing.out")
	char* err_cap = shtest_scratch_path(c"_ls_missing.err")
	shtest_capture_stdout_start(out_cap)
	shtest_capture_stderr_start(err_cap)
	ls(missing, false, false)
	char* err = shtest_capture_stderr_end(err_cap)
	char* out = shtest_capture_stdout_end(out_cap)

	assert_equal(0, strlen(out))
	assert1(index_of(err, c"cannot access") >= 0)
	assert1(index_of(err, c"No such file or directory") >= 0)
	free(out)
	free(err)
	free(out_cap)
	free(err_cap)


void test_cat_prints_one_file():
	char* f = shtest_scratch_path(c"_cat_one.txt")
	file_write_text(f, c"one file's content\x0a")

	char* cap = shtest_scratch_path(c"_cat_one.out")
	shtest_capture_stdout_start(cap)
	cat(f)
	char* got = shtest_capture_stdout_end(cap)

	assert_strings_equal(c"one file's content\x0a", got)
	free(got)
	free(cap)
	free(f)


void test_cat_concatenates_multiple_files_in_order():
	char* a = shtest_scratch_path(c"_cat_a.txt")
	char* b = shtest_scratch_path(c"_cat_b.txt")
	file_write_text(a, c"AAA\x0a")
	file_write_text(b, c"BBB\x0a")

	char* cap = shtest_scratch_path(c"_cat_multi.out")
	shtest_capture_stdout_start(cap)
	cat(a, b)
	char* got = shtest_capture_stdout_end(cap)

	assert_strings_equal(c"AAA\x0aBBB\x0a", got)
	free(got)
	free(cap)
	free(a)
	free(b)


void test_cat_missing_path_reports_error_and_continues():
	char* missing = c"/no/such/w_shell_commands_test_file_xyz"
	char* present = shtest_scratch_path(c"_cat_present.txt")
	file_write_text(present, c"still here\x0a")

	char* out_cap = shtest_scratch_path(c"_cat_missing.out")
	char* err_cap = shtest_scratch_path(c"_cat_missing.err")
	shtest_capture_stdout_start(out_cap)
	shtest_capture_stderr_start(err_cap)
	cat(missing, present)
	char* err = shtest_capture_stderr_end(err_cap)
	char* out = shtest_capture_stdout_end(out_cap)

	assert1(index_of(err, missing) >= 0)
	assert1(index_of(err, c"No such file or directory") >= 0)
	assert_strings_equal(c"still here\x0a", out)
	free(out)
	free(err)
	free(out_cap)
	free(err_cap)
	free(present)


# ---------------------------------------------------------------------------
# lib/shell_commands.w: stage 2's native tools (echo, head, tail, wc,
# mkdir_p, rm, cp, mv).

void test_echo_joins_words_with_spaces():
	char* cap = shtest_scratch_path(c"_echo.out")
	shtest_capture_stdout_start(cap)
	echo(false, c"hello", c"shell", c"mode")
	char* got = shtest_capture_stdout_end(cap)

	assert_strings_equal(c"hello shell mode\x0a", got)
	free(got)
	free(cap)


void test_echo_no_newline_suppresses_trailing_newline():
	char* cap = shtest_scratch_path(c"_echo_n.out")
	shtest_capture_stdout_start(cap)
	echo(true, c"no-newline")
	char* got = shtest_capture_stdout_end(cap)

	assert_strings_equal(c"no-newline", got)
	free(got)
	free(cap)


void test_echo_with_no_words_prints_blank_line():
	char* cap = shtest_scratch_path(c"_echo_empty.out")
	shtest_capture_stdout_start(cap)
	echo(false)
	char* got = shtest_capture_stdout_end(cap)

	assert_strings_equal(c"\x0a", got)
	free(got)
	free(cap)


void test_head_prints_first_n_lines():
	char* f = shtest_scratch_path(c"_head.txt")
	file_write_text(f, c"one\x0atwo\x0athree\x0afour\x0afive\x0a")

	char* cap = shtest_scratch_path(c"_head.out")
	shtest_capture_stdout_start(cap)
	head(f, 3)
	char* got = shtest_capture_stdout_end(cap)

	assert_strings_equal(c"one\x0atwo\x0athree\x0a", got)
	free(got)
	free(cap)
	free(f)


void test_head_n_larger_than_file_prints_everything():
	char* f = shtest_scratch_path(c"_head_all.txt")
	file_write_text(f, c"a\x0ab\x0a")

	char* cap = shtest_scratch_path(c"_head_all.out")
	shtest_capture_stdout_start(cap)
	head(f, 10)
	char* got = shtest_capture_stdout_end(cap)

	assert_strings_equal(c"a\x0ab\x0a", got)
	free(got)
	free(cap)
	free(f)


void test_head_missing_file_reports_error():
	char* missing = c"/no/such/w_shell_commands_test_head_xyz"
	char* err_cap = shtest_scratch_path(c"_head_missing.err")
	shtest_capture_stderr_start(err_cap)
	head(missing, 5)
	char* err = shtest_capture_stderr_end(err_cap)

	assert1(index_of(err, c"cannot open") >= 0)
	free(err)
	free(err_cap)


void test_tail_prints_last_n_lines():
	char* f = shtest_scratch_path(c"_tail.txt")
	file_write_text(f, c"one\x0atwo\x0athree\x0afour\x0afive\x0a")

	char* cap = shtest_scratch_path(c"_tail.out")
	shtest_capture_stdout_start(cap)
	tail(f, 2)
	char* got = shtest_capture_stdout_end(cap)

	assert_strings_equal(c"four\x0afive\x0a", got)
	free(got)
	free(cap)
	free(f)


void test_tail_missing_file_reports_error():
	char* missing = c"/no/such/w_shell_commands_test_tail_xyz"
	char* err_cap = shtest_scratch_path(c"_tail_missing.err")
	shtest_capture_stderr_start(err_cap)
	tail(missing, 5)
	char* err = shtest_capture_stderr_end(err_cap)

	assert1(index_of(err, c"cannot open") >= 0)
	free(err)
	free(err_cap)


void test_wc_default_prints_lines_words_bytes():
	char* f = shtest_scratch_path(c"_wc.txt")
	file_write_text(f, c"one two\x0athree\x0a")

	char* cap = shtest_scratch_path(c"_wc.out")
	shtest_capture_stdout_start(cap)
	wc(f, false, false, false)
	char* got = shtest_capture_stdout_end(cap)

	char* want = strjoin(c"2 3 14 ", f)
	char* want2 = strjoin(want, c"\x0a")
	assert_strings_equal(want2, got)
	free(want)
	free(want2)
	free(got)
	free(cap)
	free(f)


void test_wc_only_lines_when_only_l_flag_set():
	char* f = shtest_scratch_path(c"_wc_l.txt")
	file_write_text(f, c"a\x0ab\x0ac\x0a")

	char* cap = shtest_scratch_path(c"_wc_l.out")
	shtest_capture_stdout_start(cap)
	wc(f, true, false, false)
	char* got = shtest_capture_stdout_end(cap)

	char* want = strjoin(c"3 ", f)
	char* want2 = strjoin(want, c"\x0a")
	assert_strings_equal(want2, got)
	free(want)
	free(want2)
	free(got)
	free(cap)
	free(f)


void test_wc_counts_every_byte_past_an_embedded_nul():
	# 6 bytes: 'a' NUL 'b' ' ' 'c' '\x0a' -> 1 line, 2 words ("a\0b" is
	# one non-space run, NUL is not a separator, matching real wc), 6
	# bytes. The old strlen-derived length stopped at the NUL and
	# reported 0 1 1.
	char* f = shtest_scratch_path(c"_wc_nul.bin")
	int fd = create_file(f, 511)
	char* data = malloc(8)
	data[0] = 'a'
	data[1] = 0
	data[2] = 'b'
	data[3] = ' '
	data[4] = 'c'
	data[5] = 10
	write(fd, data, 6)
	close(fd)
	free(data)

	char* cap = shtest_scratch_path(c"_wc_nul.out")
	shtest_capture_stdout_start(cap)
	wc(f, false, false, false)
	char* got = shtest_capture_stdout_end(cap)

	char* want = strjoin(c"1 2 6 ", f)
	char* want2 = strjoin(want, c"\x0a")
	assert_strings_equal(want2, got)
	unlink(f)
	free(want)
	free(want2)
	free(got)
	free(cap)
	free(f)


void test_wc_missing_file_reports_error():
	char* missing = c"/no/such/w_shell_commands_test_wc_xyz"
	char* err_cap = shtest_scratch_path(c"_wc_missing.err")
	shtest_capture_stderr_start(err_cap)
	wc(missing, false, false, false)
	char* err = shtest_capture_stderr_end(err_cap)

	assert1(index_of(err, c"No such file or directory") >= 0)
	free(err)
	free(err_cap)


void test_mkdir_p_creates_a_single_directory():
	char* dir = shtest_scratch_path(c"_mkdir_single")

	mkdir_p(false, dir)

	assert1(path_exists(dir))
	rmdir(dir)
	free(dir)


void test_mkdir_p_creates_missing_ancestors():
	char* base = shtest_scratch_path(c"_mkdir_nested")
	char* mid = path_join(base, c"mid")
	char* leaf = path_join(mid, c"leaf")

	mkdir_p(true, leaf)

	assert1(path_exists(leaf))
	rmdir(leaf)
	rmdir(mid)
	rmdir(base)
	free(base)
	free(mid)
	free(leaf)


void test_mkdir_p_tolerates_already_existing_target():
	char* dir = shtest_scratch_path(c"_mkdir_exists")
	mkdir(dir, 493)

	char* err_cap = shtest_scratch_path(c"_mkdir_exists.err")
	shtest_capture_stderr_start(err_cap)
	mkdir_p(true, dir)
	char* err = shtest_capture_stderr_end(err_cap)

	assert_equal(0, strlen(err))
	assert1(path_exists(dir))
	free(err)
	free(err_cap)
	rmdir(dir)
	free(dir)


void test_rm_removes_a_file():
	char* f = shtest_scratch_path(c"_rm_file.txt")
	file_write_text(f, c"gone soon\x0a")

	rm(false, false, f)

	assert_equal(0, path_exists(f))
	free(f)


void test_rm_missing_without_force_reports_error():
	char* missing = c"/no/such/w_shell_commands_test_rm_xyz"
	char* err_cap = shtest_scratch_path(c"_rm_missing.err")
	shtest_capture_stderr_start(err_cap)
	rm(false, false, missing)
	char* err = shtest_capture_stderr_end(err_cap)

	assert1(index_of(err, c"No such file or directory") >= 0)
	free(err)
	free(err_cap)


void test_rm_missing_with_force_is_silent():
	char* missing = c"/no/such/w_shell_commands_test_rm_force_xyz"
	char* err_cap = shtest_scratch_path(c"_rm_force_missing.err")
	shtest_capture_stderr_start(err_cap)
	rm(false, true, missing)
	char* err = shtest_capture_stderr_end(err_cap)

	assert_equal(0, strlen(err))
	free(err)
	free(err_cap)


void test_rm_directory_without_recursive_reports_is_a_directory():
	char* dir = shtest_scratch_path(c"_rm_dir_norec")
	mkdir(dir, 493)

	char* err_cap = shtest_scratch_path(c"_rm_dir_norec.err")
	shtest_capture_stderr_start(err_cap)
	rm(false, false, dir)
	char* err = shtest_capture_stderr_end(err_cap)

	assert1(index_of(err, c"Is a directory") >= 0)
	assert1(path_exists(dir))
	free(err)
	free(err_cap)
	rmdir(dir)
	free(dir)


void test_rm_recursive_removes_directory_tree():
	char* dir = shtest_scratch_path(c"_rm_tree")
	char* nested = path_join(dir, c"nested")
	mkdir(dir, 493)
	mkdir(nested, 493)
	file_write_text(path_join(dir, c"a.txt"), c"a")
	file_write_text(path_join(nested, c"b.txt"), c"b")

	rm(true, false, dir)

	assert_equal(0, path_exists(dir))
	free(dir)
	free(nested)


void test_cp_copies_a_file():
	char* src = shtest_scratch_path(c"_cp_src.txt")
	char* dst = shtest_scratch_path(c"_cp_dst.txt")
	file_write_text(src, c"copy me\x0a")

	cp(false, src, dst)

	char* got = file_read_text(dst)
	assert_strings_equal(c"copy me\x0a", got)
	free(got)
	unlink(src)
	unlink(dst)
	free(src)
	free(dst)


void test_cp_missing_source_reports_error():
	char* missing = c"/no/such/w_shell_commands_test_cp_xyz"
	char* dst = shtest_scratch_path(c"_cp_missing_dst.txt")
	char* err_cap = shtest_scratch_path(c"_cp_missing.err")
	shtest_capture_stderr_start(err_cap)
	cp(false, missing, dst)
	char* err = shtest_capture_stderr_end(err_cap)

	assert1(index_of(err, c"No such file or directory") >= 0)
	assert_equal(0, path_exists(dst))
	free(err)
	free(err_cap)
	free(dst)


void test_cp_directory_without_recursive_reports_omitting():
	char* src = shtest_scratch_path(c"_cp_dir_norec")
	char* dst = shtest_scratch_path(c"_cp_dir_norec_dst")
	mkdir(src, 493)

	char* err_cap = shtest_scratch_path(c"_cp_dir_norec.err")
	shtest_capture_stderr_start(err_cap)
	cp(false, src, dst)
	char* err = shtest_capture_stderr_end(err_cap)

	assert1(index_of(err, c"omitting directory") >= 0)
	assert_equal(0, path_exists(dst))
	free(err)
	free(err_cap)
	rmdir(src)
	free(src)
	free(dst)


void test_cp_recursive_copies_directory_tree():
	char* src = shtest_scratch_path(c"_cp_tree_src")
	char* dst = shtest_scratch_path(c"_cp_tree_dst")
	char* src_file = path_join(src, c"a.txt")
	char* dst_file = path_join(dst, c"a.txt")
	mkdir(src, 493)
	file_write_text(src_file, c"aaa")

	cp(true, src, dst)

	char* got = file_read_text(dst_file)
	assert_strings_equal(c"aaa", got)
	free(got)
	unlink(src_file)
	unlink(dst_file)
	rmdir(src)
	rmdir(dst)
	free(src)
	free(dst)
	free(src_file)
	free(dst_file)


void test_mv_renames_a_file():
	char* src = shtest_scratch_path(c"_mv_src.txt")
	char* dst = shtest_scratch_path(c"_mv_dst.txt")
	file_write_text(src, c"move me\x0a")

	mv(src, dst)

	assert_equal(0, path_exists(src))
	char* got = file_read_text(dst)
	assert_strings_equal(c"move me\x0a", got)
	free(got)
	unlink(dst)
	free(src)
	free(dst)


void test_mv_missing_source_reports_error():
	char* missing = c"/no/such/w_shell_commands_test_mv_xyz"
	char* dst = shtest_scratch_path(c"_mv_missing_dst.txt")
	char* err_cap = shtest_scratch_path(c"_mv_missing.err")
	shtest_capture_stderr_start(err_cap)
	mv(missing, dst)
	char* err = shtest_capture_stderr_end(err_cap)

	assert1(index_of(err, c"No such file or directory") >= 0)
	free(err)
	free(err_cap)
	free(dst)


# ---------------------------------------------------------------------------
# lib/shell_commands.w: stage 3's tools (ls -l, touch, chmod, du).

void test_ls_long_lists_mode_nlink_size_mtime_and_name():
	char* dir = shtest_scratch_path(c"_ls_long_dir")
	mkdir(dir, 493)
	char* file_path = path_join(dir, c"alpha.txt")
	file_write_text(file_path, c"abc")
	# Pin the metadata the line prints so the assertion is exact: mode
	# 0644, mtime 1700000000 = 2023-11-14 22:13:20 UTC.
	assert_equal(0, file_chmod(file_path, 420))
	assert_equal(0, file_utimens(file_path, 1700000000, 1700000000, 0))

	char* cap = shtest_scratch_path(c"_ls_long.out")
	shtest_capture_stdout_start(cap)
	ls(dir, false, true)
	char* got = shtest_capture_stdout_end(cap)

	# "-rw-r--r-- 1 <owner> <group> 3 2023-11-14 22:13 alpha.txt\n" --
	# owner/group names depend on the environment, so assert the exact
	# prefix and the exact suffix around them.
	assert_equal(0, index_of(got, c"-rw-r--r-- 1 "))
	assert1(index_of(got, c" 3 2023-11-14 22:13 alpha.txt\x0a") >= 0)
	unlink(file_path)
	free(got)
	free(cap)
	free(file_path)
	free(dir)


void test_ls_long_marks_directories_and_symlinks():
	char* dir = shtest_scratch_path(c"_ls_long_kinds_dir")
	mkdir(dir, 493)
	char* sub = path_join(dir, c"subdir")
	mkdir(sub, 493)
	char* plain = path_join(dir, c"plain.txt")
	file_write_text(plain, c"p")
	char* link_path = path_join(dir, c"slink")
	assert_equal(0, file_symlink(c"plain.txt", link_path))

	char* cap = shtest_scratch_path(c"_ls_long_kinds.out")
	shtest_capture_stdout_start(cap)
	ls(dir, false, true)
	char* got = shtest_capture_stdout_end(cap)

	# mkdir's 0755 is umask-clipped in group/other, so only assert the
	# owner bits; a symlink's bits are always 0777.
	assert1(index_of(got, c"drwx") >= 0)
	assert1(index_of(got, c"lrwxrwxrwx") >= 0)
	assert1(index_of(got, c"slink -> plain.txt") >= 0)
	unlink(link_path)
	unlink(plain)
	rmdir(sub)
	free(got)
	free(cap)
	free(link_path)
	free(plain)
	free(sub)
	free(dir)


void test_touch_creates_a_missing_file():
	char* path = shtest_scratch_path(c"_touch_new.txt")
	unlink(path)
	touch(false, path)
	assert1(path_exists(path))
	file_stat st
	assert_equal(0, file_stat_path(path, &st))
	assert_equal(0, st.size)
	unlink(path)
	free(path)


void test_touch_no_create_skips_missing_file_silently():
	char* path = shtest_scratch_path(c"_touch_nc.txt")
	unlink(path)
	char* err_cap = shtest_scratch_path(c"_touch_nc.err")
	shtest_capture_stderr_start(err_cap)
	touch(true, path)
	char* err = shtest_capture_stderr_end(err_cap)

	# Real "touch -c missing" is silent success and creates nothing.
	assert_strings_equal(c"", err)
	assert_equal(0, path_exists(path))
	free(err)
	free(err_cap)
	free(path)


void test_touch_updates_mtime_of_an_existing_file():
	char* path = shtest_scratch_path(c"_touch_stamp.txt")
	file_write_text(path, c"x")
	assert_equal(0, file_utimens(path, 1000000, 1000000, 0))
	file_stat before
	assert_equal(0, file_stat_path(path, &before))
	assert_equal(1000000, before.mtime)
	touch(false, path)
	file_stat after
	assert_equal(0, file_stat_path(path, &after))
	assert1(after.mtime > 1000000)
	unlink(path)
	free(path)


void test_touch_missing_parent_reports_cannot_touch():
	char* path = c"/no/such/dir/w_shell_commands_touch_xyz.txt"
	char* err_cap = shtest_scratch_path(c"_touch_missing.err")
	shtest_capture_stderr_start(err_cap)
	touch(false, path)
	char* err = shtest_capture_stderr_end(err_cap)

	assert1(index_of(err, c"touch: cannot touch '") >= 0)
	assert1(index_of(err, c"No such file or directory") >= 0)
	free(err)
	free(err_cap)


void test_chmod_octal_sets_permission_bits():
	char* path = shtest_scratch_path(c"_chmod.txt")
	file_write_text(path, c"c")
	chmod_octal(384, path) /* 384 = 0600 */
	file_stat st
	assert_equal(0, file_stat_path(path, &st))
	assert_equal(384, file_mode_perm(&st))
	chmod_octal(493, path) /* 493 = 0755 */
	assert_equal(0, file_stat_path(path, &st))
	assert_equal(493, file_mode_perm(&st))
	unlink(path)
	free(path)


void test_chmod_octal_missing_path_reports_error():
	char* err_cap = shtest_scratch_path(c"_chmod_missing.err")
	shtest_capture_stderr_start(err_cap)
	chmod_octal(420, c"/no/such/w_shell_commands_chmod_xyz.txt")
	char* err = shtest_capture_stderr_end(err_cap)

	assert1(index_of(err, c"chmod: cannot access '") >= 0)
	assert1(index_of(err, c"No such file or directory") >= 0)
	free(err)
	free(err_cap)


int shtest_count_newlines(char* s):
	int count = 0
	int i = 0
	while (s[i] != 0):
		if (s[i] == 10):
			count = count + 1
		i = i + 1
	return count


# "<TAB>path<NL>" -- a du output line minus its leading count, precise
# enough that a path which merely prefixes another (dir vs. dir/sub)
# cannot satisfy the other's match.
char* shtest_tabbed_line(char* path):
	string_builder* out = string_new()
	string_append_char(out, 9)
	string_append(out, path)
	string_append_char(out, 10)
	char* s = out.data
	free(out)
	return s


void test_du_summarize_prints_only_the_top_total():
	char* dir = shtest_scratch_path(c"_du_s_dir")
	mkdir(dir, 493)
	char* sub = path_join(dir, c"sub")
	mkdir(sub, 493)
	char* f = path_join(sub, c"f.txt")
	file_write_text(f, c"du summarize content\x0a")

	char* cap = shtest_scratch_path(c"_du_s.out")
	shtest_capture_stdout_start(cap)
	du(true, dir)
	char* got = shtest_capture_stdout_end(cap)

	# Exactly one "N<TAB>dir" line; the child directory's own line is
	# suppressed by -s, and the count is decimal digits (block counts
	# are filesystem-dependent, so only the shape is asserted).
	assert_equal(1, shtest_count_newlines(got))
	assert1((got[0] >= '0') && (got[0] <= '9'))
	char* dir_line = shtest_tabbed_line(dir)
	assert1(index_of(got, dir_line) >= 0)
	assert1(index_of(got, sub) < 0)
	unlink(f)
	rmdir(sub)
	rmdir(dir)
	free(got)
	free(cap)
	free(dir_line)
	free(f)
	free(sub)
	free(dir)


void test_du_default_prints_child_directories_before_parent():
	char* dir = shtest_scratch_path(c"_du_walk_dir")
	mkdir(dir, 493)
	char* sub = path_join(dir, c"sub")
	mkdir(sub, 493)
	char* f = path_join(sub, c"f.txt")
	file_write_text(f, c"du walk content\x0a")

	char* cap = shtest_scratch_path(c"_du_walk.out")
	shtest_capture_stdout_start(cap)
	du(false, dir)
	char* got = shtest_capture_stdout_end(cap)

	# Post-order, real du's own order: the child directory's line
	# prints before the parent's. The parent line is matched with its
	# trailing newline so the child's (whose path extends past the
	# parent prefix) cannot satisfy it.
	assert_equal(2, shtest_count_newlines(got))
	char* sub_line = shtest_tabbed_line(sub)
	char* dir_line = shtest_tabbed_line(dir)
	int sub_at = index_of(got, sub_line)
	int dir_at = index_of(got, dir_line)
	assert1(sub_at >= 0)
	assert1(dir_at >= 0)
	assert1(sub_at < dir_at)
	unlink(f)
	rmdir(sub)
	rmdir(dir)
	free(got)
	free(cap)
	free(sub_line)
	free(dir_line)
	free(f)
	free(sub)
	free(dir)


void test_du_file_argument_prints_its_own_line():
	char* path = shtest_scratch_path(c"_du_file.txt")
	file_write_text(path, c"du file content\x0a")

	char* cap = shtest_scratch_path(c"_du_file.out")
	shtest_capture_stdout_start(cap)
	du(false, path)
	char* got = shtest_capture_stdout_end(cap)

	assert_equal(1, shtest_count_newlines(got))
	char* line = shtest_tabbed_line(path)
	assert1(index_of(got, line) >= 0)
	unlink(path)
	free(got)
	free(cap)
	free(line)
	free(path)


void test_du_missing_path_reports_cannot_access():
	char* err_cap = shtest_scratch_path(c"_du_missing.err")
	shtest_capture_stderr_start(err_cap)
	du(false, c"/no/such/w_shell_commands_du_dir_xyz")
	char* err = shtest_capture_stderr_end(err_cap)

	assert1(index_of(err, c"du: cannot access '") >= 0)
	assert1(index_of(err, c"No such file or directory") >= 0)
	free(err)
	free(err_cap)


# ---------------------------------------------------------------------------
# repl/shell_translate.w: the argv/flag -> W call translator, pure logic.

void test_translate_pwd():
	assert_strings_equal(c"shell_commands.pwd()", shell_translate_line(c"pwd"))


void test_translate_pwd_rejects_extra_word():
	assert1(shell_translate_line(c"pwd extra") == 0)


void test_translate_ls_bare_defaults_to_dot_and_all_false():
	assert_strings_equal(c"shell_commands.ls(c\".\", false, false)", shell_translate_line(c"ls"))


void test_translate_ls_short_all_flag():
	assert_strings_equal(c"shell_commands.ls(c\".\", true, false)", shell_translate_line(c"ls -a"))


void test_translate_ls_long_all_flag():
	assert_strings_equal(c"shell_commands.ls(c\".\", true, false)", shell_translate_line(c"ls --all"))


void test_translate_ls_with_explicit_path():
	assert_strings_equal(c"shell_commands.ls(c\"/tmp\", false, false)", shell_translate_line(c"ls /tmp"))


void test_translate_ls_l_flag_selects_long_format():
	# Stage 3: "-l" is now a known flag (lib/stat.w closed the
	# stat-wrapper gap the stage 1 tests documented), alone or
	# clustered with -a in either order.
	assert_strings_equal(c"shell_commands.ls(c\".\", false, true)", shell_translate_line(c"ls -l"))
	assert_strings_equal(c"shell_commands.ls(c\".\", true, true)", shell_translate_line(c"ls -la"))
	assert_strings_equal(c"shell_commands.ls(c\"/tmp\", true, true)", shell_translate_line(c"ls -al /tmp"))


void test_translate_ls_rejects_unknown_letter_in_l_cluster():
	# "no partial credit" (Sec 5.4): one unknown letter fails the whole
	# cluster even when 'l' and 'a' are both known.
	assert1(shell_translate_line(c"ls -lah") == 0)


void test_translate_ls_rejects_unknown_flag():
	assert1(shell_translate_line(c"ls -x") == 0)


void test_translate_ls_rejects_two_paths():
	assert1(shell_translate_line(c"ls a b") == 0)


void test_translate_cat_requires_at_least_one_path():
	assert1(shell_translate_line(c"cat") == 0)


void test_translate_cat_one_path():
	assert_strings_equal(c"shell_commands.cat(c\"a.txt\")", shell_translate_line(c"cat a.txt"))


void test_translate_cat_multiple_paths():
	assert_strings_equal(c"shell_commands.cat(c\"a.txt\", c\"b.txt\")",
		shell_translate_line(c"cat a.txt b.txt"))


void test_translate_cat_rejects_any_flag():
	assert1(shell_translate_line(c"cat -n a.txt") == 0)


void test_translate_unrecognized_command_falls_back():
	# sed and find stay unrecognized (design doc Sec 6.3) -- stable
	# examples of always-native commands now that stage 4 promoted grep
	# (the way stage 2 promoted this test's original "echo" example and
	# stage 4 its "grep" one).
	assert1(shell_translate_line(c"sed hi") == 0)
	assert1(shell_translate_line(c"find .") == 0)


void test_translate_single_quotes_preserve_spaces():
	assert_strings_equal(c"shell_commands.cat(c\"a b.txt\")", shell_translate_line(c"cat 'a b.txt'"))


void test_translate_double_quotes_strip_but_keep_contents():
	assert_strings_equal(c"shell_commands.cat(c\"plain\")", shell_translate_line(c"cat \"plain\""))


void test_translate_backslash_outside_quotes_escapes_next_byte():
	# "foo\ bar.txt" -> one word, the escaped space kept literal.
	assert_strings_equal(c"shell_commands.cat(c\"foo bar.txt\")",
		shell_translate_line(c"cat foo\\ bar.txt"))


void test_translate_metacharacters_fall_back_to_native():
	# Sec 5.2 rule 1: any of these anywhere on the line means "native
	# fallback, unconditionally" -- pipe, redirection, chaining,
	# backgrounding, variable/command/glob expansion.
	assert1(shell_translate_line(c"ls foo | bar") == 0)
	assert1(shell_translate_line(c"cat foo > bar.txt") == 0)
	assert1(shell_translate_line(c"cat foo < bar.txt") == 0)
	assert1(shell_translate_line(c"ls; pwd") == 0)
	assert1(shell_translate_line(c"ls & pwd") == 0)
	assert1(shell_translate_line(c"echo $HOME") == 0)
	assert1(shell_translate_line(c"cat `pwd`") == 0)
	assert1(shell_translate_line(c"ls ~") == 0)
	assert1(shell_translate_line(c"ls *") == 0)
	assert1(shell_translate_line(c"ls foo?") == 0)


# ---------------------------------------------------------------------------
# repl/shell_translate.w: stage 2's translator coverage (echo, head,
# tail, wc, mkdir, rm, cp, mv).

void test_translate_echo_joins_words():
	assert_strings_equal(c"shell_commands.echo(false, c\"hi\", c\"there\")",
		shell_translate_line(c"echo hi there"))


void test_translate_echo_no_newline_flag():
	assert_strings_equal(c"shell_commands.echo(true, c\"hi\")", shell_translate_line(c"echo -n hi"))


void test_translate_echo_with_no_words():
	assert_strings_equal(c"shell_commands.echo(false)", shell_translate_line(c"echo"))


void test_translate_echo_rejects_unknown_flag():
	assert1(shell_translate_line(c"echo -x hi") == 0)


void test_translate_echo_n_after_a_word_is_literal_text():
	# Real echo only honors "-n" while it leads the argument list; after
	# the first ordinary word it is plain text to print.
	assert_strings_equal(c"shell_commands.echo(false, c\"hi\", c\"-n\")",
		shell_translate_line(c"echo hi -n"))
	assert_strings_equal(c"shell_commands.echo(false, c\"a\", c\"-n\", c\"b\")",
		shell_translate_line(c"echo a -n b"))


void test_translate_echo_repeated_leading_n_flags_all_consumed():
	# Real echo consumes a whole leading run of "-n" flags.
	assert_strings_equal(c"shell_commands.echo(true, c\"hi\")",
		shell_translate_line(c"echo -n -n hi"))


void test_translate_head_default_count():
	assert_strings_equal(c"shell_commands.head(c\"a.txt\", 10)", shell_translate_line(c"head a.txt"))


void test_translate_head_n_flag_space_separated():
	assert_strings_equal(c"shell_commands.head(c\"a.txt\", 5)", shell_translate_line(c"head -n 5 a.txt"))


void test_translate_head_rejects_inline_equals_forms():
	# "-n=5"/"--lines=5" are lib/args.w spellings, not head's ("head
	# -n=5" is an "invalid number of lines: '=5'" error from the real
	# tool) -- the line fails closed to native so the real tool's own
	# acceptance or diagnostic applies, instead of the translator
	# accepting a form the native tool would not.
	assert1(shell_translate_line(c"head -n=5 a.txt") == 0)
	assert1(shell_translate_line(c"head --lines=5 a.txt") == 0)


void test_translate_head_long_lines_flag():
	assert_strings_equal(c"shell_commands.head(c\"a.txt\", 5)", shell_translate_line(c"head --lines 5 a.txt"))


void test_translate_head_rejects_non_numeric_value():
	assert1(shell_translate_line(c"head -n five a.txt") == 0)


void test_translate_head_requires_a_path():
	assert1(shell_translate_line(c"head -n 5") == 0)


void test_translate_head_rejects_two_paths():
	assert1(shell_translate_line(c"head a.txt b.txt") == 0)


void test_translate_tail_default_count():
	assert_strings_equal(c"shell_commands.tail(c\"a.txt\", 10)", shell_translate_line(c"tail a.txt"))


void test_translate_tail_n_flag():
	assert_strings_equal(c"shell_commands.tail(c\"a.txt\", 3)", shell_translate_line(c"tail -n 3 a.txt"))


void test_translate_tail_rejects_inline_equals_forms():
	# Same rationale as head's: not the real tools' forms.
	assert1(shell_translate_line(c"tail -n=3 a.txt") == 0)
	assert1(shell_translate_line(c"tail --lines=3 a.txt") == 0)


void test_translate_wc_default_all_flags_false():
	assert_strings_equal(c"shell_commands.wc(c\"a.txt\", false, false, false)", shell_translate_line(c"wc a.txt"))


void test_translate_wc_l_flag():
	assert_strings_equal(c"shell_commands.wc(c\"a.txt\", true, false, false)", shell_translate_line(c"wc -l a.txt"))


void test_translate_wc_clustered_flags():
	assert_strings_equal(c"shell_commands.wc(c\"a.txt\", true, true, false)", shell_translate_line(c"wc -lw a.txt"))


void test_translate_wc_all_three_clustered():
	assert_strings_equal(c"shell_commands.wc(c\"a.txt\", true, true, true)", shell_translate_line(c"wc -lwc a.txt"))


void test_translate_wc_rejects_unknown_flag():
	assert1(shell_translate_line(c"wc -x a.txt") == 0)


void test_translate_wc_requires_a_path():
	assert1(shell_translate_line(c"wc -l") == 0)


void test_translate_mkdir_bare():
	assert_strings_equal(c"shell_commands.mkdir_p(false, c\"newdir\")", shell_translate_line(c"mkdir newdir"))


void test_translate_mkdir_p_flag():
	assert_strings_equal(c"shell_commands.mkdir_p(true, c\"a/b/c\")", shell_translate_line(c"mkdir -p a/b/c"))


void test_translate_mkdir_long_parents_flag():
	assert_strings_equal(c"shell_commands.mkdir_p(true, c\"a/b/c\")", shell_translate_line(c"mkdir --parents a/b/c"))


void test_translate_mkdir_multiple_dirs():
	assert_strings_equal(c"shell_commands.mkdir_p(false, c\"a\", c\"b\")", shell_translate_line(c"mkdir a b"))


void test_translate_mkdir_requires_a_path():
	assert1(shell_translate_line(c"mkdir -p") == 0)


void test_translate_rm_bare():
	assert_strings_equal(c"shell_commands.rm(false, false, c\"a.txt\")", shell_translate_line(c"rm a.txt"))


void test_translate_rm_clustered_rf_flags():
	assert_strings_equal(c"shell_commands.rm(true, true, c\"dir\")", shell_translate_line(c"rm -rf dir"))


void test_translate_rm_long_flags():
	assert_strings_equal(c"shell_commands.rm(true, false, c\"dir\")", shell_translate_line(c"rm --recursive dir"))


void test_translate_rm_multiple_paths():
	assert_strings_equal(c"shell_commands.rm(false, false, c\"a\", c\"b\")", shell_translate_line(c"rm a b"))


void test_translate_rm_requires_a_path():
	assert1(shell_translate_line(c"rm -f") == 0)


void test_translate_cp_bare():
	assert_strings_equal(c"shell_commands.cp(false, c\"a.txt\", c\"b.txt\")", shell_translate_line(c"cp a.txt b.txt"))


void test_translate_cp_recursive_flag():
	assert_strings_equal(c"shell_commands.cp(true, c\"src\", c\"dst\")", shell_translate_line(c"cp -r src dst"))


void test_translate_cp_requires_two_paths():
	assert1(shell_translate_line(c"cp a.txt") == 0)
	assert1(shell_translate_line(c"cp a.txt b.txt c.txt") == 0)


void test_translate_mv_bare():
	assert_strings_equal(c"shell_commands.mv(c\"a.txt\", c\"b.txt\")", shell_translate_line(c"mv a.txt b.txt"))


void test_translate_mv_rejects_flag():
	assert1(shell_translate_line(c"mv -f a.txt b.txt") == 0)


void test_translate_mv_requires_two_paths():
	assert1(shell_translate_line(c"mv a.txt") == 0)


# ---------------------------------------------------------------------------
# repl/shell_translate.w: stage 3's translator coverage (ls -l above,
# touch, chmod, du).

void test_translate_touch_bare():
	assert_strings_equal(c"shell_commands.touch(false, c\"a.txt\")", shell_translate_line(c"touch a.txt"))


void test_translate_touch_no_create_flag():
	assert_strings_equal(c"shell_commands.touch(true, c\"a.txt\")", shell_translate_line(c"touch -c a.txt"))
	assert_strings_equal(c"shell_commands.touch(true, c\"a.txt\")",
		shell_translate_line(c"touch --no-create a.txt"))


void test_translate_touch_multiple_paths():
	assert_strings_equal(c"shell_commands.touch(false, c\"a\", c\"b\")", shell_translate_line(c"touch a b"))


void test_translate_touch_requires_a_path():
	assert1(shell_translate_line(c"touch") == 0)
	assert1(shell_translate_line(c"touch -c") == 0)


void test_translate_touch_rejects_unknown_flag():
	# Real touch's valued flags (-t STAMP, -d DATE, -r FILE) are
	# unknown here and fail the whole line closed to native.
	assert1(shell_translate_line(c"touch -t 202601010000 a.txt") == 0)


void test_translate_chmod_octal_mode():
	assert_strings_equal(c"shell_commands.chmod_octal(420, c\"a.txt\")",
		shell_translate_line(c"chmod 644 a.txt"))
	assert_strings_equal(c"shell_commands.chmod_octal(493, c\"a\", c\"b\")",
		shell_translate_line(c"chmod 0755 a b"))


void test_translate_chmod_rejects_symbolic_modes():
	# Symbolic modes are not octal digits; the whole line fails closed
	# to the real chmod, whose full mode grammar then applies.
	assert1(shell_translate_line(c"chmod u+x a.txt") == 0)
	assert1(shell_translate_line(c"chmod a=r a.txt") == 0)


void test_translate_chmod_rejects_bad_octal():
	assert1(shell_translate_line(c"chmod 999 a.txt") == 0)
	assert1(shell_translate_line(c"chmod 00644 a.txt") == 0)


void test_translate_chmod_requires_mode_and_path():
	assert1(shell_translate_line(c"chmod 644") == 0)
	assert1(shell_translate_line(c"chmod") == 0)


void test_translate_chmod_rejects_flags():
	# No -R in v1; a '-' word anywhere fails the line.
	assert1(shell_translate_line(c"chmod -R 755 dir") == 0)


void test_translate_du_bare_defaults_to_dot():
	assert_strings_equal(c"shell_commands.du(false, c\".\")", shell_translate_line(c"du"))


void test_translate_du_summarize_flag():
	assert_strings_equal(c"shell_commands.du(true, c\"/tmp\")", shell_translate_line(c"du -s /tmp"))
	assert_strings_equal(c"shell_commands.du(true, c\"/tmp\")",
		shell_translate_line(c"du --summarize /tmp"))


void test_translate_du_rejects_unknown_flag():
	assert1(shell_translate_line(c"du -h") == 0)
	assert1(shell_translate_line(c"du -sh /tmp") == 0)


void test_translate_du_rejects_two_paths():
	assert1(shell_translate_line(c"du a b") == 0)


# ---------------------------------------------------------------------------
# lib/shell_commands.w: stage 4's tools (ln -s, df, ps, grep).

void test_ln_s_creates_a_symlink():
	char* dir = shtest_scratch_path(c"_ln_dir")
	mkdir(dir, 493)
	char* target = path_join(dir, c"target.txt")
	file_write_text(target, c"ln target content\x0a")
	char* link_path = path_join(dir, c"link.txt")

	ln_s(c"target.txt", link_path)

	file_stat st
	assert_equal(0, file_lstat_path(link_path, &st))
	assert1(file_is_lnk(&st))
	char* got = file_read_text(link_path)
	assert_strings_equal(c"ln target content\x0a", got)
	free(got)
	unlink(link_path)
	unlink(target)
	rmdir(dir)
	free(link_path)
	free(target)
	free(dir)


void test_ln_s_existing_destination_reports_file_exists():
	char* path = shtest_scratch_path(c"_ln_exists.txt")
	file_write_text(path, c"already here")

	char* err_cap = shtest_scratch_path(c"_ln_exists.err")
	shtest_capture_stderr_start(err_cap)
	ln_s(c"anywhere", path)
	char* err = shtest_capture_stderr_end(err_cap)

	assert1(index_of(err, c"ln: failed to create symbolic link '") >= 0)
	assert1(index_of(err, c"File exists") >= 0)
	unlink(path)
	free(err)
	free(err_cap)
	free(path)


void test_ln_s_missing_parent_reports_error():
	char* err_cap = shtest_scratch_path(c"_ln_missing.err")
	shtest_capture_stderr_start(err_cap)
	ln_s(c"anywhere", c"/no/such/dir/w_shell_commands_ln_xyz")
	char* err = shtest_capture_stderr_end(err_cap)

	assert1(index_of(err, c"ln: failed to create symbolic link '") >= 0)
	assert1(index_of(err, c"No such file or directory") >= 0)
	free(err)
	free(err_cap)


void test_df_prints_header_and_one_line_per_path():
	char* cap = shtest_scratch_path(c"_df.out")
	shtest_capture_stdout_start(cap)
	df(c"/tmp")
	char* got = shtest_capture_stdout_end(cap)

	# Header plus exactly one mount line; the counts are filesystem
	# state, so only the shape is asserted (du's precedent). The mount
	# line always carries a "/"-rooted path -- the resolved mount point,
	# or "/tmp" itself on the no-match fallback.
	assert_equal(2, shtest_count_newlines(got))
	assert_equal(0, index_of(got, c"Filesystem 1K-blocks Used Available Mounted on\x0a"))
	assert1(index_of(got, c" /") >= 0)
	free(got)
	free(cap)


void test_df_no_args_lists_mounts():
	char* cap = shtest_scratch_path(c"_df_all.out")
	shtest_capture_stdout_start(cap)
	df()
	char* got = shtest_capture_stdout_end(cap)

	# At least the header and one real (nonzero-blocks) mount.
	assert_equal(0, index_of(got, c"Filesystem 1K-blocks Used Available Mounted on\x0a"))
	assert1(shtest_count_newlines(got) >= 2)
	free(got)
	free(cap)


void test_df_missing_path_reports_error():
	char* out_cap = shtest_scratch_path(c"_df_missing.out")
	char* err_cap = shtest_scratch_path(c"_df_missing.err")
	shtest_capture_stdout_start(out_cap)
	shtest_capture_stderr_start(err_cap)
	df(c"/no/such/w_shell_commands_df_xyz")
	char* err = shtest_capture_stderr_end(err_cap)
	char* out = shtest_capture_stdout_end(out_cap)

	assert1(index_of(err, c"df: ") >= 0)
	assert1(index_of(err, c"No such file or directory") >= 0)
	assert_equal(1, shtest_count_newlines(out)) /* the header only */
	free(out)
	free(err)
	free(out_cap)
	free(err_cap)


void test_ps_lists_this_process():
	char* cap = shtest_scratch_path(c"_ps.out")
	shtest_capture_stdout_start(cap)
	ps()
	char* got = shtest_capture_stdout_end(cap)

	assert_equal(0, index_of(got, c"PID PPID S COMM\x0a"))
	# Our own pid must be listed; anchor the match at a line start (the
	# header is line one, so every pid line follows a newline) so pid
	# 1234 cannot be satisfied by a line for pid 91234.
	char* pid_str = itoa(getpid())
	char* pid_line = strjoin(c"\x0a", pid_str)
	char* pid_needle = strjoin(pid_line, c" ")
	assert1(index_of(got, pid_needle) >= 0)
	# comm of this test binary (shell_commands_test / its _64 twin) --
	# the kernel truncates comm to 15 bytes, which both spell.
	assert1(index_of(got, c"shell_commands_") >= 0)
	free(pid_needle)
	free(pid_line)
	free(pid_str)
	free(got)
	free(cap)


void test_grep_prints_matching_lines():
	char* f = shtest_scratch_path(c"_grep.txt")
	file_write_text(f, c"alpha one\x0abeta two\x0agamma three\x0a")

	char* cap = shtest_scratch_path(c"_grep.out")
	shtest_capture_stdout_start(cap)
	grep(false, c"one", f)
	char* got = shtest_capture_stdout_end(cap)

	assert_strings_equal(c"alpha one\x0a", got)
	unlink(f)
	free(got)
	free(cap)
	free(f)


void test_grep_quantifiers_and_anchors_use_the_regex_engine():
	char* f = shtest_scratch_path(c"_grep_rx.txt")
	file_write_text(f, c"alpha one\x0abeta two\x0agamma three\x0a")

	char* cap = shtest_scratch_path(c"_grep_rx.out")
	shtest_capture_stdout_start(cap)
	grep(false, c"^g.m*a t", f)
	char* got = shtest_capture_stdout_end(cap)

	assert_strings_equal(c"gamma three\x0a", got)

	# '+' quantifies here (lib/regex.w's subset), unlike real grep's
	# BRE where it is a literal -- the documented divergence.
	shtest_capture_stdout_start(cap)
	grep(false, c"e+ta", f)
	char* plus = shtest_capture_stdout_end(cap)

	assert_strings_equal(c"beta two\x0a", plus)
	unlink(f)
	free(plus)
	free(got)
	free(cap)
	free(f)


void test_grep_line_numbers_flag():
	char* f = shtest_scratch_path(c"_grep_n.txt")
	file_write_text(f, c"alpha one\x0abeta two\x0agamma three\x0a")

	char* cap = shtest_scratch_path(c"_grep_n.out")
	shtest_capture_stdout_start(cap)
	grep(true, c"t", f)
	char* got = shtest_capture_stdout_end(cap)

	assert_strings_equal(c"2:beta two\x0a3:gamma three\x0a", got)
	unlink(f)
	free(got)
	free(cap)
	free(f)


void test_grep_multiple_files_prefix_names():
	char* a = shtest_scratch_path(c"_grep_a.txt")
	char* b = shtest_scratch_path(c"_grep_b.txt")
	file_write_text(a, c"match here\x0a")
	file_write_text(b, c"no\x0amatch there\x0a")

	char* cap = shtest_scratch_path(c"_grep_multi.out")
	shtest_capture_stdout_start(cap)
	grep(false, c"match", a, b)
	char* got = shtest_capture_stdout_end(cap)

	char* want_a = strjoin(a, c":match here\x0a")
	char* want_b = strjoin(b, c":match there\x0a")
	char* want = strjoin(want_a, want_b)
	assert_strings_equal(want, got)
	unlink(a)
	unlink(b)
	free(want)
	free(want_a)
	free(want_b)
	free(got)
	free(cap)
	free(a)
	free(b)


void test_grep_missing_file_reports_error_and_continues():
	char* missing = c"/no/such/w_shell_commands_grep_xyz"
	char* present = shtest_scratch_path(c"_grep_present.txt")
	file_write_text(present, c"still greppable\x0a")

	char* out_cap = shtest_scratch_path(c"_grep_missing.out")
	char* err_cap = shtest_scratch_path(c"_grep_missing.err")
	shtest_capture_stdout_start(out_cap)
	shtest_capture_stderr_start(err_cap)
	grep(false, c"greppable", missing, present)
	char* err = shtest_capture_stderr_end(err_cap)
	char* out = shtest_capture_stdout_end(out_cap)

	assert1(index_of(err, missing) >= 0)
	assert1(index_of(err, c"No such file or directory") >= 0)
	char* want = strjoin(present, c":still greppable\x0a")
	assert_strings_equal(want, out)
	unlink(present)
	free(want)
	free(out)
	free(err)
	free(out_cap)
	free(err_cap)
	free(present)


void test_grep_invalid_pattern_reports_error():
	char* f = shtest_scratch_path(c"_grep_bad.txt")
	file_write_text(f, c"anything\x0a")

	char* out_cap = shtest_scratch_path(c"_grep_bad.out")
	char* err_cap = shtest_scratch_path(c"_grep_bad.err")
	shtest_capture_stdout_start(out_cap)
	shtest_capture_stderr_start(err_cap)
	grep(false, c"[abc", f)
	char* err = shtest_capture_stderr_end(err_cap)
	char* out = shtest_capture_stdout_end(out_cap)

	assert1(index_of(err, c"grep: invalid pattern: '[abc'") >= 0)
	assert_equal(0, strlen(out))
	unlink(f)
	free(out)
	free(err)
	free(out_cap)
	free(err_cap)
	free(f)


# ---------------------------------------------------------------------------
# repl/shell_translate.w: stage 4's translator coverage (ln, df, ps,
# grep) and the quote-aware metacharacter scan.

void test_translate_ln_s_flag_forms():
	assert_strings_equal(c"shell_commands.ln_s(c\"target\", c\"link\")",
		shell_translate_line(c"ln -s target link"))
	assert_strings_equal(c"shell_commands.ln_s(c\"target\", c\"link\")",
		shell_translate_line(c"ln --symbolic target link"))


void test_translate_ln_without_s_falls_back():
	# A bare "ln" is a hard link -- no native implementation, so the
	# real tool handles it.
	assert1(shell_translate_line(c"ln target link") == 0)


void test_translate_ln_rejects_unknown_flag_and_arity():
	assert1(shell_translate_line(c"ln -sf target link") == 0)
	assert1(shell_translate_line(c"ln -s target") == 0)
	assert1(shell_translate_line(c"ln -s a b c") == 0)


void test_translate_df_bare():
	assert_strings_equal(c"shell_commands.df()", shell_translate_line(c"df"))


void test_translate_df_with_paths():
	assert_strings_equal(c"shell_commands.df(c\"/tmp\")", shell_translate_line(c"df /tmp"))
	assert_strings_equal(c"shell_commands.df(c\"a\", c\"b\")", shell_translate_line(c"df a b"))


void test_translate_df_rejects_flags():
	assert1(shell_translate_line(c"df -h") == 0)
	assert1(shell_translate_line(c"df --total /tmp") == 0)


void test_translate_ps_bare():
	assert_strings_equal(c"shell_commands.ps()", shell_translate_line(c"ps"))


void test_translate_ps_with_any_argument_falls_back():
	assert1(shell_translate_line(c"ps aux") == 0)
	assert1(shell_translate_line(c"ps -ef") == 0)


void test_translate_grep_pattern_and_file():
	assert_strings_equal(c"shell_commands.grep(false, c\"foo\", c\"/tmp/x\")",
		shell_translate_line(c"grep foo /tmp/x"))


void test_translate_grep_line_number_flag_and_multiple_files():
	assert_strings_equal(c"shell_commands.grep(true, c\"foo\", c\"a\", c\"b\")",
		shell_translate_line(c"grep -n foo a b"))
	assert_strings_equal(c"shell_commands.grep(true, c\"foo\", c\"a\")",
		shell_translate_line(c"grep --line-number foo a"))


void test_translate_grep_quoted_pattern_with_quantifiers():
	# The quote-aware rule-1 scan: '*'/'?'/'$' inside single quotes are
	# not shell-special, so the line translates and lib/regex.w gets
	# the pattern verbatim (the old position-blind scan sent every such
	# line to native).
	assert_strings_equal(c"shell_commands.grep(false, c\"a.*b\", c\"f\")",
		shell_translate_line(c"grep 'a.*b' f"))
	assert_strings_equal(c"shell_commands.grep(false, c\"foo$\", c\"f\")",
		shell_translate_line(c"grep 'foo$' f"))


void test_translate_grep_without_file_falls_back():
	# A file-less grep reads stdin -- native territory.
	assert1(shell_translate_line(c"grep foo") == 0)


void test_translate_grep_rejects_unknown_flag():
	assert1(shell_translate_line(c"grep -i foo f") == 0)
	assert1(shell_translate_line(c"grep -rn foo f") == 0)


void test_translate_grep_malformed_pattern_falls_back():
	# Patterns lib/regex.w's regex_valid rejects run the real grep
	# instead: reserved escapes, dangling quantifiers, unclosed
	# classes.
	assert1(shell_translate_line(c"grep 'a[b' f") == 0)
	assert1(shell_translate_line(c"grep '\\d' f") == 0)
	assert1(shell_translate_line(c"grep 'a**' f") == 0)


void test_translate_quoted_metacharacters_translate():
	# sh treats a single-quoted metacharacter as data, and so does the
	# tokenizer -- both print the same bytes, so no native detour is
	# needed. Double quotes keep $ and backtick active, so those still
	# fall back.
	assert_strings_equal(c"shell_commands.echo(false, c\"$HOME\")",
		shell_translate_line(c"echo '$HOME'"))
	assert_strings_equal(c"shell_commands.echo(false, c\"a|b\")",
		shell_translate_line(c"echo 'a|b'"))
	assert_strings_equal(c"shell_commands.echo(false, c\"a|b\")",
		shell_translate_line(c"echo \"a|b\""))


void test_translate_dollar_in_double_quotes_falls_back():
	assert1(shell_translate_line(c"echo \"$HOME\"") == 0)
	assert1(shell_translate_line(c"echo \"a\\$b\"") == 0)


void test_translate_escaped_metacharacter_outside_quotes_translates():
	# sh strips the backslash and passes the byte as data; so does the
	# tokenizer.
	assert_strings_equal(c"shell_commands.echo(false, c\"$HOME\")",
		shell_translate_line(c"echo \\$HOME"))
