# wbuild: target=wtest_why_test tag=tests dep=wtest data=tests/wtest/why_scratch_e2e.w
# wbuild: step="bin/wv2 tests/wtest/why_scratch_e2e.w -o bin/wtest_why_e2e"
# wbuild: step="bin/wtest_why_e2e" expect_stdout="wtest_why_scratch_test: OK"
/*
Fixture for the NAMED deps-failure aggregate warning and the
'wtest why <root>' explainer (tools/test_map.w;
docs/projects/ai_tooling_next_steps.md 2026-08-05: the aggregate
warning was anonymous -- "'bin/wv2 deps' failed for 72 roots" named
no root and no reason, so an agent could not tell whether the
fallback lost selection coverage for its diff or which roots needed
fixing). Now the aggregate names the first few failing roots plus a
count and one representative stderr line, persistable failures carry
their stderr detail into bin/.wtest_deps_cache ('E ' line), and
'wtest why [<arch>] <file.w>' explains one root's cache/live/
selection story.

Uses a scratch checkout with a FAKE bin/wv2 keyed on the root path
(the tests/wtest/timeout_scratch_e2e.w pattern: a tiny W program
written into the scratch checkout and compiled with the real bin/wv2)
so every failure flavor is deterministic and instant;
WTEST_DEPS_TIMEOUT_MS shrinks the timeout budget so the hang.w path
runs in under a second.

Replaced tests/wtest/why_scratch_test.sh (issue #323: no shell
scripts). The scratch checkout is a pid-scoped directory under bin/,
and every child is spawned through lib/process.w with an argv vector
-- no /bin/sh.
*/
import lib.lib
import lib.env
import tools.wtest_scratch


# grep -A2 "^<line>$" | grep -q "^<prefix>": one of the two lines after
# a line exactly equal to line starts with prefix.
int wy_prefix_follows(char* text, char* line, char* prefix):
	if (text == 0): return 0
	list[char*] lines = split(text, 10)
	int i = 0
	while (i < lines.length):
		if (strcmp(lines[i], line) == 0):
			int j = i + 1
			while ((j <= (i + 2)) && (j < lines.length)):
				if (starts_with(lines[j], prefix)): return 1
				j = j + 1
		i = i + 1
	return 0


# The fake compiler: 'bin/wv2 deps [x64] <root>' keyed on the root.
#   ok.w           -> success; closure ok.w + dep.w
#   bad1.w         -> "cannot locate 'gen/missing1.w'" until that file
#                     appears, then success (the M-line retry story)
#   bad2.w-bad6.w  -> a plain compile error, distinct per root
#   hang.w         -> always sleeps past the budget (never cached)
#   anything else  -> success; closure is just the root itself
char* wy_fake_wv2_source():
	string_builder* sb = string_new()
	sc_src(sb, 0, c"import lib.lib")
	sc_src(sb, 0, c"import lib.path")
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
	sc_src(sb, 0, c"void fake_err(char* s):")
	sc_src(sb, 1, c"write(2, s, strlen(s))")
	sc_src(sb, 0, c"")
	sc_src(sb, 0, c"")
	sc_src(sb, 0, c"int main(int argc, char** argv):")
	sc_src(sb, 1, c"char* nl = malloc(1)")
	sc_src(sb, 1, c"nl[0] = 10")
	sc_src(sb, 1, c"char* root = argv[2]")
	sc_src(sb, 1, c"if (fake_eq(root, c\"x64\")):")
	sc_src(sb, 2, c"root = argv[3]")
	sc_src(sb, 1, c"int n = strlen(root)")
	sc_src(sb, 1, c"if (fake_eq(root, c\"ok.w\")):")
	sc_src(sb, 2, c"println(c\"ok.w\")")
	sc_src(sb, 2, c"println(c\"dep.w\")")
	sc_src(sb, 2, c"return 0")
	sc_src(sb, 1, c"if (fake_eq(root, c\"bad1.w\")):")
	sc_src(sb, 2, c"if (path_exists(c\"gen/missing1.w\")):")
	sc_src(sb, 3, c"println(c\"bad1.w\")")
	sc_src(sb, 3, c"println(c\"gen/missing1.w\")")
	sc_src(sb, 3, c"println(c\"dep.w\")")
	sc_src(sb, 3, c"return 0")
	sc_src(sb, 2, c"fake_err(c\"bad1.w:2:1: error: cannot locate 'gen/missing1.w'\")")
	sc_src(sb, 2, c"write(2, nl, 1)")
	sc_src(sb, 2, c"return 1")
	sc_src(sb, 1, c"if ((n >= 5) && (root[0] == 'b') && (root[1] == 'a') && (root[2] == 'd') && (root[n - 2] == '.') && (root[n - 1] == 'w')):")
	sc_src(sb, 2, c"fake_err(root)")
	sc_src(sb, 2, c"fake_err(c\":1:1: error: fixture failure in \")")
	sc_src(sb, 2, c"fake_err(root)")
	sc_src(sb, 2, c"write(2, nl, 1)")
	sc_src(sb, 2, c"return 1")
	sc_src(sb, 1, c"if (fake_eq(root, c\"hang.w\")):")
	sc_src(sb, 2, c"sleep_ms(2000)")
	sc_src(sb, 2, c"return 0")
	sc_src(sb, 1, c"println(root)")
	sc_src(sb, 1, c"return 0")
	return sb.data


int main(int argc, char** argv):
	sc_init(c"wtest_why_scratch_test", c"wtest_why_scratch_")
	sc_require(c"bin/wtest")
	sc_mkdir(c"bin")
	sc_link(c"bin/wtest", c"bin/wtest")
	sc_env = env_copy_with(env_current(), c"WTEST_DEPS_TIMEOUT_MS", c"400")
	sc_install_fake_wv2(wy_fake_wv2_source())

	sc_write(c"w.w", c"int main():\n\treturn 0\n")
	sc_write(c"dep.w", c"int dep = 1\n")

	# One conventional compile target per root, in manifest order, so the
	# failing-root list in the aggregate warning is deterministic.
	list[char*] roots = new list[char*]
	roots.push(c"ok")
	roots.push(c"bad1")
	roots.push(c"bad2")
	roots.push(c"bad3")
	roots.push(c"bad4")
	roots.push(c"bad5")
	roots.push(c"bad6")
	roots.push(c"hang")
	string_builder* manifest = string_new()
	string_append(manifest, c"{\n\t\"targets\": [\n")
	int first = 1
	for char* f in roots:
		sc_write(strjoin(f, c".w"), c"import dep\n")
		if (first == 0): string_append(manifest, c",\n")
		first = 0
		string_append(manifest, c"\t\t{\"name\": \"")
		string_append(manifest, f)
		string_append(manifest, c"_t\", \"steps\": [{\"cmd\": [\"bin/wv2\", \"")
		string_append(manifest, f)
		string_append(manifest, c".w\", \"-o\", \"bin/")
		string_append(manifest, f)
		string_append(manifest, c"\"]}]}")
	string_append(manifest, c"\n\t]\n}\n")
	sc_write(c"build.json", manifest.data)

	# 1) Cold run: the aggregate warning NAMES the failing roots (first
	# five plus a count), gives one representative stderr line, and points
	# at 'wtest why'. Selection through computable closures is unaffected,
	# and the failed roots stay unselected (literal fallback has nothing
	# to match for dep.w).
	process_result* r = wtest_run(av(c"changed", c"dep.w"), 0)
	if (contains(r.stderr_text, c"wtest: warning: 'bin/wv2 deps' failed for 7 roots; falling back to literal matching for them: x86 bad1.w, x86 bad2.w, x86 bad3.w, x86 bad4.w, x86 bad5.w (and 2 more)") == 0):
		fail(c"aggregate warning does not name the failing roots")
	if (contains(r.stderr_text, c"wtest: warning: e.g. root 'x86 bad1.w': bad1.w:2:1: error: cannot locate 'gen/missing1.w'") == 0):
		fail(c"no representative failure reason")
	if (contains(r.stderr_text, c"wtest: note: 'wtest why [<arch>] <file.w>' explains any root's selection story") == 0):
		fail(c"no wtest-why pointer")
	if (has_line(r.stdout_text, c"ok_t") == 0): fail(c"closure selection lost ok_t")
	if (has_line(r.stdout_text, c"bad1_t")): fail(c"bad1_t selected without a closure")

	# 2) Persistable failures carry their stderr detail ('E ') and
	# successes the computing compiler's hash ('V ', informational) in
	# bin/.wtest_deps_cache; timeouts are still never persisted.
	char* cache = sc_read(c"bin/.wtest_deps_cache")
	if (has_line(cache, c"X x86 bad1.w") == 0): fail(c"bad1.w failure not cached")
	if (has_line(cache, c"E bad1.w:2:1: error: cannot locate 'gen/missing1.w'") == 0):
		fail(c"no E detail line for bad1.w")
	if (has_line(cache, c"M gen/missing1.w") == 0): fail(c"no M line for bad1.w")
	if (wy_prefix_follows(cache, c"R x86 ok.w", c"V ") == 0):
		fail(c"no informational V line on ok.w's success entry")
	if (contains(cache, c"x86 hang.w")): fail(c"hang.w's timeout was persisted")

	# 3) 'wtest why' on a failed root, in a FRESH process: the story (the
	# recorded stderr included) comes off the cache, not run memory.
	r = wtest_run(av(c"why", c"bad1.w"), 0)
	if (r.status != 0): fail(c"wtest why exited nonzero")
	char* why = r.stdout_text
	if (has_line(why, c"wtest: why root 'x86 bad1.w'") == 0): fail(c"why: no header")
	if (has_line(why, c"root file: present") == 0): fail(c"why: no root-file line")
	if (has_line(why, c"compile root of: bad1_t") == 0): fail(c"why: no owning target")
	if (has_line(why, c"cache: failure entry (the last 'bin/wv2 deps' run exited nonzero)") == 0):
		fail(c"why: no failure-entry line")
	if (has_line(why, c"  root content: unchanged since the failure") == 0):
		fail(c"why: no root-content line")
	if (has_line(why, c"  missing import: gen/missing1.w (still absent)") == 0):
		fail(c"why: no missing-import line")
	if (has_line(why, c"  deps stderr: bad1.w:2:1: error: cannot locate 'gen/missing1.w'") == 0):
		fail(c"why: no recorded stderr")
	if (has_line(why, c"  status: valid -- rule (b) is disabled for this root; its targets select via literal/residue rules only") == 0):
		fail(c"why: no status verdict")
	if (has_line(why, c"closure: unavailable (the cached failure above still holds)") == 0):
		fail(c"why: no closure line")
	if (has_line(why, c"  bad1_t (literal step reference)") == 0):
		fail(c"why: selection attribution missing")

	# 4) The missing import appearing flips the story: the cache entry
	# reads stale, the live re-run succeeds and warms the cache, and the
	# selection attribution switches to closure + literal.
	mkdir(sc_path(c"gen"), 493)
	sc_write(c"gen/missing1.w", c"int missing1 = 1\n")
	r = wtest_run(av(c"why", c"bad1.w"), 0)
	if (r.status != 0): fail(c"wtest why (recovered) exited nonzero")
	why = r.stdout_text
	if (contains(why, c"missing import: gen/missing1.w (now present -> retried on the next selection)") == 0):
		fail(c"why: missing-import reappearance not reported")
	if (has_line(why, c"  status: stale -- 'bin/wv2 deps' re-runs on the next selection") == 0):
		fail(c"why: stale verdict missing")
	if (has_line(why, c"closure: computed now (3 files; cache updated)") == 0):
		fail(c"why: live recompute missing")
	if (has_line(why, c"  bad1_t (closure of root 'x86 bad1.w'; literal step reference)") == 0):
		fail(c"why: closure attribution missing after recovery")
	if (has_line(sc_read(c"bin/.wtest_deps_cache"), c"R x86 bad1.w") == 0):
		fail(c"why's live recompute did not warm the cache")

	# 5) 'why' on a timed-out root: never cached, so the story is "no
	# entry" plus the live run's timeout marker -- and still no cache
	# entry afterwards.
	r = wtest_run(av(c"why", c"hang.w"), 0)
	if (r.status != 0): fail(c"wtest why hang.w exited nonzero")
	why = r.stdout_text
	if (has_line_prefix(why, c"cache: no entry for this root") == 0):
		fail(c"why: hang.w cache line wrong")
	if (has_line(why, c"closure: unavailable -- live 'bin/wv2 deps' run failed: timed out twice (budget 400ms; timeouts are never cached)") == 0):
		fail(c"why: timeout marker missing")
	if (contains(sc_read(c"bin/.wtest_deps_cache"), c"x86 hang.w")):
		fail(c"why persisted a timeout")

	# 6) An arch-prefixed root id, and the usage line documenting 'why'.
	r = wtest_run(av(c"why", c"x64", c"ok.w"), 0)
	if (r.status != 0): fail(c"wtest why x64 exited nonzero")
	why = r.stdout_text
	if (has_line(why, c"wtest: why root 'x64 ok.w'") == 0): fail(c"why: arch-prefixed header wrong")
	if (has_line(why, c"compile root of: no target in this manifest compiles this (arch, file) pair -- rule (b) never consults it") == 0):
		fail(c"why: unknown-pair line missing")
	r = wtest_run(av(c"why"), 0)
	if (r.status == 0): fail(c"bare 'wtest why' succeeded")
	if (contains(r.stderr_text, c"wtest why [<arch>] <file.w> [-f manifest.json]") == 0):
		fail(c"usage does not document 'wtest why'")

	return sc_ok()
