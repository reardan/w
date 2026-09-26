# wbuild: target=wtest_cache_test tag=tests dep=wtest data=tests/wtest/cache_scratch_e2e.w
# wbuild: step="bin/wv2 tests/wtest/cache_scratch_e2e.w -o bin/wtest_cache_e2e"
# wbuild: step="bin/wtest_cache_e2e" expect_stdout="wtest_cache_scratch_test: OK"
/*
'wtest cache' pre-warm + cold-run progress/ETA fixture
(tools/test_map.w; docs/projects/ai_tooling_next_steps.md 2026-07-29:
cold bin/.wtest_deps_cache builds exceeded 20 minutes wall under
parallel load -- './wbuild wtest_cache' pays that cost deliberately,
and the cold progress lines carry an extrapolated time-left
estimate). A fake bin/wv2 keeps the fixture's deps runs instant; 22
compile roots (+ the "x86 w.w" seed root wtest cache always warms)
cross the 20-root progress-line threshold so the ETA line is
observable.

Replaced tests/wtest/cache_scratch_test.sh (issue #323: no shell
scripts). The scratch checkout is a pid-scoped directory under bin/;
the fake bin/wv2 is a tiny W program this driver writes into it and
compiles with the real bin/wv2, and every child is spawned through
lib/process.w with an argv vector -- no /bin/sh.
*/
import lib.lib
import tools.wtest_scratch


# grep -c .: the number of non-empty lines.
int wc_count_nonempty(char* text):
	if (text == 0): return 0
	int count = 0
	for char* piece in split(text, 10):
		if (piece[0] != 0): count = count + 1
	return count


# The fake compiler: 'bin/wv2 deps <root>' logs the root to calls.log
# and prints the closure "<root>" + "dep.w".
char* wc_fake_wv2_source():
	string_builder* sb = string_new()
	sc_src(sb, 0, c"import lib.lib")
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
	sc_src(sb, 1, c"println(root)")
	sc_src(sb, 1, c"println(c\"dep.w\")")
	sc_src(sb, 1, c"return 0")
	return sb.data


int main(int argc, char** argv):
	sc_init(c"wtest_cache_scratch_test", c"wtest_cache_scratch_")
	sc_require(c"bin/wtest")
	sc_mkdir(c"bin")
	sc_link(c"bin/wtest", c"bin/wtest")

	sc_write(c"w.w", c"int main():\n\treturn 0\n")
	sc_write(c"dep.w", c"int dep = 1\n")

	# 22 conventional compile targets r01_t..r22_t rooted at r01.w..r22.w;
	# every fake closure contains dep.w, so one changed path selects
	# through all of them.
	string_builder* manifest = string_new()
	string_append(manifest, c"{\n\t\"targets\": [\n")
	for i in range(1, 22 + 1):
		char* name = strjoin(c"r", itoa(i))
		if (i < 10): name = strjoin(c"r0", itoa(i))
		string_append(manifest, c"\t\t{\"name\": \"")
		string_append(manifest, name)
		string_append(manifest, c"_t\", \"steps\": [{\"cmd\": [\"bin/wv2\", \"")
		string_append(manifest, name)
		string_append(manifest, c".w\", \"-o\", \"bin/")
		string_append(manifest, name)
		string_append(manifest, c"\"]}]}")
		if (i < 22): string_append(manifest, c",")
		string_append(manifest, c"\n")
		sc_write(strjoin(name, c".w"), c"import dep\n")
	string_append(manifest, c"\t]\n}\n")
	sc_write(c"build.json", manifest.data)

	# 0) No bin/wv2: warming is impossible and must say so, loudly.
	process_result* r = wtest_run(av(c"cache"), 0)
	if (r.status == 0): fail(c"wtest cache succeeded without bin/wv2")
	if (contains(r.stderr_text, c"wtest: error: cannot warm the deps cache: bin/wv2 not found") == 0):
		fail(c"no bin/wv2-missing error")

	# A bad argument is a usage error, and the usage names the subcommand.
	r = wtest_run(av(c"cache", c"bogus"), 0)
	if (r.status == 0): fail(c"unexpected 'wtest cache' argument accepted")
	if (contains(r.stderr_text, c"wtest cache [-f manifest.json]") == 0):
		fail(c"usage does not document 'wtest cache'")

	sc_install_fake_wv2(wc_fake_wv2_source())

	# 1) Cold pre-warm: banner + a 20/23 progress line with the elapsed /
	# time-left estimate on stderr, a summary on stdout, one deps run per
	# root (22 compile roots + the seed root).
	r = wtest_run(av(c"cache"), 0)
	if (r.status != 0): fail(c"cold wtest cache failed")
	if (contains(r.stdout_text, c"wtest: deps cache ready (23 roots)") == 0):
		fail(c"no ready summary on stdout")
	if (contains(r.stderr_text, c"wtest: building import-closure cache, 23 roots to compute") == 0):
		fail(c"no cold banner")
	if (contains(r.stderr_text, c"wtest: import-closure cache: 20/23 roots computed, ") == 0):
		fail(c"no progress line")
	if (contains(r.stderr_text, c"s elapsed, ~") == 0):
		fail(c"no elapsed time on the progress line")
	if (contains(r.stderr_text, c" left") == 0): fail(c"no time-left estimate on the progress line")
	int calls = wc_count_nonempty(sc_read(c"calls.log"))
	if (calls != 23): fail(strjoin(c"expected 23 deps runs, got ", itoa(calls)))
	char* cache = sc_read(c"bin/.wtest_deps_cache")
	if (count_line(cache, c"R x86 w.w") == 0): fail(c"seed root not warmed")
	if (count_line(cache, c"R x86 r22.w") == 0): fail(c"compile root not warmed")

	# 2) Warm rerun: revalidates, computes nothing, same summary.
	sc_write(c"calls.log", c"")
	r = wtest_run(av(c"cache"), 0)
	if (r.status != 0): fail(c"warm wtest cache failed")
	if (contains(r.stdout_text, c"wtest: deps cache ready (23 roots)") == 0):
		fail(c"warm rerun lost the summary")
	if (contains(r.stderr_text, c"building import-closure cache")): fail(c"warm rerun went cold")
	char* log = sc_read(c"calls.log")
	if ((log != 0) && (log[0] != 0)): fail(c"warm rerun ran bin/wv2 deps")

	# 3) A selection after the pre-warm is warm: no banner, no deps runs,
	# closure selection intact (including through the pre-warmed seed
	# root, which 'wtest changed' consults for every .w path).
	r = wtest_run(av(c"changed", c"dep.w"), 0)
	if (contains(r.stderr_text, c"building import-closure cache")):
		fail(c"changed run after pre-warm went cold")
	log = sc_read(c"calls.log")
	if ((log != 0) && (log[0] != 0)): fail(c"changed run after pre-warm ran bin/wv2 deps")
	if (count_line(r.stdout_text, c"r01_t") == 0):
		fail(c"closure selection missing r01_t after pre-warm")
	if (count_line(r.stdout_text, c"r22_t") == 0):
		fail(c"closure selection missing r22_t after pre-warm")

	return sc_ok()
