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
import tools.wtest_scratch


# Shared head of both fake compilers: main() logs its root to calls.log
# (so attempt counts are assertable) and leaves it in 'root'.
void wt_fake_head(string_builder* sb):
	sc_src(sb, 0, c"import lib.lib")
	sc_src(sb, 0, c"import lib.path")
	sc_src(sb, 0, c"import lib.file")
	sc_src(sb, 0, c"import lib.time")
	sc_src(sb, 0, c"")
	sc_src(sb, 0, c"")
	sc_src(sb, 0, c"int fake_eq(char* a, char* b):")
	sc_src(sb, 1, c"int i = 0")
	sc_src(sb, 1, c"while ((a[i] != 0) && (a[i] == b[i])):")
	sc_src(sb, 2, c"i = i + 1")
	sc_src(sb, 1, c"return a[i] == b[i]")
	sc_src(sb, 0, c"")
	sc_src(sb, 0, c"")
	sc_src(sb, 0, c"int main(int argc, char** argv):")
	sc_src(sb, 1, c"char* nl = malloc(1)")
	sc_src(sb, 1, c"nl[0] = 10")
	sc_src(sb, 1, c"char* root = argv[2]")
	sc_src(sb, 1, c"int fd = open(c\"calls.log\", 1089, 420)")
	sc_src(sb, 1, c"if (fd >= 0):")
	sc_src(sb, 2, c"write(fd, root, strlen(root))")
	sc_src(sb, 2, c"write(fd, nl, 1)")
	sc_src(sb, 2, c"close(fd)")


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
	sc_src(sb, 1, c"if (fake_eq(root, c\"slow.w\")):")
	sc_src(sb, 2, c"if (path_exists(c\"slow_seen\") == 0):")
	sc_src(sb, 3, c"file_write_text(c\"slow_seen\", c\"\")")
	sc_src(sb, 3, c"sleep_ms(2000)")
	sc_src(sb, 2, c"println(c\"slow.w\")")
	sc_src(sb, 2, c"println(c\"dep.w\")")
	sc_src(sb, 2, c"return 0")
	sc_src(sb, 1, c"if (fake_eq(root, c\"hang.w\")):")
	sc_src(sb, 2, c"sleep_ms(2000)")
	sc_src(sb, 2, c"return 0")
	sc_src(sb, 1, c"if (fake_eq(root, c\"broken.w\")):")
	sc_src(sb, 2, c"char* msg = c\"broken.w:1:1: error: fixture compile failure\"")
	sc_src(sb, 2, c"write(2, msg, strlen(msg))")
	sc_src(sb, 2, c"write(2, nl, 1)")
	sc_src(sb, 2, c"return 1")
	sc_src(sb, 1, c"println(root)")
	sc_src(sb, 1, c"return 0")
	return sb.data


# The second fake compiler (the load has lifted): every root succeeds
# instantly with the closure "<root>" + "dep.w".
char* wt_fake_lifted_source():
	string_builder* sb = string_new()
	wt_fake_head(sb)
	sc_src(sb, 1, c"println(root)")
	sc_src(sb, 1, c"println(c\"dep.w\")")
	sc_src(sb, 1, c"return 0")
	return sb.data


int main(int argc, char** argv):
	sc_init(c"wtest_timeout_scratch_test", c"wtest_timeout_scratch_")
	sc_require(c"bin/wtest")
	sc_mkdir(c"bin")
	sc_link(c"bin/wtest", c"bin/wtest")
	sc_env = env_copy_with(env_current(), c"WTEST_DEPS_TIMEOUT_MS", c"500")
	sc_install_fake_wv2(wt_fake_loaded_source())

	sc_write(c"w.w", c"int main():\n\treturn 0\n")
	sc_write(c"dep.w", c"int dep = 1\n")
	sc_write(c"slow.w", c"import dep\n")
	sc_write(c"hang.w", c"import dep\n")
	sc_write(c"broken.w", c"import dep\n")
	sc_write(c"build.json", c"{\n\t\"targets\": [\n\t\t{\n\t\t\t\"name\": \"slow_t\",\n\t\t\t\"steps\": [\n\t\t\t\t{\"cmd\": [\"bin/wv2\", \"slow.w\", \"-o\", \"bin/slow\"]}\n\t\t\t]\n\t\t},\n\t\t{\n\t\t\t\"name\": \"hang_t\",\n\t\t\t\"steps\": [\n\t\t\t\t{\"cmd\": [\"bin/wv2\", \"hang.w\", \"-o\", \"bin/hang\"]}\n\t\t\t]\n\t\t},\n\t\t{\n\t\t\t\"name\": \"broken_t\",\n\t\t\t\"steps\": [\n\t\t\t\t{\"cmd\": [\"bin/wv2\", \"broken.w\", \"-o\", \"bin/broken\"]}\n\t\t\t]\n\t\t}\n\t]\n}\n")

	# 1) Cold run. slow.w times out once and succeeds on the retry (its
	# closure selection survives within the same run); hang.w times out
	# twice (falls back LOUDLY and is NOT persisted); broken.w really
	# fails (persisted as an 'X' entry, exactly as before).
	process_result* r = wtest_run(av(c"changed", c"dep.w"), 0)
	if (count_line(r.stdout_text, c"slow_t") == 0):
		fail(c"retry did not recover slow.w's closure selection")
	if (count_line(r.stdout_text, c"hang_t") != 0):
		fail(c"hang_t selected without a computable closure")
	if (contains(r.stderr_text, c"wtest: warning: 'bin/wv2 deps' timed out for root 'x86 slow.w'; retrying once") == 0):
		fail(c"no retry warning for slow.w")
	if (contains(r.stderr_text, c"wtest: warning: 'bin/wv2 deps' timed out again for root 'x86 hang.w'; giving up for this run (timeouts are never cached)") == 0):
		fail(c"no give-up warning for hang.w")
	if (contains(r.stderr_text, c"wtest: warning: 'bin/wv2 deps' failed for root 'x86 broken.w'") == 0):
		fail(c"no failure warning for broken.w")
	char* cache = sc_read(c"bin/.wtest_deps_cache")
	if (count_line(cache, c"R x86 slow.w") == 0): fail(c"slow.w's retried closure was not cached")
	if (count_line(cache, c"X x86 broken.w") == 0):
		fail(c"broken.w's real compile failure was not cached")
	if (contains(cache, c"x86 hang.w")): fail(c"hang.w's timeout was persisted to the cache")
	char* calls = sc_read(c"calls.log")
	if (count_line(calls, c"slow.w") != 2):
		fail(c"expected exactly 2 slow.w attempts (timeout + retry)")
	if (count_line(calls, c"hang.w") != 2):
		fail(c"expected exactly 2 hang.w attempts (timeout + retry)")

	# 2) Next run: slow.w is warm (no new attempt), broken.w's persisted
	# failure holds (no new attempt), and hang.w RETRIES because its
	# timeout was never cached.
	sc_write(c"calls.log", c"")
	r = wtest_run(av(c"changed", c"dep.w"), 0)
	calls = sc_read(c"calls.log")
	if (count_line(calls, c"slow.w") != 0): fail(c"warm slow.w closure was recomputed")
	if (count_line(calls, c"broken.w") != 0):
		fail(c"persisted broken.w failure was retried without a content change")
	if (count_line(calls, c"hang.w") != 2):
		fail(c"timed-out hang.w was not retried on the next run")
	if (count_line(r.stdout_text, c"slow_t") == 0): fail(c"warm rerun lost slow_t")

	# 3) Load lifts: hang.w stops sleeping and the VERY NEXT run computes
	# its closure (a persisted 'X' entry would have blocked this until
	# hang.w's content changed). The new bin/wv2 content also retries
	# broken.w, per the X-entry validation.
	sc_install_fake_wv2(wt_fake_lifted_source())
	r = wtest_run(av(c"changed", c"dep.w"), 0)
	if (count_line(r.stdout_text, c"hang_t") == 0):
		fail(c"hang_t still unselected after the load lifted")
	if (count_line(r.stdout_text, c"broken_t") == 0):
		fail(c"broken_t not retried after bin/wv2 changed")
	if (contains(r.stderr_text, c"timed out")):
		fail(c"timeout warning still fired after the load lifted")

	return sc_ok()
