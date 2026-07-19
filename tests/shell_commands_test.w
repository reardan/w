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
	ls(dir, false)
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
	ls(dir, true)
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
	ls(missing, false)
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
# repl/shell_translate.w: the argv/flag -> W call translator, pure logic.

void test_translate_pwd():
	assert_strings_equal(c"shell_commands.pwd()", shell_translate_line(c"pwd"))


void test_translate_pwd_rejects_extra_word():
	assert1(shell_translate_line(c"pwd extra") == 0)


void test_translate_ls_bare_defaults_to_dot_and_all_false():
	assert_strings_equal(c"shell_commands.ls(c\".\", false)", shell_translate_line(c"ls"))


void test_translate_ls_short_all_flag():
	assert_strings_equal(c"shell_commands.ls(c\".\", true)", shell_translate_line(c"ls -a"))


void test_translate_ls_long_all_flag():
	assert_strings_equal(c"shell_commands.ls(c\".\", true)", shell_translate_line(c"ls --all"))


void test_translate_ls_with_explicit_path():
	assert_strings_equal(c"shell_commands.ls(c\"/tmp\", false)", shell_translate_line(c"ls /tmp"))


void test_translate_ls_rejects_l_flag():
	# No portable stat/mode/size/mtime wrapper exists yet (design doc
	# Sec 6.2), so "-l" -- alone or clustered into "-la" -- is not in
	# ls's v1 flag table and must fall back to native, not a partial
	# translation that silently drops it.
	assert1(shell_translate_line(c"ls -l") == 0)
	assert1(shell_translate_line(c"ls -la") == 0)


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
	# grep is deliberately never native (design doc Sec 6.3: no reusable
	# pattern-matching core exists), so it stays a stable example of an
	# always-unrecognized command -- unlike "echo", which stage 2 below
	# promotes to a native tool.
	assert1(shell_translate_line(c"grep hi") == 0)


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


void test_translate_head_default_count():
	assert_strings_equal(c"shell_commands.head(c\"a.txt\", 10)", shell_translate_line(c"head a.txt"))


void test_translate_head_n_flag_space_separated():
	assert_strings_equal(c"shell_commands.head(c\"a.txt\", 5)", shell_translate_line(c"head -n 5 a.txt"))


void test_translate_head_n_flag_inline_equals():
	assert_strings_equal(c"shell_commands.head(c\"a.txt\", 5)", shell_translate_line(c"head -n=5 a.txt"))


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
