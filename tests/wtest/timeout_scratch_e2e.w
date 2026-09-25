# wbuild: target=wtest_timeout_test tag=tests dep=wtest data=tests/wtest/timeout_scratch_e2e.w
# wbuild: step="bin/wv2 tests/wtest/timeout_scratch_e2e.w -o bin/wtest_timeout_e2e"
# wbuild: step="bin/wtest_timeout_e2e" expect_stdout="wtest_timeout_scratch_test: OK"
/*
Regression fixture for timeout-shaped 'bin/wv2 deps' failures
(tools/test_map.w; docs/projects/ai_tooling_next_steps.md 2026-07-29
U4/U5): under parallel load a deps shell-out can exceed its
process_run budget, and the timeout used to be persisted as an 'X'
cache entry keyed to the root's content hash -- silently disabling
closure (and per-arch verify) selection until the stale line was
hand-deleted. Now a timeout is retried once immediately, never
persisted (only real nonzero compile exits are), and every failed
shell-out prints one stderr line naming its root.

Uses a scratch checkout with a FAKE bin/wv2 (a tiny W program keyed on
the root path, written into the scratch checkout and compiled with the
real bin/wv2) and a small WTEST_DEPS_TIMEOUT_MS so the timeout path
runs in under a second instead of 120s per attempt.

Replaced tests/wtest/timeout_scratch_test.sh (issue #323: no shell
scripts). The scratch checkout is a pid-scoped directory under bin/,
and every child is spawned through lib/process.w with an argv vector
-- no /bin/sh.
*/
import lib.lib
import lib.env
import lib.process
import lib.path
import lib.file
import lib.str
import structures.string


char* wt_root_dir
char* wt_dir
char* wt_wtest


void wt_rm_rf(char* path):
	char** argv = strv_new(3)
	strv_set(argv, 0, c"/bin/rm")
	strv_set(argv, 1, c"-rf")
	strv_set(argv, 2, path)
	process_result* r = process_run(c"/bin/rm", argv, 0, 0, 60000)
	if (r != 0):
		process_result_free(r)
	free(cast(char*, argv))


void wt_err(char* msg):
	write(2, msg, strlen(msg))


void wt_fail(char* msg):
	wt_err(c"wtest_timeout_scratch_test: FAIL: ")
	wt_err(msg)
	wt_err(c"\n")
	if (wt_dir != 0):
		wt_rm_rf(wt_dir)
	exit(1)


int wt_eq(char* a, char* b):
	int i = 0
	while ((a[i] != 0) && (a[i] == b[i])):
		i = i + 1
	return a[i] == b[i]


int wt_has(char* text, char* needle):
	if (text == 0):
		return 0
	return index_of(text, needle) >= 0


# grep -cx line: the number of lines exactly equal to line.
int wt_count_line(char* text, char* line):
	if (text == 0):
		return 0
	int count = 0
	for char* piece in split(text, 10):
		if (wt_eq(piece, line)):
			count = count + 1
	return count


char* wt_path(char* rel):
	return path_join(wt_dir, rel)


char* wt_read(char* rel):
	return file_read_text(wt_path(rel))


void wt_write(char* rel, char* text):
	if (file_write_text(wt_path(rel), text) == 0):
		wt_fail(strjoin(c"cannot write ", rel))


# One 'bin/wtest changed dep.w' run in the scratch checkout under the
# shrunken WTEST_DEPS_TIMEOUT_MS budget.
process_result* wt_wtest_changed():
	char** argv = strv_new(3)
	strv_set(argv, 0, c"bin/wtest")
	strv_set(argv, 1, c"changed")
	strv_set(argv, 2, c"dep.w")
	spawn_options* opts = spawn_options_new()
	opts.cwd = wt_dir
	opts.env = env_copy_with(env_current(), c"WTEST_DEPS_TIMEOUT_MS", c"500")
	process_result* r = process_run(wt_path(c"bin/wtest"), argv, opts, 0, 600000)
	if (r == 0):
		wt_fail(c"could not spawn bin/wtest")
	return r


void wt_src(string_builder* sb, int tabs, char* line):
	int i = 0
	while (i < tabs):
		string_append(sb, c"\t")
		i = i + 1
	string_append(sb, line)
	string_append(sb, c"\n")


# Shared head of both fake compilers: main() logs its root to calls.log
# (so attempt counts are assertable) and leaves it in 'root'.
void wt_fake_head(string_builder* sb):
	wt_src(sb, 0, c"import lib.lib")
	wt_src(sb, 0, c"import lib.path")
	wt_src(sb, 0, c"import lib.file")
	wt_src(sb, 0, c"import lib.time")
	wt_src(sb, 0, c"")
	wt_src(sb, 0, c"")
	wt_src(sb, 0, c"int fake_eq(char* a, char* b):")
	wt_src(sb, 1, c"int i = 0")
	wt_src(sb, 1, c"while ((a[i] != 0) && (a[i] == b[i])):")
	wt_src(sb, 2, c"i = i + 1")
	wt_src(sb, 1, c"return a[i] == b[i]")
	wt_src(sb, 0, c"")
	wt_src(sb, 0, c"")
	wt_src(sb, 0, c"int main(int argc, char** argv):")
	wt_src(sb, 1, c"char* nl = malloc(1)")
	wt_src(sb, 1, c"nl[0] = 10")
	wt_src(sb, 1, c"char* root = argv[2]")
	wt_src(sb, 1, c"int fd = open(c\"calls.log\", 1089, 420)")
	wt_src(sb, 1, c"if (fd >= 0):")
	wt_src(sb, 2, c"write(fd, root, strlen(root))")
	wt_src(sb, 2, c"write(fd, nl, 1)")
	wt_src(sb, 2, c"close(fd)")


# The first fake compiler: 'bin/wv2 deps <root>' behavior keyed on the root.
#   w.w      -> instant success (the seed closure; keeps the seed
#               residue rule quiet)
#   slow.w   -> sleeps past the budget on the FIRST call, succeeds on
#               the retry
#   hang.w   -> always sleeps past the budget (both attempts time out)
#   broken.w -> a real nonzero compile exit (the persistable flavor)
char* wt_fake_loaded_source():
	string_builder* sb = string_new()
	wt_fake_head(sb)
	wt_src(sb, 1, c"if (fake_eq(root, c\"slow.w\")):")
	wt_src(sb, 2, c"if (path_exists(c\"slow_seen\") == 0):")
	wt_src(sb, 3, c"file_write_text(c\"slow_seen\", c\"\")")
	wt_src(sb, 3, c"sleep_ms(2000)")
	wt_src(sb, 2, c"println(c\"slow.w\")")
	wt_src(sb, 2, c"println(c\"dep.w\")")
	wt_src(sb, 2, c"return 0")
	wt_src(sb, 1, c"if (fake_eq(root, c\"hang.w\")):")
	wt_src(sb, 2, c"sleep_ms(2000)")
	wt_src(sb, 2, c"return 0")
	wt_src(sb, 1, c"if (fake_eq(root, c\"broken.w\")):")
	wt_src(sb, 2, c"char* msg = c\"broken.w:1:1: error: fixture compile failure\"")
	wt_src(sb, 2, c"write(2, msg, strlen(msg))")
	wt_src(sb, 2, c"write(2, nl, 1)")
	wt_src(sb, 2, c"return 1")
	wt_src(sb, 1, c"println(root)")
	wt_src(sb, 1, c"return 0")
	return sb.data


# The second fake compiler (the load has lifted): every root succeeds
# instantly with the closure "<root>" + "dep.w".
char* wt_fake_lifted_source():
	string_builder* sb = string_new()
	wt_fake_head(sb)
	wt_src(sb, 1, c"println(root)")
	wt_src(sb, 1, c"println(c\"dep.w\")")
	wt_src(sb, 1, c"return 0")
	return sb.data


void wt_install_fake_wv2(char* source):
	wt_write(c"fake_wv2.w", source)
	char* compiler = path_join(wt_root_dir, c"bin/wv2")
	char** argv = strv_new(4)
	strv_set(argv, 0, compiler)
	strv_set(argv, 1, wt_path(c"fake_wv2.w"))
	strv_set(argv, 2, c"-o")
	strv_set(argv, 3, wt_path(c"bin/wv2"))
	spawn_options* opts = spawn_options_new()
	opts.cwd = wt_root_dir
	process_result* r = process_run(compiler, argv, opts, 0, 600000)
	if (r == 0):
		wt_fail(c"could not spawn bin/wv2 for the fake compiler")
	if (r.status != 0):
		wt_err(r.stderr_text)
		wt_fail(c"fake bin/wv2 did not compile")
	process_result_free(r)


int main(int argc, char** argv):
	char* cwd = malloc(4096)
	if (getcwd(cwd, 4096) <= 0):
		wt_fail(c"getcwd failed")
	wt_root_dir = cwd
	wt_wtest = path_join(wt_root_dir, c"bin/wtest")
	if (path_exists(wt_wtest) == 0):
		wt_err(c"wtest_timeout_scratch_test: bin/wtest must be built first\n")
		return 1

	wt_dir = path_join(wt_root_dir, strjoin(c"bin/wtest_timeout_scratch_", itoa(getpid())))
	wt_rm_rf(wt_dir)
	mkdir(wt_dir, 493)
	mkdir(wt_path(c"bin"), 493)
	if (symlink(wt_wtest, wt_path(c"bin/wtest")) < 0):
		wt_fail(c"cannot symlink bin/wtest into the scratch checkout")
	wt_install_fake_wv2(wt_fake_loaded_source())

	wt_write(c"w.w", c"int main():\n\treturn 0\n")
	wt_write(c"dep.w", c"int dep = 1\n")
	wt_write(c"slow.w", c"import dep\n")
	wt_write(c"hang.w", c"import dep\n")
	wt_write(c"broken.w", c"import dep\n")
	wt_write(c"build.json", c"{\n\t\"targets\": [\n\t\t{\n\t\t\t\"name\": \"slow_t\",\n\t\t\t\"steps\": [\n\t\t\t\t{\"cmd\": [\"bin/wv2\", \"slow.w\", \"-o\", \"bin/slow\"]}\n\t\t\t]\n\t\t},\n\t\t{\n\t\t\t\"name\": \"hang_t\",\n\t\t\t\"steps\": [\n\t\t\t\t{\"cmd\": [\"bin/wv2\", \"hang.w\", \"-o\", \"bin/hang\"]}\n\t\t\t]\n\t\t},\n\t\t{\n\t\t\t\"name\": \"broken_t\",\n\t\t\t\"steps\": [\n\t\t\t\t{\"cmd\": [\"bin/wv2\", \"broken.w\", \"-o\", \"bin/broken\"]}\n\t\t\t]\n\t\t}\n\t]\n}\n")

	# 1) Cold run. slow.w times out once and succeeds on the retry (its
	# closure selection survives within the same run); hang.w times out
	# twice (falls back LOUDLY and is NOT persisted); broken.w really
	# fails (persisted as an 'X' entry, exactly as before).
	process_result* r = wt_wtest_changed()
	if (wt_count_line(r.stdout_text, c"slow_t") == 0):
		wt_fail(c"retry did not recover slow.w's closure selection")
	if (wt_count_line(r.stdout_text, c"hang_t") != 0):
		wt_fail(c"hang_t selected without a computable closure")
	if (wt_has(r.stderr_text, c"wtest: warning: 'bin/wv2 deps' timed out for root 'x86 slow.w'; retrying once") == 0):
		wt_fail(c"no retry warning for slow.w")
	if (wt_has(r.stderr_text, c"wtest: warning: 'bin/wv2 deps' timed out again for root 'x86 hang.w'; giving up for this run (timeouts are never cached)") == 0):
		wt_fail(c"no give-up warning for hang.w")
	if (wt_has(r.stderr_text, c"wtest: warning: 'bin/wv2 deps' failed for root 'x86 broken.w'") == 0):
		wt_fail(c"no failure warning for broken.w")
	char* cache = wt_read(c"bin/.wtest_deps_cache")
	if (wt_count_line(cache, c"R x86 slow.w") == 0):
		wt_fail(c"slow.w's retried closure was not cached")
	if (wt_count_line(cache, c"X x86 broken.w") == 0):
		wt_fail(c"broken.w's real compile failure was not cached")
	if (wt_has(cache, c"x86 hang.w")):
		wt_fail(c"hang.w's timeout was persisted to the cache")
	char* calls = wt_read(c"calls.log")
	if (wt_count_line(calls, c"slow.w") != 2):
		wt_fail(c"expected exactly 2 slow.w attempts (timeout + retry)")
	if (wt_count_line(calls, c"hang.w") != 2):
		wt_fail(c"expected exactly 2 hang.w attempts (timeout + retry)")

	# 2) Next run: slow.w is warm (no new attempt), broken.w's persisted
	# failure holds (no new attempt), and hang.w RETRIES because its
	# timeout was never cached.
	wt_write(c"calls.log", c"")
	r = wt_wtest_changed()
	calls = wt_read(c"calls.log")
	if (wt_count_line(calls, c"slow.w") != 0):
		wt_fail(c"warm slow.w closure was recomputed")
	if (wt_count_line(calls, c"broken.w") != 0):
		wt_fail(c"persisted broken.w failure was retried without a content change")
	if (wt_count_line(calls, c"hang.w") != 2):
		wt_fail(c"timed-out hang.w was not retried on the next run")
	if (wt_count_line(r.stdout_text, c"slow_t") == 0):
		wt_fail(c"warm rerun lost slow_t")

	# 3) Load lifts: hang.w stops sleeping and the VERY NEXT run computes
	# its closure (a persisted 'X' entry would have blocked this until
	# hang.w's content changed). The new bin/wv2 content also retries
	# broken.w, per the X-entry validation.
	wt_install_fake_wv2(wt_fake_lifted_source())
	r = wt_wtest_changed()
	if (wt_count_line(r.stdout_text, c"hang_t") == 0):
		wt_fail(c"hang_t still unselected after the load lifted")
	if (wt_count_line(r.stdout_text, c"broken_t") == 0):
		wt_fail(c"broken_t not retried after bin/wv2 changed")
	if (wt_has(r.stderr_text, c"timed out")):
		wt_fail(c"timeout warning still fired after the load lifted")

	wt_rm_rf(wt_dir)
	println(c"wtest_timeout_scratch_test: OK")
	return 0
