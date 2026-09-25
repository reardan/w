/*
End-to-end check for missing_file_test's out-of-tree half: a compile
and a `check` run from a working directory OUTSIDE the checkout must
still find the auto-imported runtime (structures/hash_table.w, ...)
through the compiler binary's own directory (compiler/compiler.w,
compile_relative_path's argv[0] fallback), with no "cannot locate",
"went up one directory" or "not found error" noise on stderr.

It replaced two inline `sh -c` steps (issue #323: no shell): each child
is spawned through lib/process.w with an argv vector and a cwd. Unlike
most e2e drivers, the scratch directory must not live under bin/: from
there the upward cwd walk reaches the repo root and the argv[0]
fallback under test never runs. It is pid-scoped under $TMPDIR (or
/tmp) instead, and removed afterwards.

Prints "missing_file cwd e2e OK" on success; each failure prints a
FAIL: line and the exit status is 1. Run by missing_file_test (its
directives are at the end of this file).
*/
import lib.lib
import lib.env
import lib.process
import lib.path
import lib.file
import lib.str
import lib.shell_commands
import structures.string


char* WV2
char* DIR
int FAILED = 0


void out(char* s):
	write(1, s, strlen(s))


void fail(char* desc, char* what):
	out(c"FAIL: ")
	out(desc)
	out(c": ")
	out(what)
	out(c"\n")
	FAILED = 1


void reject(char* desc, char* text, char* needle):
	if (index_of(text, needle) >= 0): fail(desc, strjoin(c"stderr contains ", needle))


# Runs argv (argc words, argv[0] an absolute path) with cwd DIR; asserts
# exit 0 and none of the old step's reject_stderr strings.
void run_clean(char* desc, char** argv):
	spawn_options* opts = spawn_options_new()
	opts.cwd = DIR
	process_result* r = process_run(strv_get(argv, 0), argv, opts, 0, 300000)
	free(opts)
	if (r == 0):
		fail(desc, c"could not spawn")
		return
	if (r.status != 0):
		out(r.stderr_text)
		fail(desc, c"non-zero exit status")
	reject(desc, r.stderr_text, c"cannot locate")
	reject(desc, r.stderr_text, c"went up one directory")
	reject(desc, r.stderr_text, c"not found error")
	process_result_free(r)


int main():
	char* root = malloc(4096)
	if (getcwd(root, 4096) <= 0):
		out(c"FAIL: getcwd failed\n")
		return 1
	WV2 = path_join(root, c"bin/wv2")
	char* tmp = env_get(c"TMPDIR")
	if ((tmp == 0) || (tmp[0] == 0)): tmp = c"/tmp"
	string_builder* d = string_new()
	string_append(d, tmp)
	string_append(d, c"/w_missing_file_e2e_")
	string_append_int(d, getpid())
	DIR = d.data
	if (index_of(DIR, root) == 0):
		out(c"FAIL: scratch directory is inside the checkout; set TMPDIR elsewhere\n")
		return 1
	shell_commands_rm_one(DIR, 1, 1)
	if (shell_commands_mkdir_one(DIR, 1) != 0):
		out(c"FAIL: cannot create the scratch directory\n")
		return 1
	if (file_write_text(path_join(DIR, c"prog.w"), c"int main():\n\treturn 0\n") == 0):
		out(c"FAIL: cannot write prog.w\n")
		return 1

	char** argv = strv_new(4)
	strv_set(argv, 0, WV2)
	strv_set(argv, 1, c"prog.w")
	strv_set(argv, 2, c"-o")
	strv_set(argv, 3, c"prog_out")
	run_clean(c"compile from outside the checkout", argv)

	argv = strv_new(1)
	strv_set(argv, 0, path_join(DIR, c"prog_out"))
	run_clean(c"run the out-of-tree binary", argv)

	argv = strv_new(4)
	strv_set(argv, 0, WV2)
	strv_set(argv, 1, c"check")
	strv_set(argv, 2, c"--quiet")
	strv_set(argv, 3, c"prog.w")
	run_clean(c"check from outside the checkout", argv)

	shell_commands_rm_one(DIR, 1, 1)
	if (FAILED != 0): return 1
	out(c"missing_file cwd e2e OK\n")
	return 0
# wbuild: target=missing_file_test tag=tests dep=wv2 dep=wfixture
# wbuild: step="bin/wv2 tests/no_such_file_typo.w -o /dev/null" expect_fail expect_stderr="no such file: 'tests/no_such_file_typo.w'" reject_stderr="went up one directory" reject_stderr="not found error"
# wbuild: step="bin/wv2 check --json tests/no_such_file_typo.w" expect_fail expect_stdout="\"file\": \"tests/no_such_file_typo.w\"" expect_stdout="\"severity\": \"error\"" expect_stdout="\"message\": \"no such file: 'tests/no_such_file_typo.w'\""
# wbuild: step="bin/wfixture bin/wv2 tests/missing_import_fixture.w"
# wbuild: step="bin/wv2 tools/missing_file_cwd_e2e.w -o bin/missing_file_cwd_e2e"
# wbuild: step="bin/missing_file_cwd_e2e" expect_stdout="missing_file cwd e2e OK"
