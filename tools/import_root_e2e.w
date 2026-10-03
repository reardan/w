/*
End-to-end check for explicit ordered import roots ('--import-root <dir>',
compiler/compiler.w; docs/projects/compilation_model.md "Import roots"),
driven over the tests/import_roots/ fixture tree:

  a/ir_mod.w, b/ir_mod.w                 one module name in both roots
  b/ir_only_b.w                          a module only the second root has
  a/ir_pkg/__arch__/{x86,x64}/ir_arch.w  per-target resolution in a root
  b/ir_warn.w                            a module with one warning
  main.w, warn_main.w, missing_main.w    the programs compiled here

It asserts that root order decides which duplicate wins (and swapping
the order flips it); that compile, check, deps and symbols agree on the
resolved files, including under the x64 selector in both spellings;
that 'deps --json' reports the shadowed duplicate; that relative roots
resolve against the invocation's working directory (runs from bin/ and
from outside the checkout with absolute roots); that diagnostics name
the resolved file inside the root; and the error paths (a root that is
no directory, a missing value, an import found nowhere). Every child is
spawned through lib/process.w with an argv vector and a cwd (no shell,
issue #323).

Prints "import_root e2e OK" on success; each failure prints a FAIL:
line and the exit status is 1. Run by import_root_cli_test (directives
at the end of this file); the plain compile+run coverage, with wexec's
cache keys and wtest's closures over the roots, is
tests/import_root_test.w and tests/import_root_order_test.w.
*/
import lib.lib
import lib.env
import lib.process
import lib.path
import lib.str
import structures.string


char* REPO
char* WV2
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


# Runs bin/wv2 with the space-separated words of line (a word starting
# with '@' gets the checkout's absolute path in place of the '@', so
# the root path itself may contain spaces) from cwd.
process_result* wv2(char* cwd, char* line):
	list[char*] words = new list[char*]
	words.push(WV2)
	string_builder* word = string_new()
	int i = 0
	while (1):
		if ((line[i] == ' ') || (line[i] == 0)):
			if (word.length > 0):
				char* text = strclone(word.data)
				if (text[0] == '@'): text = strjoin(REPO, text + 1)
				words.push(text)
				string_clear(word)
			if (line[i] == 0): break
		else: string_append_char(word, line[i])
		i = i + 1
	string_free(word)
	char** argv = strv_new(words.length)
	int k = 0
	while (k < words.length):
		strv_set(argv, k, words[k])
		k = k + 1
	spawn_options* opts = spawn_options_new()
	opts.cwd = cwd
	process_result* r = process_run(WV2, argv, opts, 0, 300000)
	free(opts)
	return r


void expect_status(char* desc, process_result* r, int status):
	if (r.status != status):
		out(r.stderr_text)
		fail(desc, strjoin(c"unexpected exit status ", itoa(r.status)))


void expect_in(char* desc, char* stream, char* text, char* needle):
	if (index_of(text, needle) < 0):
		out(text)
		fail(desc, strjoin(strjoin(stream, c" lacks "), needle))


void expect_not_in(char* desc, char* stream, char* text, char* needle):
	if (index_of(text, needle) >= 0):
		fail(desc, strjoin(strjoin(stream, c" contains "), needle))


# Compile line from cwd to the absolute output binary, run it, and
# expect its stdout to contain want.
void compile_run(char* desc, char* cwd, char* line, char* binary, char* want):
	process_result* r = wv2(cwd, strjoin(strjoin(line, c" -o "), binary))
	expect_status(desc, r, 0)
	if (r.status != 0): return
	char** argv = strv_new(1)
	strv_set(argv, 0, binary)
	process_result* ran = process_run(binary, argv, 0, 0, 60000)
	if (ran == 0):
		fail(desc, c"could not run the binary")
		return
	expect_status(desc, ran, 0)
	expect_in(desc, c"stdout", ran.stdout_text, want)


int main():
	REPO = malloc(4096)
	if (getcwd(REPO, 4096) <= 0):
		out(c"FAIL: getcwd failed\n")
		return 1
	WV2 = path_join(REPO, c"bin/wv2")
	char* BIN = path_join(REPO, c"bin")
	char* A = c"tests/import_roots/a"
	char* AB = c"--import-root tests/import_roots/a --import-root tests/import_roots/b "
	char* BA = c"--import-root tests/import_roots/b --import-root=tests/import_roots/a "
	char* MAIN = c"tests/import_roots/main.w"

	# Root order decides the duplicate; the module only in b/ and the
	# per-arch module only in a/ resolve either way.
	compile_run(c"compile a,b", REPO, strjoin(AB, MAIN), path_join(BIN, c"import_root_e2e_ab"), c"which=a only_b=42 word=4")
	compile_run(c"compile b,a", REPO, strjoin(BA, MAIN), path_join(BIN, c"import_root_e2e_ba"), c"which=b only_b=42 word=4")

	# Relative roots resolve against the invocation's working directory:
	# the same program from bin/, and from outside the checkout with
	# absolute roots (the auto-imported runtime then resolves through
	# the compiler binary's own directory, as without roots).
	compile_run(c"compile from bin/", BIN, c"--import-root ../tests/import_roots/b --import-root ../tests/./import_roots/a/ ../tests/import_roots/main.w", path_join(BIN, c"import_root_e2e_bin"), c"which=b only_b=42 word=4")
	char* tmp = env_get(c"TMPDIR")
	if ((tmp == 0) || (tmp[0] == 0)): tmp = c"/tmp"
	compile_run(c"compile from outside the checkout", tmp, c"--import-root @/tests/import_roots/a --import-root @/tests/import_roots/b @/tests/import_roots/main.w", path_join(BIN, c"import_root_e2e_tmp"), c"which=a only_b=42 word=4")

	# Without roots nothing changes: the imports are simply not found,
	# with the unchanged default diagnostic.
	process_result* r = wv2(REPO, c"check --quiet tests/import_roots/main.w")
	expect_status(c"no roots", r, 1)
	expect_in(c"no roots", c"stderr", r.stderr_text, c"cannot locate 'ir_mod.w' (searched the current directory and every parent)")

	# check agrees with compile; roots may precede the other leading flags
	r = wv2(REPO, strjoin(strjoin(c"check ", AB), c"--json --quiet tests/import_roots/main.w"))
	expect_status(c"check a,b", r, 0)
	if (r.stdout_text[0] != 0): fail(c"check a,b", c"stdout is not empty")

	# deps: the resolved files, repo-relative under the working directory
	r = wv2(REPO, strjoin(strjoin(c"deps ", AB), MAIN))
	expect_status(c"deps a,b", r, 0)
	expect_in(c"deps a,b", c"stdout", r.stdout_text, c"\ntests/import_roots/a/ir_mod.w\n")
	expect_in(c"deps a,b", c"stdout", r.stdout_text, c"\ntests/import_roots/b/ir_only_b.w\n")
	expect_in(c"deps a,b", c"stdout", r.stdout_text, c"\ntests/import_roots/a/ir_pkg/__arch__/x86/ir_arch.w\n")
	expect_not_in(c"deps a,b", c"stdout", r.stdout_text, c"tests/import_roots/b/ir_mod.w")
	expect_not_in(c"deps a,b", c"stdout", r.stdout_text, c"shadows")
	r = wv2(REPO, strjoin(strjoin(c"deps ", BA), MAIN))
	expect_status(c"deps b,a", r, 0)
	expect_in(c"deps b,a", c"stdout", r.stdout_text, c"\ntests/import_roots/b/ir_mod.w\n")
	expect_not_in(c"deps b,a", c"stdout", r.stdout_text, c"tests/import_roots/a/ir_mod.w")

	# deps --json reports the duplicate the first root shadowed
	r = wv2(REPO, strjoin(strjoin(c"deps --json ", AB), MAIN))
	expect_status(c"deps --json a,b", r, 0)
	expect_in(c"deps --json a,b", c"stdout", r.stdout_text, c"{\"file\": \"tests/import_roots/a/ir_mod.w\", \"shadows\": [\"tests/import_roots/b/ir_mod.w\"]}")
	expect_in(c"deps --json a,b", c"stdout", r.stdout_text, c"{\"file\": \"tests/import_roots/b/ir_only_b.w\"}")
	r = wv2(REPO, c"deps --json lib/assert.w")
	expect_status(c"deps --json without roots", r, 0)
	expect_not_in(c"deps --json without roots", c"stdout", r.stdout_text, c"shadows")

	# Outside the working directory the resolved path prints absolute
	r = wv2(BIN, c"deps --import-root ../tests/import_roots/b --import-root ../tests/import_roots/a ../tests/import_roots/main.w")
	expect_status(c"deps from bin/", r, 0)
	expect_in(c"deps from bin/", c"stdout", r.stdout_text, strjoin(REPO, c"/tests/import_roots/b/ir_mod.w\n"))

	# __arch__ inside a root follows the selector, in both spellings
	r = wv2(REPO, strjoin(strjoin(c"x64 deps ", AB), MAIN))
	expect_status(c"x64 deps", r, 0)
	expect_in(c"x64 deps", c"stdout", r.stdout_text, c"\ntests/import_roots/a/ir_pkg/__arch__/x64/ir_arch.w\n")
	r = wv2(REPO, strjoin(strjoin(c"deps x64 ", AB), MAIN))
	expect_status(c"deps x64", r, 0)
	expect_in(c"deps x64", c"stdout", r.stdout_text, c"\ntests/import_roots/a/ir_pkg/__arch__/x64/ir_arch.w\n")

	# symbols names the resolved declaration file
	r = wv2(REPO, strjoin(strjoin(c"symbols --json ", AB), MAIN))
	expect_status(c"symbols a,b", r, 0)
	expect_in(c"symbols a,b", c"stdout", r.stdout_text, c"tests/import_roots/a/ir_mod.w\", \"line\": 4")
	r = wv2(REPO, strjoin(strjoin(c"symbols --json ", BA), MAIN))
	expect_status(c"symbols b,a", r, 0)
	expect_in(c"symbols b,a", c"stdout", r.stdout_text, c"tests/import_roots/b/ir_mod.w\", \"line\": 4")
	r = wv2(REPO, strjoin(strjoin(c"x64 symbols --json ", AB), MAIN))
	expect_in(c"x64 symbols", c"stdout", r.stdout_text, c"tests/import_roots/a/ir_pkg/__arch__/x64/ir_arch.w\"")

	# A diagnostic in a module from a root names that file
	r = wv2(REPO, c"check --json --quiet --import-root tests/import_roots/b tests/import_roots/warn_main.w")
	expect_status(c"warning in a root", r, 0)
	expect_in(c"warning in a root", c"stdout", r.stdout_text, c"tests/import_roots/b/ir_warn.w\", \"line\": 5")
	expect_in(c"warning in a root", c"stdout", r.stdout_text, c"bit 31")

	# An import found nowhere names the roots among the places searched
	r = wv2(REPO, strjoin(c"check --quiet --import-root ", strjoin(A, c" tests/import_roots/missing_main.w")))
	expect_status(c"missing module", r, 1)
	expect_in(c"missing module", c"stderr", r.stderr_text, c"cannot locate 'ir_absent.w' (searched the import roots, the current directory and every parent)")

	# Bad roots fail before anything compiles
	r = wv2(REPO, c"check --json --import-root tests/import_roots/nope tests/import_roots/main.w")
	expect_status(c"unknown root (json)", r, 1)
	expect_in(c"unknown root (json)", c"stdout", r.stdout_text, c"\"file\": \"<command-line>\"")
	expect_in(c"unknown root (json)", c"stdout", r.stdout_text, c"import root is not a directory: 'tests/import_roots/nope'")
	r = wv2(REPO, strjoin(c"--import-root tests/import_roots/a/ir_mod.w ", strjoin(MAIN, c" -o /dev/null")))
	expect_status(c"file as root", r, 1)
	expect_in(c"file as root", c"stderr", r.stderr_text, c"error: import root is not a directory: 'tests/import_roots/a/ir_mod.w'")
	r = wv2(REPO, strjoin(strjoin(c"deps ", MAIN), c" --import-root"))
	expect_status(c"missing value", r, 1)
	expect_in(c"missing value", c"stderr", r.stderr_text, c"error: missing directory after '--import-root'")

	if (FAILED != 0): return 1
	out(c"import_root e2e OK\n")
	return 0
# wbuild: target=import_root_cli_test tag=tests dep=wv2 data=tests/import_roots/ data=tools/import_root_e2e.w
# wbuild: step="bin/wv2 tools/import_root_e2e.w -o bin/import_root_e2e"
# wbuild: step="bin/import_root_e2e" expect_stdout="import_root e2e OK"
