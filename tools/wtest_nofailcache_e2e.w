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
import lib.path
import lib.file
import tools.wtest_scratch


void sc_setup():
	sc_init(c"wtest_nofailcache_scratch_test", c"wtest_nofailcache_e2e_")
	sc_require(c"bin/wv2")
	sc_require(c"bin/wtest")
	sc_mkdir(c"bin")
	# bin/wv2 is deliberately NOT linked yet: the first runs in main
	# exercise the "compiler temporarily missing" failure path.
	sc_link(c"bin/wtest", c"bin/wtest")
	sc_link(c"lib", c"lib")
	sc_link(c"structures", c"structures")
	sc_link(c"code_generator", c"code_generator")


char* WARNING = 0


int main():
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
	process_result* r = wtest_run(av(c"changed", c"lib/file.w"), 0)
	if (r.status != 0):
		sc_err(r.stderr_text)
		fail(c"bin/wtest exited nonzero")
	if (contains(r.stderr_text, WARNING) == 0):
		fail(c"no fallback warning while bin/wv2 was missing")
	if (has_line(r.stdout_text, c"verify")):
		fail(c"verify selected with no computable seed closure")
	if (has_line(r.stdout_text, c"probe_target") == 0):
		fail(c"literal selection lost while bin/wv2 was missing")
	if (has_line_prefix(sc_read(c"bin/.wtest_deps_cache"), c"X ")):
		fail(c"deps failure was persisted as an 'X' cache entry")
	process_result_free(r)

	# 2) A second run without bin/wv2 retries (and warns) instead of
	# silently reusing a cached failure.
	char* err = wtest_err(av(c"changed", c"lib/file.w"), 0)
	if (contains(err, WARNING) == 0):
		fail(c"second run did not retry / warn")

	# 3) bin/wv2 back: the VERY NEXT run must recover the derived seed
	# graph (the old 'X' entry semantics kept the rule pinned to the
	# prefix floor here until w.w itself changed).
	sc_link(c"bin/wv2", c"bin/wv2")
	r = wtest_run(av(c"changed", c"lib/file.w"), 0)
	if (r.status != 0):
		sc_err(r.stderr_text)
		fail(c"bin/wtest exited nonzero")
	if (has_line(r.stdout_text, c"verify") == 0):
		fail(c"seed rule still on the prefix floor after bin/wv2 reappeared")
	if (has_line(r.stdout_text, c"self_host_warning_test") == 0):
		fail(c"self_host_warning_test missing after recovery")
	if (contains(r.stderr_text, WARNING)):
		fail(c"fallback warning still fired with bin/wv2 present")
	if (has_line_prefix(sc_read(c"bin/.wtest_deps_cache"), c"R x86 w.w") == 0):
		fail(c"successful seed closure was not cached")
	process_result_free(r)

	# 4) Warm rerun keeps the derived selection (cache hit, no
	# recompute).
	char* out = wtest_out(av(c"changed", c"lib/file.w"), 0)
	if (has_line(out, c"verify") == 0):
		fail(c"warm rerun lost verify")

	# 5) A stale 'X' failure entry written by an older bin/wtest build is
	# ignored on load (never pins the rule), whatever its recorded hash.
	sc_write(c"bin/.wtest_deps_cache", c"X x86 w.w\nH 0123456789abcdef\n")
	out = wtest_out(av(c"changed", c"lib/file.w"), 0)
	if (has_line(out, c"verify") == 0):
		fail(c"a stale legacy 'X' entry pinned the seed rule")

	return sc_ok()
