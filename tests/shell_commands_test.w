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
	assert1(shell_translate_line(c"echo hi") == 0)


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
