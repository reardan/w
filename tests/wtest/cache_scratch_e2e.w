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
import lib.process
import lib.path
import lib.file
import lib.str
import structures.string


char* wc_root_dir
char* wc_dir
char* wc_wtest


void wc_rm_rf(char* path):
	char** argv = strv_new(3)
	strv_set(argv, 0, c"/bin/rm")
	strv_set(argv, 1, c"-rf")
	strv_set(argv, 2, path)
	process_result* r = process_run(c"/bin/rm", argv, 0, 0, 60000)
	if (r != 0):
		process_result_free(r)
	free(cast(char*, argv))


void wc_err(char* msg):
	write(2, msg, strlen(msg))


void wc_fail(char* msg):
	wc_err(c"wtest_cache_scratch_test: FAIL: ")
	wc_err(msg)
	wc_err(c"\n")
	if (wc_dir != 0):
		wc_rm_rf(wc_dir)
	exit(1)


int wc_eq(char* a, char* b):
	int i = 0
	while ((a[i] != 0) && (a[i] == b[i])):
		i = i + 1
	return a[i] == b[i]


int wc_has(char* text, char* needle):
	if (text == 0):
		return 0
	return index_of(text, needle) >= 0


# grep -cx line: the number of lines exactly equal to line.
int wc_count_line(char* text, char* line):
	if (text == 0):
		return 0
	int count = 0
	for char* piece in split(text, 10):
		if (wc_eq(piece, line)):
			count = count + 1
	return count


# grep -c .: the number of non-empty lines.
int wc_count_nonempty(char* text):
	if (text == 0):
		return 0
	int count = 0
	for char* piece in split(text, 10):
		if (piece[0] != 0):
			count = count + 1
	return count


char* wc_path(char* rel):
	return path_join(wc_dir, rel)


char* wc_read(char* rel):
	return file_read_text(wc_path(rel))


void wc_write(char* rel, char* text):
	if (file_write_text(wc_path(rel), text) == 0):
		wc_fail(strjoin(c"cannot write ", rel))


# One 'bin/wtest <a1> [<a2>]' run in the scratch checkout (a2 may be 0).
process_result* wc_wtest_run(char* a1, char* a2):
	char** argv = strv_new(3)
	strv_set(argv, 0, c"bin/wtest")
	strv_set(argv, 1, a1)
	if (a2 != 0):
		strv_set(argv, 2, a2)
	spawn_options* opts = spawn_options_new()
	opts.cwd = wc_dir
	process_result* r = process_run(wc_path(c"bin/wtest"), argv, opts, 0, 600000)
	if (r == 0):
		wc_fail(c"could not spawn bin/wtest")
	return r


void wc_src(string_builder* sb, int tabs, char* line):
	int i = 0
	while (i < tabs):
		string_append(sb, c"\t")
		i = i + 1
	string_append(sb, line)
	string_append(sb, c"\n")


# The fake compiler: 'bin/wv2 deps <root>' logs the root to calls.log
# and prints the closure "<root>" + "dep.w".
char* wc_fake_wv2_source():
	string_builder* sb = string_new()
	wc_src(sb, 0, c"import lib.lib")
	wc_src(sb, 0, c"")
	wc_src(sb, 0, c"")
	wc_src(sb, 0, c"int main(int argc, char** argv):")
	wc_src(sb, 1, c"char* nl = malloc(1)")
	wc_src(sb, 1, c"nl[0] = 10")
	wc_src(sb, 1, c"char* root = argv[2]")
	wc_src(sb, 1, c"int fd = open(c\"calls.log\", 1089, 420)")
	wc_src(sb, 1, c"if (fd >= 0):")
	wc_src(sb, 2, c"write(fd, root, strlen(root))")
	wc_src(sb, 2, c"write(fd, nl, 1)")
	wc_src(sb, 2, c"close(fd)")
	wc_src(sb, 1, c"println(root)")
	wc_src(sb, 1, c"println(c\"dep.w\")")
	wc_src(sb, 1, c"return 0")
	return sb.data


void wc_install_fake_wv2():
	wc_write(c"fake_wv2.w", wc_fake_wv2_source())
	char* compiler = path_join(wc_root_dir, c"bin/wv2")
	char** argv = strv_new(4)
	strv_set(argv, 0, compiler)
	strv_set(argv, 1, wc_path(c"fake_wv2.w"))
	strv_set(argv, 2, c"-o")
	strv_set(argv, 3, wc_path(c"bin/wv2"))
	spawn_options* opts = spawn_options_new()
	opts.cwd = wc_root_dir
	process_result* r = process_run(compiler, argv, opts, 0, 600000)
	if (r == 0):
		wc_fail(c"could not spawn bin/wv2 for the fake compiler")
	if (r.status != 0):
		wc_err(r.stderr_text)
		wc_fail(c"fake bin/wv2 did not compile")
	process_result_free(r)


int main(int argc, char** argv):
	char* cwd = malloc(4096)
	if (getcwd(cwd, 4096) <= 0):
		wc_fail(c"getcwd failed")
	wc_root_dir = cwd
	wc_wtest = path_join(wc_root_dir, c"bin/wtest")
	if (path_exists(wc_wtest) == 0):
		wc_fail(c"bin/wtest must be built first")

	wc_dir = path_join(wc_root_dir, strjoin(c"bin/wtest_cache_scratch_", itoa(getpid())))
	wc_rm_rf(wc_dir)
	mkdir(wc_dir, 493)
	mkdir(wc_path(c"bin"), 493)
	if (symlink(wc_wtest, wc_path(c"bin/wtest")) < 0):
		wc_fail(c"cannot symlink bin/wtest into the scratch checkout")

	wc_write(c"w.w", c"int main():\n\treturn 0\n")
	wc_write(c"dep.w", c"int dep = 1\n")

	# 22 conventional compile targets r01_t..r22_t rooted at r01.w..r22.w;
	# every fake closure contains dep.w, so one changed path selects
	# through all of them.
	string_builder* manifest = string_new()
	string_append(manifest, c"{\n\t\"targets\": [\n")
	int i = 1
	while (i <= 22):
		char* name = strjoin(c"r", itoa(i))
		if (i < 10):
			name = strjoin(c"r0", itoa(i))
		string_append(manifest, c"\t\t{\"name\": \"")
		string_append(manifest, name)
		string_append(manifest, c"_t\", \"steps\": [{\"cmd\": [\"bin/wv2\", \"")
		string_append(manifest, name)
		string_append(manifest, c".w\", \"-o\", \"bin/")
		string_append(manifest, name)
		string_append(manifest, c"\"]}]}")
		if (i < 22):
			string_append(manifest, c",")
		string_append(manifest, c"\n")
		wc_write(strjoin(name, c".w"), c"import dep\n")
		i = i + 1
	string_append(manifest, c"\t]\n}\n")
	wc_write(c"build.json", manifest.data)

	# 0) No bin/wv2: warming is impossible and must say so, loudly.
	process_result* r = wc_wtest_run(c"cache", 0)
	if (r.status == 0):
		wc_fail(c"wtest cache succeeded without bin/wv2")
	if (wc_has(r.stderr_text, c"wtest: error: cannot warm the deps cache: bin/wv2 not found") == 0):
		wc_fail(c"no bin/wv2-missing error")

	# A bad argument is a usage error, and the usage names the subcommand.
	r = wc_wtest_run(c"cache", c"bogus")
	if (r.status == 0):
		wc_fail(c"unexpected 'wtest cache' argument accepted")
	if (wc_has(r.stderr_text, c"wtest cache [-f manifest.json]") == 0):
		wc_fail(c"usage does not document 'wtest cache'")

	wc_install_fake_wv2()

	# 1) Cold pre-warm: banner + a 20/23 progress line with the elapsed /
	# time-left estimate on stderr, a summary on stdout, one deps run per
	# root (22 compile roots + the seed root).
	r = wc_wtest_run(c"cache", 0)
	if (r.status != 0):
		wc_fail(c"cold wtest cache failed")
	if (wc_has(r.stdout_text, c"wtest: deps cache ready (23 roots)") == 0):
		wc_fail(c"no ready summary on stdout")
	if (wc_has(r.stderr_text, c"wtest: building import-closure cache, 23 roots to compute") == 0):
		wc_fail(c"no cold banner")
	if (wc_has(r.stderr_text, c"wtest: import-closure cache: 20/23 roots computed, ") == 0):
		wc_fail(c"no progress line")
	if (wc_has(r.stderr_text, c"s elapsed, ~") == 0):
		wc_fail(c"no elapsed time on the progress line")
	if (wc_has(r.stderr_text, c" left") == 0):
		wc_fail(c"no time-left estimate on the progress line")
	int calls = wc_count_nonempty(wc_read(c"calls.log"))
	if (calls != 23):
		wc_fail(strjoin(c"expected 23 deps runs, got ", itoa(calls)))
	char* cache = wc_read(c"bin/.wtest_deps_cache")
	if (wc_count_line(cache, c"R x86 w.w") == 0):
		wc_fail(c"seed root not warmed")
	if (wc_count_line(cache, c"R x86 r22.w") == 0):
		wc_fail(c"compile root not warmed")

	# 2) Warm rerun: revalidates, computes nothing, same summary.
	wc_write(c"calls.log", c"")
	r = wc_wtest_run(c"cache", 0)
	if (r.status != 0):
		wc_fail(c"warm wtest cache failed")
	if (wc_has(r.stdout_text, c"wtest: deps cache ready (23 roots)") == 0):
		wc_fail(c"warm rerun lost the summary")
	if (wc_has(r.stderr_text, c"building import-closure cache")):
		wc_fail(c"warm rerun went cold")
	char* log = wc_read(c"calls.log")
	if ((log != 0) && (log[0] != 0)):
		wc_fail(c"warm rerun ran bin/wv2 deps")

	# 3) A selection after the pre-warm is warm: no banner, no deps runs,
	# closure selection intact (including through the pre-warmed seed
	# root, which 'wtest changed' consults for every .w path).
	r = wc_wtest_run(c"changed", c"dep.w")
	if (wc_has(r.stderr_text, c"building import-closure cache")):
		wc_fail(c"changed run after pre-warm went cold")
	log = wc_read(c"calls.log")
	if ((log != 0) && (log[0] != 0)):
		wc_fail(c"changed run after pre-warm ran bin/wv2 deps")
	if (wc_count_line(r.stdout_text, c"r01_t") == 0):
		wc_fail(c"closure selection missing r01_t after pre-warm")
	if (wc_count_line(r.stdout_text, c"r22_t") == 0):
		wc_fail(c"closure selection missing r22_t after pre-warm")

	wc_rm_rf(wc_dir)
	println(c"wtest_cache_scratch_test: OK")
	return 0
