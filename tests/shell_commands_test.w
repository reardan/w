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
import lib.process
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
	if (text == 0): return strclone(c"")
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
	char* cwd = cast(char*, malloc(4096))
	getcwd(cwd, 4096)

	char* cap = shtest_scratch_path(c"_pwd.out")
	shtest_capture_stdout_start(cap)
	shell_commands_pwd()
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
	shell_commands_ls(dir, false, false)
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
	shell_commands_ls(dir, true, false)
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
	shell_commands_ls(missing, false, false)
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
	shell_commands_cat(f)
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
	shell_commands_cat(a, b)
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
	shell_commands_cat(missing, present)
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
	shell_commands_echo(false, c"hello", c"shell", c"mode")
	char* got = shtest_capture_stdout_end(cap)

	assert_strings_equal(c"hello shell mode\x0a", got)
	free(got)
	free(cap)


void test_echo_no_newline_suppresses_trailing_newline():
	char* cap = shtest_scratch_path(c"_echo_n.out")
	shtest_capture_stdout_start(cap)
	shell_commands_echo(true, c"no-newline")
	char* got = shtest_capture_stdout_end(cap)

	assert_strings_equal(c"no-newline", got)
	free(got)
	free(cap)


void test_echo_with_no_words_prints_blank_line():
	char* cap = shtest_scratch_path(c"_echo_empty.out")
	shtest_capture_stdout_start(cap)
	shell_commands_echo(false)
	char* got = shtest_capture_stdout_end(cap)

	assert_strings_equal(c"\x0a", got)
	free(got)
	free(cap)


void test_head_prints_first_n_lines():
	char* f = shtest_scratch_path(c"_head.txt")
	file_write_text(f, c"one\x0atwo\x0athree\x0afour\x0afive\x0a")

	char* cap = shtest_scratch_path(c"_head.out")
	shtest_capture_stdout_start(cap)
	shell_commands_head(f, 3)
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
	shell_commands_head(f, 10)
	char* got = shtest_capture_stdout_end(cap)

	assert_strings_equal(c"a\x0ab\x0a", got)
	free(got)
	free(cap)
	free(f)


void test_head_missing_file_reports_error():
	char* missing = c"/no/such/w_shell_commands_test_head_xyz"
	char* err_cap = shtest_scratch_path(c"_head_missing.err")
	shtest_capture_stderr_start(err_cap)
	shell_commands_head(missing, 5)
	char* err = shtest_capture_stderr_end(err_cap)

	assert1(index_of(err, c"cannot open") >= 0)
	free(err)
	free(err_cap)


void test_tail_prints_last_n_lines():
	char* f = shtest_scratch_path(c"_tail.txt")
	file_write_text(f, c"one\x0atwo\x0athree\x0afour\x0afive\x0a")

	char* cap = shtest_scratch_path(c"_tail.out")
	shtest_capture_stdout_start(cap)
	shell_commands_tail(f, 2)
	char* got = shtest_capture_stdout_end(cap)

	assert_strings_equal(c"four\x0afive\x0a", got)
	free(got)
	free(cap)
	free(f)


void test_tail_missing_file_reports_error():
	char* missing = c"/no/such/w_shell_commands_test_tail_xyz"
	char* err_cap = shtest_scratch_path(c"_tail_missing.err")
	shtest_capture_stderr_start(err_cap)
	shell_commands_tail(missing, 5)
	char* err = shtest_capture_stderr_end(err_cap)

	assert1(index_of(err, c"cannot open") >= 0)
	free(err)
	free(err_cap)


void test_wc_default_prints_lines_words_bytes():
	char* f = shtest_scratch_path(c"_wc.txt")
	file_write_text(f, c"one two\x0athree\x0a")

	char* cap = shtest_scratch_path(c"_wc.out")
	shtest_capture_stdout_start(cap)
	shell_commands_wc(f, false, false, false)
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
	shell_commands_wc(f, true, false, false)
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
	char* data = cast(char*, malloc(8))
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
	shell_commands_wc(f, false, false, false)
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
	shell_commands_wc(missing, false, false, false)
	char* err = shtest_capture_stderr_end(err_cap)

	assert1(index_of(err, c"No such file or directory") >= 0)
	free(err)
	free(err_cap)


void test_mkdir_p_creates_a_single_directory():
	char* dir = shtest_scratch_path(c"_mkdir_single")

	shell_commands_mkdir(false, dir)

	assert1(path_exists(dir))
	rmdir(dir)
	free(dir)


void test_mkdir_p_creates_missing_ancestors():
	char* base = shtest_scratch_path(c"_mkdir_nested")
	char* mid = path_join(base, c"mid")
	char* leaf = path_join(mid, c"leaf")

	shell_commands_mkdir(true, leaf)

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
	shell_commands_mkdir(true, dir)
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

	shell_commands_rm(false, false, f)

	assert_equal(0, path_exists(f))
	free(f)


void test_rm_missing_without_force_reports_error():
	char* missing = c"/no/such/w_shell_commands_test_rm_xyz"
	char* err_cap = shtest_scratch_path(c"_rm_missing.err")
	shtest_capture_stderr_start(err_cap)
	shell_commands_rm(false, false, missing)
	char* err = shtest_capture_stderr_end(err_cap)

	assert1(index_of(err, c"No such file or directory") >= 0)
	free(err)
	free(err_cap)


void test_rm_missing_with_force_is_silent():
	char* missing = c"/no/such/w_shell_commands_test_rm_force_xyz"
	char* err_cap = shtest_scratch_path(c"_rm_force_missing.err")
	shtest_capture_stderr_start(err_cap)
	shell_commands_rm(false, true, missing)
	char* err = shtest_capture_stderr_end(err_cap)

	assert_equal(0, strlen(err))
	free(err)
	free(err_cap)


void test_rm_directory_without_recursive_reports_is_a_directory():
	char* dir = shtest_scratch_path(c"_rm_dir_norec")
	mkdir(dir, 493)

	char* err_cap = shtest_scratch_path(c"_rm_dir_norec.err")
	shtest_capture_stderr_start(err_cap)
	shell_commands_rm(false, false, dir)
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

	shell_commands_rm(true, false, dir)

	assert_equal(0, path_exists(dir))
	free(dir)
	free(nested)


void test_cp_copies_a_file():
	char* src = shtest_scratch_path(c"_cp_src.txt")
	char* dst = shtest_scratch_path(c"_cp_dst.txt")
	file_write_text(src, c"copy me\x0a")

	shell_commands_cp(false, src, dst)

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
	shell_commands_cp(false, missing, dst)
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
	shell_commands_cp(false, src, dst)
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

	shell_commands_cp(true, src, dst)

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

	shell_commands_mv(src, dst)

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
	shell_commands_mv(missing, dst)
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
	shell_commands_ls(dir, false, true)
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
	shell_commands_ls(dir, false, true)
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
	shell_commands_touch(false, path)
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
	shell_commands_touch(true, path)
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
	shell_commands_touch(false, path)
	file_stat after
	assert_equal(0, file_stat_path(path, &after))
	assert1(after.mtime > 1000000)
	unlink(path)
	free(path)


void test_touch_missing_parent_reports_cannot_touch():
	char* path = c"/no/such/dir/w_shell_commands_touch_xyz.txt"
	char* err_cap = shtest_scratch_path(c"_touch_missing.err")
	shtest_capture_stderr_start(err_cap)
	shell_commands_touch(false, path)
	char* err = shtest_capture_stderr_end(err_cap)

	assert1(index_of(err, c"touch: cannot touch '") >= 0)
	assert1(index_of(err, c"No such file or directory") >= 0)
	free(err)
	free(err_cap)


void test_chmod_octal_sets_permission_bits():
	char* path = shtest_scratch_path(c"_chmod.txt")
	file_write_text(path, c"c")
	shell_commands_chmod_octal(384, path) /* 384 = 0600 */
	file_stat st
	assert_equal(0, file_stat_path(path, &st))
	assert_equal(384, file_mode_perm(&st))
	shell_commands_chmod_octal(493, path) /* 493 = 0755 */
	assert_equal(0, file_stat_path(path, &st))
	assert_equal(493, file_mode_perm(&st))
	unlink(path)
	free(path)


void test_chmod_octal_missing_path_reports_error():
	char* err_cap = shtest_scratch_path(c"_chmod_missing.err")
	shtest_capture_stderr_start(err_cap)
	shell_commands_chmod_octal(420, c"/no/such/w_shell_commands_chmod_xyz.txt")
	char* err = shtest_capture_stderr_end(err_cap)

	assert1(index_of(err, c"chmod: cannot access '") >= 0)
	assert1(index_of(err, c"No such file or directory") >= 0)
	free(err)
	free(err_cap)


int shtest_count_newlines(char* s):
	int count = 0
	int i = 0
	while (s[i] != 0):
		if (s[i] == 10): count = count + 1
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
	shell_commands_du(true, dir)
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
	shell_commands_du(false, dir)
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
	shell_commands_du(false, path)
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
	shell_commands_du(false, c"/no/such/w_shell_commands_du_dir_xyz")
	char* err = shtest_capture_stderr_end(err_cap)

	assert1(index_of(err, c"du: cannot access '") >= 0)
	assert1(index_of(err, c"No such file or directory") >= 0)
	free(err)
	free(err_cap)


# ---------------------------------------------------------------------------
# repl/shell_translate.w: the argv/flag -> W call translator, pure logic.

# shell_translate_line(line) must give want; 0 means the line falls
# back to the native shell.
void tr(char* line, char* want):
	char* got = shell_translate_line(line)
	int same = want == got
	if ((want != 0) && (got != 0)): same = strcmp(want, got) == 0
	if (same == 0):
		print2(c"translating: ")
		println2(line)
	assert_strings_equal(want, got)


void test_translate_stage1():
	tr(c"pwd", c"shell_commands_pwd()")
	tr(c"pwd extra", 0)
	tr(c"ls", c"shell_commands_ls(c\".\", false, false)")
	tr(c"ls -a", c"shell_commands_ls(c\".\", true, false)")
	tr(c"ls --all", c"shell_commands_ls(c\".\", true, false)")
	tr(c"ls /tmp", c"shell_commands_ls(c\"/tmp\", false, false)")
	# Stage 3: "-l" is now a known flag (lib/stat.w closed the
	# stat-wrapper gap the stage 1 tests documented), alone or
	# clustered with -a in either order.
	tr(c"ls -l", c"shell_commands_ls(c\".\", false, true)")
	tr(c"ls -la", c"shell_commands_ls(c\".\", true, true)")
	tr(c"ls -al /tmp", c"shell_commands_ls(c\"/tmp\", true, true)")
	# "no partial credit" (Sec 5.4): one unknown letter fails the whole
	# cluster even when 'l' and 'a' are both known.
	tr(c"ls -lah", 0)
	tr(c"ls -x", 0)
	tr(c"ls a b", 0)
	tr(c"cat", c"shell_commands_cat()")
	tr(c"cat a.txt", c"shell_commands_cat(c\"a.txt\")")
	tr(c"cat a.txt b.txt", c"shell_commands_cat(c\"a.txt\", c\"b.txt\")")
	tr(c"cat -n a.txt", 0)
	# Unsupported sed scripts and find actions stay external.
	tr(c"sed hi", 0)
	tr(c"find . -exec echo x", 0)
	tr(c"cat 'a b.txt'", c"shell_commands_cat(c\"a b.txt\")")
	tr(c"cat \"plain\"", c"shell_commands_cat(c\"plain\")")
	# "foo\ bar.txt" -> one word, the escaped space kept literal.
	tr(c"cat foo\\ bar.txt", c"shell_commands_cat(c\"foo bar.txt\")")
	# Sec 5.2 rule 1: any of these anywhere on the line means "native
	# fallback, unconditionally" -- pipe, redirection, chaining,
	# backgrounding, variable/command/glob expansion.
	tr(c"ls foo | bar", 0)
	tr(c"cat foo > bar.txt", 0)
	tr(c"cat foo < bar.txt", 0)
	tr(c"ls; pwd", 0)
	tr(c"ls & pwd", 0)
	tr(c"echo $HOME", 0)
	tr(c"cat `pwd`", 0)
	tr(c"ls ~", 0)
	tr(c"ls *", 0)
	tr(c"ls foo?", 0)


# ---------------------------------------------------------------------------
# repl/shell_translate.w: stage 2's translator coverage (echo, head,
# tail, wc, mkdir, rm, cp, mv).

void test_translate_stage2():
	tr(c"echo hi there", c"shell_commands_echo(false, c\"hi\", c\"there\")")
	tr(c"echo -n hi", c"shell_commands_echo(true, c\"hi\")")
	tr(c"echo", c"shell_commands_echo(false)")
	tr(c"echo -x hi", 0)
	# Real echo only honors "-n" while it leads the argument list; after
	# the first ordinary word it is plain text to print.
	tr(c"echo hi -n", c"shell_commands_echo(false, c\"hi\", c\"-n\")")
	tr(c"echo a -n b", c"shell_commands_echo(false, c\"a\", c\"-n\", c\"b\")")
	# Real echo consumes a whole leading run of "-n" flags.
	tr(c"echo -n -n hi", c"shell_commands_echo(true, c\"hi\")")
	tr(c"head a.txt", c"shell_commands_head(c\"a.txt\", 10)")
	tr(c"head -n 5 a.txt", c"shell_commands_head(c\"a.txt\", 5)")
	# "-n=5"/"--lines=5" are lib/args.w spellings, not head's ("head
	# -n=5" is an "invalid number of lines: '=5'" error from the real
	# tool) -- the line fails closed to native so the real tool's own
	# acceptance or diagnostic applies, instead of the translator
	# accepting a form the native tool would not.
	tr(c"head -n=5 a.txt", 0)
	tr(c"head --lines=5 a.txt", 0)
	tr(c"head --lines 5 a.txt", c"shell_commands_head(c\"a.txt\", 5)")
	tr(c"head -n five a.txt", 0)
	tr(c"head -n 5", c"shell_commands_head(c\"-\", 5)")
	tr(c"head a.txt b.txt", 0)
	tr(c"tail a.txt", c"shell_commands_tail(c\"a.txt\", 10)")
	tr(c"tail -n 3 a.txt", c"shell_commands_tail(c\"a.txt\", 3)")
	# Same rationale as head's: not the real tools' forms.
	tr(c"tail -n=3 a.txt", 0)
	tr(c"tail --lines=3 a.txt", 0)
	tr(c"wc a.txt", c"shell_commands_wc(c\"a.txt\", false, false, false)")
	tr(c"wc -l a.txt", c"shell_commands_wc(c\"a.txt\", true, false, false)")
	tr(c"wc -lw a.txt", c"shell_commands_wc(c\"a.txt\", true, true, false)")
	tr(c"wc -lwc a.txt", c"shell_commands_wc(c\"a.txt\", true, true, true)")
	tr(c"wc -x a.txt", 0)
	tr(c"wc -l", c"shell_commands_wc(c\"\", true, false, false)")
	tr(c"mkdir newdir", c"shell_commands_mkdir(false, c\"newdir\")")
	tr(c"mkdir -p a/b/c", c"shell_commands_mkdir(true, c\"a/b/c\")")
	tr(c"mkdir --parents a/b/c", c"shell_commands_mkdir(true, c\"a/b/c\")")
	tr(c"mkdir a b", c"shell_commands_mkdir(false, c\"a\", c\"b\")")
	tr(c"mkdir -p", 0)
	tr(c"rm a.txt", c"shell_commands_rm(false, false, c\"a.txt\")")
	tr(c"rm -rf dir", c"shell_commands_rm(true, true, c\"dir\")")
	tr(c"rm --recursive dir", c"shell_commands_rm(true, false, c\"dir\")")
	tr(c"rm a b", c"shell_commands_rm(false, false, c\"a\", c\"b\")")
	tr(c"rm -f", 0)
	tr(c"cp a.txt b.txt", c"shell_commands_cp(false, c\"a.txt\", c\"b.txt\")")
	tr(c"cp -r src dst", c"shell_commands_cp(true, c\"src\", c\"dst\")")
	tr(c"cp a.txt", 0)
	tr(c"cp a.txt b.txt c.txt", 0)
	tr(c"mv a.txt b.txt", c"shell_commands_mv(c\"a.txt\", c\"b.txt\")")
	tr(c"mv -f a.txt b.txt", 0)
	tr(c"mv a.txt", 0)


# ---------------------------------------------------------------------------
# repl/shell_translate.w: stage 3's translator coverage (ls -l above,
# touch, chmod, du).

void test_translate_stage3():
	tr(c"touch a.txt", c"shell_commands_touch(false, c\"a.txt\")")
	tr(c"touch -c a.txt", c"shell_commands_touch(true, c\"a.txt\")")
	tr(c"touch --no-create a.txt", c"shell_commands_touch(true, c\"a.txt\")")
	tr(c"touch a b", c"shell_commands_touch(false, c\"a\", c\"b\")")
	tr(c"touch", 0)
	tr(c"touch -c", 0)
	# Real touch's valued flags (-t STAMP, -d DATE, -r FILE) are
	# unknown here and fail the whole line closed to native.
	tr(c"touch -t 202601010000 a.txt", 0)
	tr(c"chmod 644 a.txt", c"shell_commands_chmod_octal(420, c\"a.txt\")")
	tr(c"chmod 0755 a b", c"shell_commands_chmod_octal(493, c\"a\", c\"b\")")
	# Symbolic modes are not octal digits; the whole line fails closed
	# to the real chmod, whose full mode grammar then applies.
	tr(c"chmod u+x a.txt", 0)
	tr(c"chmod a=r a.txt", 0)
	tr(c"chmod 999 a.txt", 0)
	tr(c"chmod 00644 a.txt", 0)
	tr(c"chmod 644", 0)
	tr(c"chmod", 0)
	# No -R in v1; a '-' word anywhere fails the line.
	tr(c"chmod -R 755 dir", 0)
	tr(c"du", c"shell_commands_du(false, c\".\")")
	tr(c"du -s /tmp", c"shell_commands_du(true, c\"/tmp\")")
	tr(c"du --summarize /tmp", c"shell_commands_du(true, c\"/tmp\")")
	tr(c"du -h", 0)
	tr(c"du -sh /tmp", 0)
	tr(c"du a b", 0)


# ---------------------------------------------------------------------------
# lib/shell_commands.w: stage 4's tools (ln -s, df, ps, grep).

void test_ln_s_creates_a_symlink():
	char* dir = shtest_scratch_path(c"_ln_dir")
	mkdir(dir, 493)
	char* target = path_join(dir, c"target.txt")
	file_write_text(target, c"ln target content\x0a")
	char* link_path = path_join(dir, c"link.txt")

	shell_commands_ln_s(c"target.txt", link_path)

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
	shell_commands_ln_s(c"anywhere", path)
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
	shell_commands_ln_s(c"anywhere", c"/no/such/dir/w_shell_commands_ln_xyz")
	char* err = shtest_capture_stderr_end(err_cap)

	assert1(index_of(err, c"ln: failed to create symbolic link '") >= 0)
	assert1(index_of(err, c"No such file or directory") >= 0)
	free(err)
	free(err_cap)


void test_df_prints_header_and_one_line_per_path():
	char* cap = shtest_scratch_path(c"_df.out")
	shtest_capture_stdout_start(cap)
	shell_commands_df(c"/tmp")
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
	shell_commands_df()
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
	shell_commands_df(c"/no/such/w_shell_commands_df_xyz")
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
	shell_commands_ps()
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
	shell_commands_grep(false, c"one", f)
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
	shell_commands_grep(false, c"^g.m*a t", f)
	char* got = shtest_capture_stdout_end(cap)

	assert_strings_equal(c"gamma three\x0a", got)

	# '+' quantifies here (lib/regex.w's subset), unlike real grep's
	# BRE where it is a literal -- the documented divergence.
	shtest_capture_stdout_start(cap)
	shell_commands_grep(false, c"e+ta", f)
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
	shell_commands_grep(true, c"t", f)
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
	shell_commands_grep(false, c"match", a, b)
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
	shell_commands_grep(false, c"greppable", missing, present)
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
	shell_commands_grep(false, c"[abc", f)
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

void test_translate_stage4():
	tr(c"ln -s target link", c"shell_commands_ln_s(c\"target\", c\"link\")")
	tr(c"ln --symbolic target link", c"shell_commands_ln_s(c\"target\", c\"link\")")
	# A bare ln creates a hard link.
	tr(c"ln target link", c"shell_commands_ln(c\"target\", c\"link\")")
	tr(c"ln -sf target link", 0)
	tr(c"ln -s target", 0)
	tr(c"ln -s a b c", 0)
	tr(c"df", c"shell_commands_df()")
	tr(c"df /tmp", c"shell_commands_df(c\"/tmp\")")
	tr(c"df a b", c"shell_commands_df(c\"a\", c\"b\")")
	tr(c"df -h", 0)
	tr(c"df --total /tmp", 0)
	tr(c"ps", c"shell_commands_ps()")
	tr(c"ps aux", 0)
	tr(c"ps -ef", 0)
	tr(c"grep foo /tmp/x", c"shell_commands_grep(false, c\"foo\", c\"/tmp/x\")")
	tr(c"grep -n foo a b", c"shell_commands_grep(true, c\"foo\", c\"a\", c\"b\")")
	tr(c"grep --line-number foo a", c"shell_commands_grep(true, c\"foo\", c\"a\")")
	# The quote-aware rule-1 scan: '*'/'?'/'$' inside single quotes are
	# not shell-special, so the line translates and lib/regex.w gets
	# the pattern verbatim (the old position-blind scan sent every such
	# line to native).
	tr(c"grep 'a.*b' f", c"shell_commands_grep(false, c\"a.*b\", c\"f\")")
	tr(c"grep 'foo$' f", c"shell_commands_grep(false, c\"foo$\", c\"f\")")
	# A file-less grep reads stdin.
	tr(c"grep foo", c"shell_commands_grep(false, c\"foo\")")
	tr(c"grep -i foo f", 0)
	tr(c"grep -rn foo f", 0)
	# Patterns lib/regex.w's regex_valid rejects run the real grep
	# instead: reserved escapes, dangling quantifiers, unclosed
	# classes.
	tr(c"grep 'a[b' f", 0)
	tr(c"grep '\\d' f", 0)
	tr(c"grep 'a**' f", 0)
	# sh treats a single-quoted metacharacter as data, and so does the
	# tokenizer -- both print the same bytes, so no native detour is
	# needed. Double quotes keep $ and backtick active, so those still
	# fall back.
	tr(c"echo '$HOME'", c"shell_commands_echo(false, c\"$HOME\")")
	tr(c"echo 'a|b'", c"shell_commands_echo(false, c\"a|b\")")
	tr(c"echo \"a|b\"", c"shell_commands_echo(false, c\"a|b\")")
	tr(c"echo \"$HOME\"", 0)
	tr(c"echo \"a\\$b\"", 0)
	# sh strips the backslash and passes the byte as data; so does the
	# tokenizer.
	tr(c"echo \\$HOME", c"shell_commands_echo(false, c\"$HOME\")")


# ---------------------------------------------------------------------------
# Exit statuses (design doc Sec 12): every tool returns 0 on success
# and nonzero on failure, like the real command's process; grep uses
# the real grep's 0/1/2.

# Output of the tool calls below goes to scratch files: only the
# returned statuses are under test here.
void shtest_quiet_start():
	shtest_capture_stdout_start(shtest_scratch_path(c"_status.out"))
	shtest_capture_stderr_start(shtest_scratch_path(c"_status.err"))


void shtest_quiet_end():
	free(shtest_capture_stderr_end(shtest_scratch_path(c"_status.err")))
	free(shtest_capture_stdout_end(shtest_scratch_path(c"_status.out")))


void test_tools_return_zero_on_success():
	char* dir = shtest_scratch_path(c"_status_ok_dir")
	char* f = path_join(dir, c"f.txt")
	char* g = path_join(dir, c"g.txt")
	char* link = path_join(dir, c"link.txt")
	shtest_quiet_start()
	int mkdir_status = shell_commands_mkdir(true, dir)
	file_write_text(f, c"alpha\x0abeta\x0a")
	int cp_status = shell_commands_cp(false, f, g)
	int statuses = shell_commands_pwd() | shell_commands_ls(dir, true, true) |
		shell_commands_cat(f) | shell_commands_echo(false, c"x") |
		shell_commands_head(f, 1) | shell_commands_tail(f, 1) |
		shell_commands_wc(f, false, false, false) | shell_commands_touch(false, g) |
		shell_commands_chmod_octal(420, g) | shell_commands_du(true, dir) |
		shell_commands_ln_s(c"f.txt", link) | shell_commands_df(dir) | shell_commands_ps()
	int mv_status = shell_commands_mv(g, path_join(dir, c"h.txt"))
	int grep_status = shell_commands_grep(false, c"beta", f)
	int rm_status = shell_commands_rm(true, false, dir)
	shtest_quiet_end()
	assert_equal(0, mkdir_status)
	assert_equal(0, cp_status)
	assert_equal(0, statuses)
	assert_equal(0, mv_status)
	assert_equal(0, grep_status)
	assert_equal(0, rm_status)
	free(link)
	free(g)
	free(f)
	free(dir)


void test_tools_return_one_on_failure():
	char* missing = c"/no/such/w_shell_commands_status_xyz"
	shtest_quiet_start()
	int ls_status = shell_commands_ls(missing, false, false)
	int cat_status = shell_commands_cat(missing)
	int head_status = shell_commands_head(missing, 1)
	int tail_status = shell_commands_tail(missing, 1)
	int wc_status = shell_commands_wc(missing, false, false, false)
	int mkdir_status = shell_commands_mkdir(false, c"/no/such/parent/child")
	int rm_status = shell_commands_rm(false, false, missing)
	int cp_status = shell_commands_cp(false, missing, c"/tmp/w_shell_commands_status_never")
	int mv_status = shell_commands_mv(missing, c"/tmp/w_shell_commands_status_never")
	int touch_status = shell_commands_touch(false, c"/no/such/dir/f")
	int chmod_status = shell_commands_chmod_octal(420, missing)
	int du_status = shell_commands_du(false, missing)
	int ln_status = shell_commands_ln_s(c"x", c"/no/such/dir/link")
	int df_status = shell_commands_df(missing)
	shtest_quiet_end()
	assert_equal(1, ls_status)
	assert_equal(1, cat_status)
	assert_equal(1, head_status)
	assert_equal(1, tail_status)
	assert_equal(1, wc_status)
	assert_equal(1, mkdir_status)
	assert_equal(1, rm_status)
	assert_equal(1, cp_status)
	assert_equal(1, mv_status)
	assert_equal(1, touch_status)
	assert_equal(1, chmod_status)
	assert_equal(1, du_status)
	assert_equal(1, ln_status)
	assert_equal(1, df_status)


void test_multi_path_tools_fail_when_any_path_fails():
	char* f = shtest_scratch_path(c"_status_partial.txt")
	file_write_text(f, c"x\x0a")
	shtest_quiet_start()
	int cat_status = shell_commands_cat(f, c"/no/such/w_status_partial")
	shtest_quiet_end()
	assert_equal(1, cat_status)
	unlink(f)
	free(f)


void test_rm_force_on_a_missing_path_succeeds():
	shtest_quiet_start()
	int status = shell_commands_rm(false, true, c"/no/such/w_shell_commands_status_force")
	shtest_quiet_end()
	assert_equal(0, status)


void test_grep_status_matches_real_grep():
	char* f = shtest_scratch_path(c"_status_grep.txt")
	file_write_text(f, c"alpha\x0abeta\x0a")
	shtest_quiet_start()
	int hit = shell_commands_grep(false, c"alp", f)
	int miss = shell_commands_grep(false, c"gamma", f)
	int missing_file = shell_commands_grep(false, c"alp", f, c"/no/such/w_status_grep")
	int bad_pattern = shell_commands_grep(false, c"a**", f)
	shtest_quiet_end()
	assert_equal(0, hit)
	assert_equal(1, miss)
	assert_equal(2, missing_file)
	assert_equal(2, bad_pattern)
	unlink(f)
	free(f)


# ---------------------------------------------------------------------------
# Session-function calls (design doc Sec 12): typed words become a
# call of the user's own function, one literal per parameter kind.

list[char*] shtest_words(char* line):
	return shell_translate_tokenize(line)


void test_session_call_renders_each_kind():
	list[int] kinds = new list[int]
	kinds.push(shell_arg_string)
	kinds.push(shell_arg_int)
	kinds.push(shell_arg_bool)
	assert_strings_equal(c"greet(c\"wor\\\"ld\", -3, true)",
		shell_translate_session_call(shtest_words(c"greet 'wor\"ld' -3 1"), kinds, 3, -1))


void test_session_call_passes_flags_as_plain_words():
	list[int] kinds = new list[int]
	kinds.push(shell_arg_string)
	assert_strings_equal(c"ls(c\"-la\")",
		shell_translate_session_call(shtest_words(c"ls -la"), kinds, 1, -1))


void test_session_call_checks_arity_and_defaults():
	list[int] kinds = new list[int]
	kinds.push(shell_arg_int)
	kinds.push(shell_arg_int)
	# The second parameter has a default: it may be left off, but a
	# third word has nowhere to go.
	assert_strings_equal(c"add(1)", shell_translate_session_call(shtest_words(c"add 1"), kinds, 1, -1))
	assert1(shell_translate_session_call(shtest_words(c"add"), kinds, 1, -1) == 0)
	assert1(shell_translate_session_call(shtest_words(c"add 1 2 3"), kinds, 1, -1) == 0)


void test_session_call_rejects_words_that_do_not_fit():
	list[int] kinds = new list[int]
	kinds.push(shell_arg_int)
	kinds.push(shell_arg_bool)
	assert1(shell_translate_session_call(shtest_words(c"f x true"), kinds, 2, -1) == 0)
	assert1(shell_translate_session_call(shtest_words(c"f 1 maybe"), kinds, 2, -1) == 0)


void test_session_call_variadic_takes_the_rest():
	list[int] kinds = new list[int]
	kinds.push(shell_arg_bool)
	assert_strings_equal(c"shout(false, c\"a\", c\"b\")",
		shell_translate_session_call(shtest_words(c"shout false a b"), kinds, 1, shell_arg_string))
	assert_strings_equal(c"shout(true)",
		shell_translate_session_call(shtest_words(c"shout true"), kinds, 1, shell_arg_string))


# Real fd0 redirection, repeated in one process to catch stale singleton
# buffers/EOF state and accidental closing of stdin after each invocation.
void shtest_stdin_start(char* text):
	dup2(0, 92)
	char* path = shtest_scratch_path(c"_stdin")
	file_write_text(path, text)
	int fd = open(path, 0, 0)
	assert1(fd >= 0)
	dup2(fd, 0)
	close(fd)
	unlink(path)
	free(path)


void shtest_stdin_end():
	# dup2 fails with EBADF if a tool closed fd0.
	assert1(dup2(0, 93) >= 0)
	close(93)
	dup2(92, 0)
	close(92)


void test_stdin_tools_and_fresh_invocations():
	char* cap = shtest_scratch_path(c"_stdin.out")
	for i in range(8):
		shtest_stdin_start(c"alpha one\x0abeta two\x0a")
		shtest_capture_stdout_start(cap)
		int status = 1
		if (i == 0): status = shell_commands_cat()
		if (i == 1): status = shell_commands_cat(c"-")
		if (i == 2): status = shell_commands_head(c"-", 1)
		if (i == 3): status = shell_commands_tail(c"-", 1)
		if (i == 4): status = shell_commands_wc(c"", false, false, true)
		if (i == 5): status = shell_commands_grep(false, c"beta")
		if (i == 6): status = shell_commands_grep(true, c"alpha", c"-")
		if (i == 7): status = shell_commands_sed(false, c"s/[a-z]*/X/")
		char* got = shtest_capture_stdout_end(cap)
		shtest_stdin_end()
		assert_equal(0, status)
		if (i < 2): assert_strings_equal(c"alpha one\x0abeta two\x0a", got)
		if (i == 2): assert_strings_equal(c"alpha one\x0a", got)
		if ((i == 3) || (i == 5)): assert_strings_equal(c"beta two\x0a", got)
		if (i == 4): assert_strings_equal(c"19\x0a", got)
		if (i == 6): assert_strings_equal(c"1:alpha one\x0a", got)
		if (i == 7): assert_strings_equal(c"X one\x0aX two\x0a", got)
		free(got)
	free(cap)


void test_translate_stdin_and_new_tools():
	tr(c"cat -", c"shell_commands_cat(c\"-\")")
	tr(c"head", c"shell_commands_head(c\"-\", 10)")
	tr(c"tail -n 1 -", c"shell_commands_tail(c\"-\", 1)")
	tr(c"wc -c", c"shell_commands_wc(c\"\", false, false, true)")
	tr(c"wc -l -", c"shell_commands_wc(c\"-\", true, false, false)")
	tr(c"grep x -", c"shell_commands_grep(false, c\"x\", c\"-\")")
	tr(c"find", c"shell_commands_find(c\".\", c\"*\", c\"\", 0, 2147483647)")
	tr(c"find dir -name '*.w' -type f -mindepth 1 -maxdepth 2 -print", c"shell_commands_find(c\"dir\", c\"*.w\", c\"f\", 1, 2)")
	tr(c"find -type l", c"shell_commands_find(c\".\", c\"*\", c\"l\", 0, 2147483647)")
	tr(c"find . -type d -maxdepth 0", c"shell_commands_find(c\".\", c\"*\", c\"d\", 0, 0)")
	tr(c"find . -print -name x", 0)
	tr(c"find . -name x -name y", 0)
	tr(c"find . -name '[ab]'", 0)
	tr(c"find . -maxdepth 999999999999", 0)
	tr(c"find . -mindepth -1", 0)
	tr(c"find . -type b", 0)
	tr(c"find . -name", 0)
	tr(c"find a b", 0)
	tr(c"find -L .", 0)
	tr(c"find . -delete", 0)
	tr(c"sed 's/a/A/g'", c"shell_commands_sed(false, c\"s/a/A/g\")")
	tr(c"sed -n p a -", c"shell_commands_sed(true, c\"p\", c\"a\", c\"-\")")
	tr(c"sed d", c"shell_commands_sed(false, c\"d\")")
	tr(c"sed -i 's/a/b/' f", 0)
	tr(c"sed 's/a+/b/'", 0)
	tr(c"sed 's/a/b/i'", 0)
	tr(c"sed 's//b/'", 0)
	tr(c"sed 's/a/\\1/'", 0)
	tr(c"sed 's/a/b/;p'", 0)
	tr(c"sed '1p'", 0)
	tr(c"sed", 0)
	tr(c"sed -n", 0)
	tr(c"sed p --unknown", 0)
	tr(c"ln -f a b", 0)


void test_sed_substitution_edges():
	assert_strings_equal(c"<aaa> b aa", shell_commands_sed_replace(c"aaa b aa", c"a*", c"<&>", 0))
	assert_strings_equal(c"XbX", shell_commands_sed_replace(c"ab", c"a*", c"X", 1))
	assert_strings_equal(c"XaXbX", shell_commands_sed_replace(c"ab", c"z*", c"X", 1))
	assert_strings_equal(c"Xab", shell_commands_sed_replace(c"ab", c"^", c"X", 1))
	assert_strings_equal(c"abX", shell_commands_sed_replace(c"ab", c"$", c"X", 1))
	assert_strings_equal(c"XX", shell_commands_sed_replace(c"aa", c"a", c"X", 1))
	assert_strings_equal(c"bb", shell_commands_sed_replace(c"bb", c"a", c"X", 1))
	assert_strings_equal(c"X", shell_commands_sed_replace(c"", c"^$", c"X", 1))


void test_sed_files_print_delete_quiet_and_errors():
	char* path = shtest_scratch_path(c"_sed.txt")
	char* cap = shtest_scratch_path(c"_sed.out")
	file_write_text(path, c"aaa\x0abb")
	for i in range(5):
		shtest_capture_stdout_start(cap)
		int status = 1
		if (i == 0): status = shell_commands_sed(false, c"s/a*/X/g", path)
		if (i == 1): status = shell_commands_sed(true, c"p", path)
		if (i == 2): status = shell_commands_sed(false, c"p", path)
		if (i == 3): status = shell_commands_sed(false, c"d", path)
		if (i == 4): status = shell_commands_sed(true, c"s/a/X/", path)
		char* got = shtest_capture_stdout_end(cap)
		assert_equal(0, status)
		if (i == 0): assert_strings_equal(c"X\x0aXbXbX", got)
		if (i == 1): assert_strings_equal(c"aaa\x0abb", got)
		if (i == 2): assert_strings_equal(c"aaa\x0aaaa\x0abbbb", got)
		if (i >= 3): assert_strings_equal(c"", got)
		free(got)
	shtest_quiet_start()
	assert_equal(1, shell_commands_sed(false, c"bad script", path))
	assert_equal(1, shell_commands_sed(false, c"p", c"/no/such/w_sed", path))
	shtest_quiet_end()
	unlink(path)
	free(path)
	free(cap)


void test_find_depth_types_names_and_symlinks():
	char* dir = shtest_scratch_path(c"_find")
	char* sub = path_join(dir, c"sub")
	char* a = path_join(dir, c"a.w")
	char* b = path_join(sub, c"b.w")
	char* link = path_join(dir, c"loop")
	char* broken = path_join(dir, c"broken")
	assert_equal(0, shell_commands_mkdir(true, sub))
	file_write_text(a, c"a")
	file_write_text(b, c"b")
	assert_equal(0, shell_commands_ln_s(c".", link))
	assert_equal(0, shell_commands_ln_s(c"absent", broken))
	char* cap = shtest_scratch_path(c"_find.out")
	for i in range(6):
		shtest_capture_stdout_start(cap)
		int status = 1
		if (i == 0): status = shell_commands_find(dir, c"*", c"", 0, 10)
		if (i == 1): status = shell_commands_find(dir, c"?.w", c"f", 1, 1)
		if (i == 2): status = shell_commands_find(dir, c"*.w", c"f", 2, 2)
		if (i == 3): status = shell_commands_find(dir, c"*", c"d", 0, 0)
		if (i == 4): status = shell_commands_find(dir, c"*", c"l", 0, 10)
		if (i == 5): status = shell_commands_find(link, c"*", c"l", 0, 10)
		char* got = shtest_capture_stdout_end(cap)
		assert_equal(0, status)
		if (i == 0): assert_equal(6, shtest_count_newlines(got))
		if (i == 1): assert_strings_equal(strjoin(a, c"\x0a"), got)
		if (i == 2): assert_strings_equal(strjoin(b, c"\x0a"), got)
		if (i == 3): assert_strings_equal(strjoin(dir, c"\x0a"), got)
		if (i == 4): assert_equal(2, shtest_count_newlines(got))
		if (i == 5): assert_strings_equal(strjoin(link, c"\x0a"), got)
		free(got)
	shtest_quiet_start()
	assert_equal(1, shell_commands_find(c"/no/such/w_find", c"*", c"", 0, 1))
	assert_equal(1, shell_commands_find(dir, c"*", c"z", 0, 1))
	assert_equal(1, shell_commands_find(dir, c"*", c"", -1, 1))
	shtest_quiet_end()
	assert_equal(1, shell_glob_match(c"a*b?", c"axxbz"))
	assert_equal(0, shell_glob_match(c"a*b?", c"axxb"))
	assert_equal(0, shell_glob_match(c"abc", c"abd"))
	assert_equal(1, shell_glob_match(c"*", c".hidden"))
	assert_equal(0, shell_glob_valid(c"a\\b"))
	shell_commands_rm(true, false, dir)
	free(cap)
	free(broken)
	free(link)
	free(b)
	free(a)
	free(sub)
	free(dir)


void test_ln_hard_links_share_content_without_replacing():
	char* dir = shtest_scratch_path(c"_hardlinks")
	char* sub = path_join(dir, c"sub")
	char* source = path_join(dir, c"source")
	char* dest = path_join(dir, c"dest")
	shell_commands_mkdir(true, sub)
	file_write_text(source, c"before")
	assert_equal(0, shell_commands_ln(source, dest))
	assert_equal(0, shell_commands_ln(source, sub))
	file_stat st
	assert_equal(0, file_stat_path(source, &st))
	assert_equal(3, st.nlink)
	file_write_text(dest, c"after")
	assert_strings_equal(c"after", file_read_text(source))
	shtest_quiet_start()
	assert_equal(1, shell_commands_ln(source, dest))
	assert_equal(1, shell_commands_ln(c"/no/such/w_link", path_join(dir, c"missing")))
	shtest_quiet_end()
	assert_strings_equal(c"after", file_read_text(dest))
	shell_commands_rm(true, false, dir)
	free(dest)
	free(source)
	free(sub)
	free(dir)


# Keep the producer end OPEN while waiting for the consumer: no EOF is
# possible. Whole-input head would hang here just as with yes | head.
# Timeout kills/reaps only the test child, then produces a normal failure.
void test_head_pipe_exits_before_producer_eof():
	char* cap = shtest_scratch_path(c"_head_pipe.out")
	for n in range(2):
		int read_end = -1
		int write_end = -1
		assert_equal(0, process_make_pipe(&read_end, &write_end))
		shtest_capture_stdout_start(cap)
		int pid = fork()
		assert1(pid >= 0)
		if (pid == 0):
			close(write_end)
			dup2(read_end, 0)
			close(read_end)
			exit(shell_commands_head(c"-", n))
		close(read_end)
		if (n > 0): assert_equal(6, write(write_end, c"first\x0a", 6))
		process* child = new process
		child.pid = pid
		child.stdin_fd = -1
		child.stdout_fd = -1
		child.stderr_fd = -1
		child.reaped = 0
		child.win_handle = 0
		int status = process_wait_timeout(child, 1500)
		if (status == process_status_timeout):
			process_kill(child, sigkill)
			process_wait(child)
		close(write_end)
		process_free(child)
		char* got = shtest_capture_stdout_end(cap)
		assert_equal(0, status)
		if (n == 0): assert_strings_equal(c"", got)
		else: assert_strings_equal(c"first\x0a", got)
		free(got)
	free(cap)


void test_head_tail_preserve_partial_lines_and_tail_ring():
	char* path = shtest_scratch_path(c"_partial_lines")
	char* cap = shtest_scratch_path(c"_partial_lines.out")
	file_write_text(path, c"a\x0ab\x0ac\x0ad")
	for i in range(4):
		shtest_capture_stdout_start(cap)
		int status = 0
		if (i == 0): status = shell_commands_head(path, 20)
		if (i == 1): status = shell_commands_tail(path, 2)
		if (i == 2): status = shell_commands_tail(path, 0)
		if (i == 3): status = shell_commands_tail(path, 20)
		char* got = shtest_capture_stdout_end(cap)
		assert_equal(0, status)
		if ((i == 0) || (i == 3)): assert_strings_equal(c"a\x0ab\x0ac\x0ad", got)
		if (i == 1): assert_strings_equal(c"c\x0ad", got)
		if (i == 2): assert_strings_equal(c"", got)
		free(got)
	unlink(path)
	free(path)
	free(cap)


void test_new_tool_rejections_and_read_errors():
	tr(c"head -n 9999999999999", 0)
	tr(c"sed 's/a/b///g'", 0)
	tr(c"sed 's/[[:alpha:]]/b/'", 0)
	tr(c"sed 's/a/b/\x0ap'", 0)
	assert_equal(1, shell_glob_match(c"*", c"*literal"))
	shtest_quiet_start()
	assert_equal(1, shell_commands_cat(c"/"))
	assert_equal(1, shell_commands_head(c"/", 1))
	assert_equal(1, shell_commands_tail(c"/", 1))
	assert_equal(1, shell_commands_wc(c"/", true, false, false))
	assert_equal(2, shell_commands_grep(false, c"x", c"/"))
	assert_equal(1, shell_commands_sed(false, c"p", c"/"))
	shtest_quiet_end()


void test_translate_bracket_globs_respect_quotes():
	tr(c"echo [ab]", 0)
	tr(c"cat file[0-9].txt", 0)
	tr(c"echo '[ab]'", c"shell_commands_echo(false, c\"[ab]\")")
	tr(c"echo \"[ab]\"", c"shell_commands_echo(false, c\"[ab]\")")
	tr(c"echo \\[ab]", c"shell_commands_echo(false, c\"[ab]\")")
	tr(c"sed 's/[ab]/X/g'", c"shell_commands_sed(false, c\"s/[ab]/X/g\")")
	assert_equal(0, shell_translate_has_meta(c"find . -name '[ab]'"))
