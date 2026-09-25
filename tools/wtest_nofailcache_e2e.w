# wbuild: target=wtest_nofailcache_test tag=tests dep=wtest dep=wv2 data=tools/wtest_nofailcache_e2e.w
# wbuild: step="bin/wv2 tools/wtest_nofailcache_e2e.w -o bin/wtest_nofailcache_e2e"
# wbuild: step="bin/wtest_nofailcache_e2e" expect_stdout="wtest_nofailcache_scratch_test: OK"
/*
Regression fixture for the deps-failure caching bug (tools/test_map.w,
docs/projects/ai_tooling_next_steps.md 2026-07-28 residue), run by the
`wtest_nofailcache_test` target. It replaced
tools/wtest_nofailcache_scratch_test.sh (issue #323: no shell scripts);
every child is spawned through lib/process.w with an argv vector -- no
/bin/sh. The FAIL messages and the final OK line keep the old script's
name so the target's expectations are unchanged.

The derived seed-graph rule caches 'bin/wv2 deps w.w' against w.w's
content hash, and it used to cache FAILURES too -- running bin/wtest
while bin/wv2 was merely missing wrote an 'X' entry that silently pinned
the rule to its coarse compiler-tree prefix floor until w.w itself
changed, even after bin/wv2 reappeared. Failures are no longer cached:
the fallback is announced on stderr and retried on the next run.

Like tools/wtest_defhash_e2e.w, this needs its own scratch checkout (a
pid-scoped directory under bin/ with a tiny w.w and a fixture
build.json, plus symlinked lib/ structures/ code_generator/ trees for
the auto-imported runtime) because the scenario is "bin/wv2 is missing,
then comes back" -- the real repo's bin/wv2 cannot be hidden while other
targets run in parallel.
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
		sc_err(c"wtest_nofailcache_scratch_test: bin/wv2 and bin/wtest must be built first\n")
		exit(1)
	free(wv2)
	free(wtest)
	string_builder* d = string_new()
	string_append(d, sc_root)
	string_append(d, c"/bin/wtest_nofailcache_e2e_")
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
	# bin/wv2 is deliberately NOT linked yet: the first runs in main
	# exercise the "compiler temporarily missing" failure path.
	sc_link(c"bin/wtest", c"bin/wtest")
	sc_link(c"lib", c"lib")
	sc_link(c"structures", c"structures")
	sc_link(c"code_generator", c"code_generator")


# grep -q '^<prefix>' on a file in the scratch tree (0 when absent).
int file_has_line_prefix(char* rel, char* prefix):
	char* path = path_join(sc_dir, rel)
	char* text = file_read_text(path)
	free(path)
	if (text == 0):
		return 0
	int nl = strlen(prefix)
	int found = 0
	int i = 0
	while ((text[i] != 0) && (found == 0)):
		int j = 0
		while ((j < nl) && (text[i + j] == prefix[j])):
			j = j + 1
		if (j == nl):
			found = 1
		while ((text[i] != 0) && (text[i] != '\n')):
			i = i + 1
		if (text[i] == '\n'):
			i = i + 1
	free(text)
	return found


char* WARNING = 0


int main():
	sc_name = c"wtest_nofailcache_scratch_test"
	WARNING = c"wtest: warning: 'bin/wv2 deps' failed"
	sc_setup()
	sc_write(c"w.w", c"import lib.file\n\nint main():\n\treturn 0\n")
	# No step-less umbrella target here: this fixture is about the seed
	# rule, not the large-selection collapse.
	sc_write(c"build.json", c"{\n\t\"targets\": [\n\t\t{\n\t\t\t\"name\": \"verify\",\n\t\t\t\"steps\": [\n\t\t\t\t{\"cmd\": [\"true\"]}\n\t\t\t]\n\t\t},\n\t\t{\n\t\t\t\"name\": \"self_host_warning_test\",\n\t\t\t\"steps\": [\n\t\t\t\t{\"cmd\": [\"true\"]}\n\t\t\t]\n\t\t},\n\t\t{\n\t\t\t\"name\": \"parser_generator_w_test\",\n\t\t\t\"steps\": [\n\t\t\t\t{\"cmd\": [\"true\"]}\n\t\t\t]\n\t\t},\n\t\t{\n\t\t\t\"name\": \"metadata_check\",\n\t\t\t\"steps\": [\n\t\t\t\t{\"cmd\": [\"true\"]}\n\t\t\t]\n\t\t},\n\t\t{\n\t\t\t\"name\": \"probe_target\",\n\t\t\t\"steps\": [\n\t\t\t\t{\"cmd\": [\"true\", \"lib/file.w\"]}\n\t\t\t]\n\t\t}\n\t]\n}\n")

	# 1) bin/wv2 missing: the seed-graph rule must fall back LOUDLY to
	# the prefix floor (lib/file.w is in the tiny w.w's closure, but the
	# closure cannot be computed), keep the literal selection, and NOT
	# persist the failure.
	process_result* r = wtest_run(av(c"changed", c"lib/file.w", 0, 0, 0), 0)
	if (r.status != 0):
		sc_err(r.stderr_text)
		fail(c"bin/wtest exited nonzero")
	if (contains(r.stderr_text, WARNING) == 0):
		fail(c"no fallback warning while bin/wv2 was missing")
	if (has_line(r.stdout_text, c"verify")):
		fail(c"verify selected with no computable seed closure")
	if (has_line(r.stdout_text, c"probe_target") == 0):
		fail(c"literal selection lost while bin/wv2 was missing")
	if (file_has_line_prefix(c"bin/.wtest_deps_cache", c"X ")):
		fail(c"deps failure was persisted as an 'X' cache entry")
	process_result_free(r)

	# 2) A second run without bin/wv2 retries (and warns) instead of
	# silently reusing a cached failure.
	char* err = wtest_err(av(c"changed", c"lib/file.w", 0, 0, 0), 0)
	if (contains(err, WARNING) == 0):
		fail(c"second run did not retry / warn")

	# 3) bin/wv2 back: the VERY NEXT run must recover the derived seed
	# graph (the old 'X' entry semantics kept the rule pinned to the
	# prefix floor here until w.w itself changed).
	sc_link(c"bin/wv2", c"bin/wv2")
	r = wtest_run(av(c"changed", c"lib/file.w", 0, 0, 0), 0)
	if (r.status != 0):
		sc_err(r.stderr_text)
		fail(c"bin/wtest exited nonzero")
	if (has_line(r.stdout_text, c"verify") == 0):
		fail(c"seed rule still on the prefix floor after bin/wv2 reappeared")
	if (has_line(r.stdout_text, c"self_host_warning_test") == 0):
		fail(c"self_host_warning_test missing after recovery")
	if (contains(r.stderr_text, WARNING)):
		fail(c"fallback warning still fired with bin/wv2 present")
	if (file_has_line_prefix(c"bin/.wtest_deps_cache", c"R x86 w.w") == 0):
		fail(c"successful seed closure was not cached")
	process_result_free(r)

	# 4) Warm rerun keeps the derived selection (cache hit, no
	# recompute).
	char* out = wtest_out(av(c"changed", c"lib/file.w", 0, 0, 0), 0)
	if (has_line(out, c"verify") == 0):
		fail(c"warm rerun lost verify")

	# 5) A stale 'X' failure entry written by an older bin/wtest build is
	# ignored on load (never pins the rule), whatever its recorded hash.
	sc_write(c"bin/.wtest_deps_cache", c"X x86 w.w\nH 0123456789abcdef\n")
	out = wtest_out(av(c"changed", c"lib/file.w", 0, 0, 0), 0)
	if (has_line(out, c"verify") == 0):
		fail(c"a stale legacy 'X' entry pinned the seed rule")

	sc_cleanup()
	char* ok = c"wtest_nofailcache_scratch_test: OK\n"
	write(1, ok, strlen(ok))
	return 0
