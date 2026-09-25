# wbuild: target=wtest_range_test tag=tests dep=wtest
# wbuild: step="bin/wv2 tools/wtest_range_e2e.w -o bin/wtest_range_e2e"
# wbuild: step="bin/wtest_range_e2e" expect_stdout="wtest_range_scratch_test: OK"
/*
Self-contained fixture for bin/wtest's commit-ranged selection (wave
plan C task 4b, tools/test_map.w, issue #251 direction 4b: 'wtest
changed A..B'), run by the `wtest_range_test` target. It replaced
tools/wtest_range_scratch_test.sh (issue #323: no shell scripts); every
child is spawned through lib/process.w with an argv vector -- no /bin/sh.
The FAIL messages and the final OK line keep the old script's name so the
target's expectations are unchanged.

Mirrors tools/wtest_defhash_e2e.w's throwaway-git-repo pattern (a
pid-scoped directory under bin/) for the same reason: this feature's own
machinery shells out to real git plumbing (git diff, git show, git
merge-base, git rev-parse, git cat-file) that only means something
against real commits and a real compilable root, not another
tests/wtest/ '-f manifest.json' fixture.

The scratch repo gets its own symlinked copies of bin/wv2, bin/wtest,
and the lib/ structures/ code_generator/ trees for the same reason
tools/wtest_defhash_e2e.w does: compiling even a two-function program
needs all three reachable at the scratch repo's own relative paths
(compiler/compiler.w's cold-start auto-import of
structures.hash_table / structures.w_list).
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
		sc_err(c"wtest_range_scratch_test: bin/wv2 and bin/wtest must be built first\n")
		exit(1)
	free(wv2)
	free(wtest)
	string_builder* d = string_new()
	string_append(d, sc_root)
	string_append(d, c"/bin/wtest_range_e2e_")
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


# 'git rev-parse HEAD' without its trailing newline.
char* head_rev():
	char* rev = git(av(c"rev-parse", c"HEAD", 0, 0, 0))
	int n = strlen(rev)
	while ((n > 0) && ((rev[n - 1] == '\n') || (rev[n - 1] == '\r'))):
		rev[n - 1] = 0
		n = n - 1
	return rev


char* cat3(char* a, char* b, char* c):
	string_builder* s = string_new()
	string_append(s, a)
	string_append(s, b)
	string_append(s, c)
	char* r = s.data
	free(s)
	return r


int main():
	sc_name = c"wtest_range_scratch_test"
	sc_setup()
	sc_write(c"build.json", c"{\n\t\"targets\": [\n\t\t{\n\t\t\t\"name\": \"scratch_target\",\n\t\t\t\"steps\": [\n\t\t\t\t{\"cmd\": [\"bin/wv2\", \"scratch_root.w\", \"-o\", \"bin/scratch_out\"]}\n\t\t\t]\n\t\t}\n\t]\n}\n")
	sc_write(c"scratch_root.w", c"import scratch_lib\n\nint main():\n\treturn scratch_lib_add(1, 2)\n")
	sc_write(c"scratch_lib.w", c"int scratch_lib_add(int a, int b):\n\treturn a + b\n")
	# A second .w file present from the first commit, deleted partway
	# through the history below -- exercises "a file deleted across the
	# range" (task item 2) without ever touching scratch_lib.w, whose own
	# closure-membership assertions must stay independent of it.
	sc_write(c"bystander.w", c"int bystander_unused():\n\treturn 0\n")

	git(av(c"init", c"-q", 0, 0, 0))
	git(av(c"config", c"user.email", c"test@example.com", 0, 0))
	git(av(c"config", c"user.name", c"test", 0, 0))
	git(av(c"add", c"-A", 0, 0, 0))
	git(av(c"commit", c"-q", c"-m", c"c0: initial commit", 0))
	char* c0 = head_rev()

	# --- c1: comment-only edit to scratch_lib.w ------------------------
	sc_append(c"scratch_lib.w", c"\n# a trailing comment, no behavior change\n")
	git(av(c"commit", c"-qam", c"c1: comment-only edit", 0, 0))
	char* c1 = head_rev()

	# --- c2: a real definition change to scratch_lib.w -----------------
	sc_write(c"scratch_lib.w", c"int scratch_lib_add(int a, int b):\n\treturn a + b + 1\n\n\n# a trailing comment, no behavior change\n")
	git(av(c"commit", c"-qam", c"c2: real edit", 0, 0))
	char* c2 = head_rev()

	# --- c3: delete bystander.w (present since c0, untouched until now) -
	git(av(c"rm", c"-q", c"bystander.w", 0, 0))
	git(av(c"commit", c"-qam", c"c3: delete bystander.w", 0, 0))
	char* c3 = head_rev()

	# ===== Two-dot range c0..c1 (comment-only): plain selection still
	# picks up scratch_target (rule (b), unrefined); --defhash skips it
	# (its recorded definitions are provably identical at both ends of
	# the range) -- the same "plain selects, --defhash skips" contrast
	# tools/wtest_defhash_e2e.w proves for HEAD-vs-worktree, now proven
	# rev-vs-rev via an explicit closed range.
	char* r01 = cat3(c0, c"..", c1)
	char* out = wtest_out(av(c"changed", r01, 0, 0, 0), 0)
	if (has_line(out, c"scratch_target") == 0):
		fail(c"c0..c1 (comment-only): plain selection dropped scratch_target")
	out = wtest_out(av(c"changed", c"--defhash", r01, 0, 0), 0)
	if (has_line(out, c"scratch_target")):
		fail(c"c0..c1 (comment-only): --defhash still selected scratch_target")

	# ===== Two-dot range c1..c2 (real edit): --defhash must NOT skip ===
	char* r12 = cat3(c1, c"..", c2)
	out = wtest_out(av(c"changed", r12, 0, 0, 0), 0)
	if (has_line(out, c"scratch_target") == 0):
		fail(c"c1..c2 (real edit): plain selection dropped scratch_target")
	out = wtest_out(av(c"changed", c"--defhash", r12, 0, 0), 0)
	if (has_line(out, c"scratch_target") == 0):
		fail(c"c1..c2 (real edit): --defhash did not select scratch_target")

	# ===== Three-dot range c0...c2 (linear history, so
	# merge-base(c0,c2) = c0 -- same comparison as the two-dot c0..c2
	# form): a real edit lives in the range, so --defhash must not skip
	# it.
	out = wtest_out(av(c"changed", c"--defhash", cat3(c0, c"...", c2), 0, 0), 0)
	if (has_line(out, c"scratch_target") == 0):
		fail(c"c0...c2 (three-dot, real edit inside): --defhash did not select scratch_target")

	# ===== Deleted file across a range: falls back to the documented
	# residue rule (metadata_check + tests) exactly like an ordinary
	# deleted-file path does today -- not a closure scan, and not a
	# crash. The scratch manifest defines neither target, so wtest_add's
	# own "target not in this manifest" fallback swallows the actual
	# printed selection (0 targets, same as tools/wtest_defhash_e2e.w's
	# own baseline note about unmodified files) -- --verbose's notes are
	# the only way to observe the rule firing in this minimal fixture.
	char* err = wtest_err(av(c"changed", c"--verbose", cat3(c2, c"..", c3), 0, 0), 0)
	if (contains(err, c"bystander.w -> metadata_check") == 0):
		fail(c"deleted file in range: metadata_check residue rule did not fire")
	if (contains(err, c"bystander.w -> tests") == 0):
		fail(c"deleted file in range: tests residue rule did not fire")

	# ===== Open range 'A..' (single revision versus the worktree, task
	# item 1's "single rev meaning rev..worktree"): an uncommitted,
	# comment-only worktree edit on top of c3 must select plainly and be
	# skipped under --defhash, exactly like the closed comment-only case
	# above -- proving the worktree-as-right-side path
	# (wtest_range_right left at 0) instead of an explicit commit.
	char* open3 = cat3(c3, c"..", c"")
	sc_append(c"scratch_lib.w", c"\n# another comment-only edit, uncommitted\n")
	out = wtest_out(av(c"changed", open3, 0, 0, 0), 0)
	if (has_line(out, c"scratch_target") == 0):
		fail(c"c3.. (open range, comment-only worktree edit): plain selection dropped scratch_target")
	out = wtest_out(av(c"changed", c"--defhash", open3, 0, 0), 0)
	if (has_line(out, c"scratch_target")):
		fail(c"c3.. (open range, comment-only worktree edit): --defhash still selected scratch_target")
	git(av(c"checkout", c"-q", c"--", c"scratch_lib.w", 0))

	# ===== No range argument: byte-identical to a plain path list
	# ("commit-ranged selection is opt-in via a positional '..'
	# argument, ordinary paths are untouched" -- scratch_lib.w never
	# contains ".." so it can never be mistaken for one).
	out = wtest_out(av(c"changed", c"scratch_lib.w", 0, 0, 0), 0)
	if (has_line(out, c"scratch_target") == 0):
		fail(c"no-range baseline: plain path selection dropped scratch_target")

	# ===== Invalid revision: a hard error, not a silent fallback ======
	process_result* r = wtest_run(av(c"changed", cat3(c"not_a_real_rev", c"..", c3), 0, 0, 0), 0)
	if (r.status == 0):
		fail(c"invalid range: wtest exited 0")
	if (contains(r.stderr_text, c"invalid revision in range") == 0):
		fail(c"invalid range: wrong/missing error message")
	process_result_free(r)

	# ===== Second range argument: an argument error, not a silently
	# ignored changed-file path (it used to fall to the tests-umbrella
	# catch-all with no diagnostic).
	r = wtest_run(av(c"changed", r01, r12, 0, 0), 0)
	if (r.status == 0):
		fail(c"second range argument: wtest exited 0")
	if (contains(r.stderr_text, c"only one revision range argument") == 0):
		fail(c"second range argument: wrong/missing error message")
	process_result_free(r)

	sc_cleanup()
	char* ok = c"wtest_range_scratch_test: OK\n"
	write(1, ok, strlen(ok))
	return 0
