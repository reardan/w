# wbuild: target=wtest_defhash_test tag=tests dep=wtest
# wbuild: step="bin/wv2 tools/wtest_defhash_e2e.w -o bin/wtest_defhash_e2e"
# wbuild: step="bin/wtest_defhash_e2e" expect_stdout="wtest_defhash_scratch_test: OK"
/*
Self-contained fixture for bin/wtest's --defhash refinement (wave plan C
task 2g, tools/test_map.w), run by the `wtest_defhash_test` target. It
replaced tools/wtest_defhash_scratch_test.sh (issue #323: no shell
scripts); every child is spawned through lib/process.w with an argv
vector -- no /bin/sh. The FAIL messages and the final OK line keep the
old script's name so the target's expectations are unchanged.

The '-f manifest.json' fixtures elsewhere in tests/wtest/ cover rule
(a)/(c)/leaf-diff selection with synthetic "true"/"echo" steps and no
real git history, but --defhash's own machinery shells out to
'git show HEAD:<path>' and 'bin/wv2 defhash', which only mean something
against a real commit and a real compilable root -- hence a throwaway git
repository (a pid-scoped directory under bin/) instead of another -f
fixture, per the wave plan's "self-contained git init-in-a-scratch-dir"
note.

The scratch repo gets its own symlinked copies of bin/wv2, bin/wtest,
and the lib/ structures/ code_generator/ trees: link_impl unconditionally
auto-imports structures.hash_table and structures.w_list before compiling
any user file (compiler/compiler.w's cold-start auto-import block), and
those transitively reach into lib/ and code_generator/integer.w, so even
the two-function program below needs all three trees reachable at the
scratch repo's own relative paths -- exactly like this repo's own
build_relative_import_test (build.base.json) demonstrates a bare tmp dir
with none of them fails with "cannot locate 'structures/hash_table.w'".
*/
import lib.lib
import lib.process
import lib.path
import lib.file
import lib.container
import structures.string


char* sc_name = 0
char* sc_root = 0
char* sc_dir = 0


void sc_err(char* s):
	write(2, s, strlen(s))


void sc_cleanup():
	if (sc_dir == 0):
		return
	char** argv = strv_new(3)
	strv_set(argv, 0, c"/bin/rm")
	strv_set(argv, 1, c"-rf")
	strv_set(argv, 2, sc_dir)
	process_result* r = process_run(c"/bin/rm", argv, 0, 0, 60000)
	if (r != 0):
		process_result_free(r)
	free(cast(void*, argv))


void fail(char* msg):
	sc_err(sc_name)
	sc_err(c": FAIL: ")
	sc_err(msg)
	sc_err(c"\n")
	sc_cleanup()
	exit(1)


list[char*] av(char* a, char* b, char* c, char* d, char* e):
	list[char*] v = new list[char*]
	if (a != 0):
		v.push(a)
	if (b != 0):
		v.push(b)
	if (c != 0):
		v.push(c)
	if (d != 0):
		v.push(d)
	if (e != 0):
		v.push(e)
	return v


# Runs prog with argv0 plus args (cwd = the scratch repo), feeding
# stdin_text (0 for none). A spawn failure is a test failure.
process_result* sc_exec(char* prog, char* argv0, list[char*] args, char* stdin_text):
	char** argv = strv_new(args.length + 1)
	strv_set(argv, 0, argv0)
	int i = 1
	for char* a in args:
		strv_set(argv, i, a)
		i = i + 1
	spawn_options* opts = spawn_options_new()
	opts.cwd = sc_dir
	process_result* r = process_run(prog, argv, opts, stdin_text, 600000)
	free(opts)
	free(cast(void*, argv))
	list_free[char*](args)
	if (r == 0):
		string_builder* m = string_new()
		string_append(m, c"could not spawn ")
		string_append(m, prog)
		fail(m.data)
	return r


# 'git <args>' through /usr/bin/env (execve does no PATH lookup); must
# exit 0, as under the old script's 'set -e'. Returns stdout (owned).
char* git(list[char*] args):
	args.insert(0, c"git")
	process_result* r = sc_exec(c"/usr/bin/env", c"env", args, 0)
	if (r.status != 0):
		sc_err(r.stderr_text)
		fail(c"a git command failed")
	char* out = strclone(r.stdout_text)
	process_result_free(r)
	return out


char* sc_wtest_path():
	return path_join(sc_dir, c"bin/wtest")


# 'bin/wtest <args>' in the scratch repo; the caller owns the result.
process_result* wtest_run(list[char*] args, char* stdin_text):
	return sc_exec(sc_wtest_path(), c"bin/wtest", args, stdin_text)


# 'out=$(bin/wtest <args>)' under 'set -e': must exit 0, returns stdout.
char* wtest_out(list[char*] args, char* stdin_text):
	process_result* r = wtest_run(args, stdin_text)
	if (r.status != 0):
		sc_err(r.stderr_text)
		fail(c"bin/wtest exited nonzero")
	char* out = strclone(r.stdout_text)
	process_result_free(r)
	return out


# 'err=$(bin/wtest <args> 2>&1 >/dev/null)' under 'set -e'.
char* wtest_err(list[char*] args, char* stdin_text):
	process_result* r = wtest_run(args, stdin_text)
	if (r.status != 0):
		sc_err(r.stderr_text)
		fail(c"bin/wtest exited nonzero")
	char* err = strclone(r.stderr_text)
	process_result_free(r)
	return err


int sc_index_of(char* haystack, char* needle):
	int hl = strlen(haystack)
	int nl = strlen(needle)
	int i = 0
	while ((i + nl) <= hl):
		int j = 0
		while ((j < nl) && (haystack[i + j] == needle[j])):
			j = j + 1
		if (j == nl):
			return i
		i = i + 1
	return -1


# grep -qF
int contains(char* text, char* needle):
	return sc_index_of(text, needle) >= 0


# grep -qx: some whole line of text equals line.
int has_line(char* text, char* line):
	int nl = strlen(line)
	int i = 0
	while (text[i] != 0):
		int j = 0
		while ((j < nl) && (text[i + j] == line[j])):
			j = j + 1
		if ((j == nl) && ((text[i + j] == 0) || (text[i + j] == '\n'))):
			return 1
		while ((text[i] != 0) && (text[i] != '\n')):
			i = i + 1
		if (text[i] == '\n'):
			i = i + 1
	return 0


void sc_write(char* rel, char* text):
	char* path = path_join(sc_dir, rel)
	if (file_write_text(path, text) == 0):
		fail(c"could not write a scratch file")
	free(path)


void sc_append(char* rel, char* text):
	char* path = path_join(sc_dir, rel)
	char* old = file_read_text(path)
	if (old == 0):
		fail(c"could not read a scratch file")
	string_builder* s = string_new()
	string_append(s, old)
	string_append(s, text)
	if (file_write_text(path, s.data) == 0):
		fail(c"could not append to a scratch file")
	string_free(s)
	free(old)
	free(path)


void sc_link(char* repo_rel, char* scratch_rel):
	char* target = path_join(sc_root, repo_rel)
	char* link = path_join(sc_dir, scratch_rel)
	if (symlink(target, link) < 0):
		fail(c"could not create a scratch symlink")
	free(target)
	free(link)


void sc_setup():
	char* buf = malloc(4096)
	if (getcwd(buf, 4096) <= 0):
		fail(c"getcwd failed")
	sc_root = buf
	char* wv2 = path_join(sc_root, c"bin/wv2")
	char* wtest = path_join(sc_root, c"bin/wtest")
	if ((path_exists(wv2) == 0) || (path_exists(wtest) == 0)):
		sc_err(c"wtest_defhash_scratch_test: bin/wv2 and bin/wtest must be built first\n")
		exit(1)
	free(wv2)
	free(wtest)
	string_builder* d = string_new()
	string_append(d, sc_root)
	string_append(d, c"/bin/wtest_defhash_e2e_")
	string_append_int(d, getpid())
	sc_dir = d.data
	free(d)
	sc_cleanup()
	if (mkdir(sc_dir, 493) < 0):
		sc_dir = 0
		fail(c"could not create the scratch directory")
	char* scratch_bin = path_join(sc_dir, c"bin")
	mkdir(scratch_bin, 493)
	free(scratch_bin)
	sc_link(c"bin/wv2", c"bin/wv2")
	sc_link(c"bin/wtest", c"bin/wtest")
	sc_link(c"lib", c"lib")
	sc_link(c"structures", c"structures")
	sc_link(c"code_generator", c"code_generator")


int main():
	sc_name = c"wtest_defhash_scratch_test"
	sc_setup()
	sc_write(c"build.json", c"{\n\t\"targets\": [\n\t\t{\n\t\t\t\"name\": \"scratch_target\",\n\t\t\t\"steps\": [\n\t\t\t\t{\"cmd\": [\"bin/wv2\", \"scratch_root.w\", \"-o\", \"bin/scratch_out\"]}\n\t\t\t]\n\t\t}\n\t]\n}\n")
	sc_write(c"scratch_root.w", c"import scratch_lib\n\nint main():\n\treturn scratch_lib_add(1, 2)\n")
	sc_write(c"scratch_lib.w", c"int scratch_lib_add(int a, int b):\n\treturn a + b\n")

	git(av(c"init", c"-q", 0, 0, 0))
	git(av(c"config", c"user.email", c"test@example.com", 0, 0))
	git(av(c"config", c"user.name", c"test", 0, 0))
	git(av(c"add", c"-A", 0, 0, 0))
	git(av(c"commit", c"-q", c"-m", c"initial commit", 0))

	# Sanity baseline: an unmodified file selects scratch_target under
	# plain rule (b) closure selection -- this just proves the fixture
	# itself (the manifest's compile step, the import from
	# scratch_root.w) is wired up before trusting any skip/fallback
	# assertion below. (An unmodified file is not a meaningful --defhash
	# case on its own: HEAD and the worktree are byte-identical, so
	# "unchanged" is the only correct answer, same as every other case
	# below where the two are actually identical -- comment-only edits
	# included.)
	char* out = wtest_out(av(c"changed", c"scratch_lib.w", 0, 0, 0), 0)
	if (has_line(out, c"scratch_target") == 0):
		fail(c"baseline (no --defhash) did not select scratch_target")

	# Comment/formatting-only edit: --defhash must SKIP the
	# import-closure target (defhash's own token-stream hash excludes
	# comments/whitespace); without the flag, rule (b) keeps selecting
	# it unconditionally -- the "default selection is byte-identical
	# without the flag" property.
	sc_append(c"scratch_lib.w", c"\n# a trailing comment, no behavior change\n")
	out = wtest_out(av(c"changed", c"scratch_lib.w", 0, 0, 0), 0)
	if (has_line(out, c"scratch_target") == 0):
		fail(c"comment-only edit: plain selection dropped scratch_target")
	out = wtest_out(av(c"changed", c"--defhash", c"scratch_lib.w", 0, 0), 0)
	if (has_line(out, c"scratch_target")):
		fail(c"comment-only edit: --defhash still selected scratch_target")

	# Real edit: --defhash must fall back to full closure selection (the
	# definition's own recorded hash actually changed).
	git(av(c"checkout", c"-q", c"--", c"scratch_lib.w", 0))
	sc_write(c"scratch_lib.w", c"int scratch_lib_add(int a, int b):\n\treturn a + b + 1\n")
	out = wtest_out(av(c"changed", c"--defhash", c"scratch_lib.w", 0, 0), 0)
	if (has_line(out, c"scratch_target") == 0):
		fail(c"real edit: --defhash did not select scratch_target")

	# Explicit-generics syntax ('T max[T](T a, T b):', docs/projects/
	# generics.md): wave plan C task 4f threaded defhash bookkeeping
	# through the generic scan-ahead machinery (grammar/generic.w), so a
	# generic definition's own span is now recorded (kind
	# 'generic_function') and hashed like any other definition -- a
	# comment-only edit correctly SKIPs, same as an ordinary function,
	# instead of always falling back.
	git(av(c"checkout", c"-q", c"--", c"scratch_lib.w", 0))
	sc_write(c"scratch_lib.w", c"int scratch_lib_add(int a, int b):\n\treturn a + b\n\n\nT scratch_lib_first[T](T a, T b):\n\treturn a\n")
	git(av(c"add", c"scratch_lib.w", 0, 0, 0))
	git(av(c"commit", c"-q", c"-m", c"add an explicit-generics definition", 0))
	sc_append(c"scratch_lib.w", c"\n# comment only, generics still present\n")
	out = wtest_out(av(c"changed", c"--defhash", c"scratch_lib.w", 0, 0), 0)
	if (has_line(out, c"scratch_target")):
		fail(c"generic definition: comment-only edit still selected scratch_target")

	# A REAL edit to the generic definition's body must still select the
	# target -- coverage means the change is now visible to 'bin/wv2
	# defhash', not that generics are exempt from selection.
	git(av(c"checkout", c"-q", c"--", c"scratch_lib.w", 0))
	sc_write(c"scratch_lib.w", c"int scratch_lib_add(int a, int b):\n\treturn a + b\n\n\nT scratch_lib_first[T](T a, T b):\n\treturn b\n")
	out = wtest_out(av(c"changed", c"--defhash", c"scratch_lib.w", 0, 0), 0)
	if (has_line(out, c"scratch_target") == 0):
		fail(c"generic definition: real body edit did not select scratch_target")

	# 'operator' overload syntax (docs/projects/operator_overloading.md):
	# same story via grammar/operator_overload.w -- a real operator
	# definition is now recorded (kind 'operator', a synthetic
	# 'operator<spelling>(<types>)' name), so a comment-only edit
	# SKIPs...
	char* point_prefix = c"int scratch_lib_add(int a, int b):\n\treturn a + b\n\nstruct scratch_lib_point:\n\tint x\n\tint y\n\nscratch_lib_point operator+(scratch_lib_point a, scratch_lib_point b):\n"
	git(av(c"checkout", c"-q", c"--", c"scratch_lib.w", 0))
	string_builder* src = string_new()
	string_append(src, point_prefix)
	string_append(src, c"\treturn scratch_lib_point(a.x + b.x, a.y + b.y)\n")
	sc_write(c"scratch_lib.w", src.data)
	git(av(c"add", c"scratch_lib.w", 0, 0, 0))
	git(av(c"commit", c"-q", c"-m", c"add an operator overload", 0))
	sc_append(c"scratch_lib.w", c"\n# comment only, operator overload still present\n")
	out = wtest_out(av(c"changed", c"--defhash", c"scratch_lib.w", 0, 0), 0)
	if (has_line(out, c"scratch_target")):
		fail(c"operator overload: comment-only edit still selected scratch_target")

	# ...while a REAL edit to the operator's body still selects the
	# target.
	git(av(c"checkout", c"-q", c"--", c"scratch_lib.w", 0))
	string_clear(src)
	string_append(src, point_prefix)
	string_append(src, c"\treturn scratch_lib_point(b.x + a.x, b.y + a.y)\n")
	sc_write(c"scratch_lib.w", src.data)
	out = wtest_out(av(c"changed", c"--defhash", c"scratch_lib.w", 0, 0), 0)
	if (has_line(out, c"scratch_target") == 0):
		fail(c"operator overload: real body edit did not select scratch_target")

	# The coverage payoff (wave plan C task 4f): a file defining BOTH a
	# generic AND an operator overload alongside an ordinary function,
	# only comment-edited, now SKIPs -- before this task, the mere
	# presence of either shape (tools/test_map.w's
	# wtest_defhash_risky_text, now removed) forced a fallback on every
	# such file regardless of what actually changed.
	git(av(c"checkout", c"-q", c"--", c"scratch_lib.w", 0))
	string_clear(src)
	string_append(src, point_prefix)
	string_append(src, c"\treturn scratch_lib_point(a.x + b.x, a.y + b.y)\n\nT scratch_lib_first[T](T a, T b):\n\treturn a\n")
	sc_write(c"scratch_lib.w", src.data)
	string_free(src)
	git(av(c"add", c"scratch_lib.w", 0, 0, 0))
	git(av(c"commit", c"-q", c"-m", c"add a generic definition and an operator overload", 0))
	sc_append(c"scratch_lib.w", c"\n# comment only, generic + operator overload still present\n")
	out = wtest_out(av(c"changed", c"--defhash", c"scratch_lib.w", 0, 0), 0)
	if (has_line(out, c"scratch_target")):
		fail(c"generic+operator coverage: comment-only edit still selected scratch_target")

	# Committed-clean footgun warning (tools/test_map.w header comment,
	# --defhash): piping a ranged diff's path list into the un-ranged
	# form after committing ('git diff --name-only A..B | wtest changed
	# --defhash') compares HEAD vs a byte-identical worktree and silently
	# skips every path's closure selection -- wtest now warns on stderr,
	# suggesting the ranged form, without touching the stdout selection.
	git(av(c"checkout", c"-q", c"--", c"scratch_lib.w", 0))
	char* piped_paths = git(av(c"diff", c"--name-only", c"HEAD~1..HEAD", 0, 0))
	char* err = wtest_err(av(c"changed", c"--defhash", 0, 0, 0), piped_paths)
	if (contains(err, c"committed-clean vs HEAD") == 0):
		fail(c"footgun combo (piped committed-clean path): warning did not fire")
	if (contains(err, c"wtest changed A..B --defhash") == 0):
		fail(c"footgun combo: warning did not suggest the ranged form")

	# The stdout selection itself must stay byte-identical: only stderr
	# gains the warning.
	char* piped_out = wtest_out(av(c"changed", c"--defhash", 0, 0, 0), piped_paths)
	char* positional_out = wtest_out(av(c"changed", c"--defhash", c"scratch_lib.w", 0, 0), 0)
	if (strcmp(piped_out, positional_out) != 0):
		fail(c"footgun combo: warning changed the stdout selection")

	# The ranged form is the correct spelling and must NOT warn (it
	# compares the range's own endpoints, not HEAD vs the worktree).
	err = wtest_err(av(c"changed", c"HEAD~1..HEAD", c"--defhash", 0, 0), 0)
	if (contains(err, c"committed-clean")):
		fail(c"ranged form: warning fired")

	# A genuinely dirty worktree path piped in (the documented
	# 'git diff --name-only HEAD | wtest changed --defhash' workflow)
	# must NOT warn either: the path differs from HEAD, so the
	# comparison is meaningful.
	sc_append(c"scratch_lib.w", c"\n# dirty worktree, comment only\n")
	piped_paths = git(av(c"diff", c"--name-only", c"HEAD", 0, 0))
	err = wtest_err(av(c"changed", c"--defhash", 0, 0, 0), piped_paths)
	if (contains(err, c"committed-clean")):
		fail(c"dirty worktree: warning fired")

	# A committed-clean path named POSITIONALLY was asked about
	# deliberately (this program's own earlier cases do exactly that),
	# so it must not warn: the warning is scoped to stdin-piped lists.
	git(av(c"checkout", c"-q", c"--", c"scratch_lib.w", 0))
	err = wtest_err(av(c"changed", c"--defhash", c"scratch_lib.w", 0, 0), 0)
	if (contains(err, c"committed-clean")):
		fail(c"positional committed-clean path: warning fired")

	sc_cleanup()
	char* ok = c"wtest_defhash_scratch_test: OK\n"
	write(1, ok, strlen(ok))
	return 0
