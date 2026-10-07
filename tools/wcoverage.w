# wbuild: binary=wcoverage
# wbuild: target=wcoverage_report dep=wcoverage
# wbuild: step="bin/wcoverage"
# wbuild: target=wcoverage_test tag=tests dep=wcoverage
# wbuild: step="bin/wcoverage --roots tests/wcoverage/roots --modules tests/wcoverage/mods --harness tests/wcoverage/harness.w" expect_stdout="roots: 3 (1 did not compile, skipped)" expect_stdout="uncovered modules (2 of 6):" expect_stdout="  tests/wcoverage/mods/sub/deep_unused.w" expect_stdout="  tests/wcoverage/mods/unused.w" expect_stdout="reached only through the test harness (1 of 6):" expect_stdout="  tests/wcoverage/mods/harness_only.w" expect_stdout="module coverage: 3/6 (50%)" reject_stdout="mods/used.w" reject_stdout="mods/used_e2e.w" reject_stdout="__arch__" reject_stdout="harness_direct"
# wbuild: step="bin/wcoverage -j 1 --roots tests/wcoverage/roots --modules tests/wcoverage/mods --harness tests/wcoverage/harness.w --covered" expect_stdout="covered modules (3 of 6):" expect_stdout="  tests/wcoverage/mods/harness_direct.w" expect_stdout="  tests/wcoverage/mods/used.w" expect_stdout="  tests/wcoverage/mods/used_by_used.w"
# wbuild: step="bin/wcoverage --roots tests/wcoverage/roots --modules tests/wcoverage/mods --harness none" expect_stdout="uncovered modules (2 of 6):" expect_stdout="module coverage: 4/6 (66%)" reject_stdout="reached only through"
# wbuild: step="bin/wcoverage --modules tests/wcoverage/no_such_dir" expect_fail expect_stderr="wcoverage: no modules under"
/*
wcoverage: module-level test coverage (issue #538). Lists the library
modules that no test program imports, directly or transitively.

Usage: wcoverage [-j N] [--compiler <wv2>] [--roots <dir>]...
                 [--modules <dir>]... [--harness <file>|none] [--covered]

Roots are the test programs. By default: every .w file under tests/
(tests, fixtures and the helper programs test steps run) plus every
*_test.w and *_e2e.w under lib/, structures/, graphics/, libs/ and
tools/ -- the sources the generated manifest builds and runs as tests.
--roots <dir> (repeatable) replaces that set with every .w file under
the given directories.

Modules are the files being measured. By default every .w file under
lib/ and structures/, minus *_test.w files and the per-target
__arch__/ trees (a root's closure is computed for the default 32-bit
target only, so the other targets' __arch__ files would all read as
uncovered). --modules <dir> (repeatable) replaces the set.

Each root's closure comes from '<compiler> deps <root>' (default
bin/wv2), run -j N at a time (default 4). A root that does not compile
for the default target is retried with the x64 selector (the
arch_only=x64 sources); one that compiles for neither (diagnostic
fixtures, arm64/wasm-only sources) contributes nothing and is counted
as skipped. A module is covered when some root's closure
contains it; the report lists the uncovered ones and the ratio
(--covered lists the covered ones too).

The test harness is the exception. Every test imports lib/testing.w,
whose own closure (lib/format.w, lib/float_text.w, lib/crash.w, ...)
would otherwise count as covered by every test in the tree. A module
in the harness's closure (--harness <file>, default lib/testing.w;
"none" disables this) counts as covered only when some root names it
in an import line of its own; otherwise it is listed separately as
"reached only through the test harness" and does not count. Modules
an empty program already pulls in (the auto-imported runtime) are
exempt: every program reaches them, harness or not.

This is static reachability, not execution coverage: a covered module
may still have functions no test calls. Line-level coverage needs the
compiler's help and is deferred (docs/testing.md, "Coverage").

Exit status: 0, or 2 on a usage error or an empty module set.
*/
import lib.lib
import lib.args
import lib.dir
import lib.file
import lib.path
import lib.process
import lib.str


char* wcov_compiler
int wcov_jobs


void wcov_fail(char* what, char* detail):
	print2(c"wcoverage: ")
	print2(what)
	println2(detail)
	exit(2)


int wcov_is_w(char* path):
	return ends_with(path, c".w")


int wcov_is_test_source(char* path):
	return ends_with(path, c"_test.w") || ends_with(path, c"_e2e.w")


# Every .w file under dir (depth-first name order) passing the filter:
# 0 = all, 1 = test sources only, 2 = modules (no tests, no __arch__).
void wcov_collect(char* dir, int filter, list[char*] out):
	list[char*] files = new list[char*]
	dir_walk_files(dir, files)
	for char* f in files:
		int keep = wcov_is_w(f)
		if (keep && (filter == 1)): keep = wcov_is_test_source(f)
		if (keep && (filter == 2)): keep = (wcov_is_test_source(f) == 0) && (contains(f, c"/__arch__/") == 0)
		if (keep): out.push(f)


# Adds the module path of every top-level "import a.b.c" line in the
# file at path to out ("a/b/c.w"), the imports a root names itself.
void wcov_direct_imports(char* path, set[char*] out):
	char* text = file_read_text(path)
	if (text == 0): return
	for char* line in split(text, '\x0a'):
		if (starts_with(line, c"import ")):
			int i = 7
			while (line[i] == ' '): i = i + 1
			int start = i
			while ((line[i] != 0) && (line[i] != ' ') && (line[i] != '\x09') && (line[i] != '\x0d')): i = i + 1
			char* dotted = substring(line, start, i)
			char* rel = strjoin(replace(dotted, c".", c"/"), c".w")
			if ((rel in out) == 0): out.add(rel)
	free(text)


# Reads everything left on fd (the child has exited, so this ends at
# EOF). A closure listing is a few KB, far below the pipe buffer, so a
# child never blocks on a full pipe before it is reaped.
char* wcov_read_fd(int fd):
	int cap = 8192
	int len = 0
	char* buf = cast(char*, malloc(cap))
	while (1):
		if (len + 4096 + 1 > cap):
			buf = realloc(buf, cap, cap * 2)
			cap = cap * 2
		int n = read(fd, &buf[len], 4096)
		if (n <= 0):
			buf[len] = 0
			return buf
		len = len + n


# arch is 0 for the default 32-bit target, or a selector word ("x64").
process* wcov_spawn(char* root, char* arch):
	char** argv = strv_new(4)
	strv_set(argv, 0, wcov_compiler)
	strv_set(argv, 1, c"deps")
	if (arch != 0):
		strv_set(argv, 2, arch)
		strv_set(argv, 3, root)
	else: strv_set(argv, 2, root)
	spawn_options* opts = spawn_options_new()
	opts.stdout_mode = process_pipe
	opts.stderr_mode = process_null
	process* p = process_spawn(wcov_compiler, argv, opts)
	free(opts)
	free(cast(char*, argv))
	if (p == 0): wcov_fail(c"cannot run ", wcov_compiler)
	return p


# Adds every path a finished deps child printed to seen. Returns 1 when
# the root compiled.
int wcov_harvest(process* p, set[char*] seen):
	char* text = wcov_read_fd(p.stdout_fd)
	int ok = process_decode_status(p.status) == 0
	if (ok):
		list[char*] lines = split(text, '\x0a')
		for char* line in lines:
			if ((line[0] != 0) && ((line in seen) == 0)): seen.add(line)
	free(text)
	process_free(p)
	return ok


# Runs deps over every root, wcov_jobs at a time; returns the number of
# roots that failed to compile. A root that fails for the default
# 32-bit target is retried once with the x64 selector: float64/int64
# sources (the arch_only=x64 tests) are rejected on 32-bit words.
int wcov_closures(list[char*] roots, set[char*] seen):
	int failed = 0
	list[char*] pending = new list[char*]
	list[int] pending_x64 = new list[int]
	for char* r in roots:
		pending.push(r)
		pending_x64.push(0)
	int next = 0
	list[process*] running = new list[process*]
	list[int] running_index = new list[int]
	while ((next < pending.length) || (running.length > 0)):
		while ((next < pending.length) && (running.length < wcov_jobs)):
			char* arch = 0
			if (pending_x64[next]): arch = c"x64"
			running.push(wcov_spawn(pending[next], arch))
			running_index.push(next)
			next = next + 1
		int i = process_wait_any(running, 1)
		if (i < 0): wcov_fail(c"waiting for deps failed", c"")
		process* done = running[i]
		int index = running_index[i]
		list_remove_at[process*](running, i)
		list_remove_at[int](running_index, i)
		if (wcov_harvest(done, seen) == 0):
			if (pending_x64[index]): failed = failed + 1
			else:
				pending.push(pending[index])
				pending_x64.push(1)
	return failed


void wcov_print_list(char* title, list[char*] paths, int total):
	print(title)
	print(c" (")
	print(itoa(paths.length))
	print(c" of ")
	print(itoa(total))
	println(c"):")
	for char* p in paths:
		print(c"  ")
		println(p)


int main(int argc, int argv):
	args_init(argc, argv)
	wcov_compiler = c"bin/wv2"
	wcov_jobs = 4
	int show_covered = 0
	char* harness = c"lib/testing.w"
	list[char*] root_dirs = new list[char*]
	list[char*] module_dirs = new list[char*]
	int i = 1
	while (i < args_count()):
		char* a = args_get(i)
		int has_next = i + 1 < args_count()
		if (strcmp(a, c"--covered") == 0): show_covered = 1
		elif ((strcmp(a, c"-j") == 0) && has_next):
			i = i + 1
			wcov_jobs = atoi(args_get(i))
			if (wcov_jobs < 1): wcov_jobs = 1
		elif ((strcmp(a, c"--compiler") == 0) && has_next):
			i = i + 1
			wcov_compiler = args_get(i)
		elif ((strcmp(a, c"--roots") == 0) && has_next):
			i = i + 1
			root_dirs.push(args_get(i))
		elif ((strcmp(a, c"--harness") == 0) && has_next):
			i = i + 1
			harness = args_get(i)
			if (strcmp(harness, c"none") == 0): harness = 0
		elif ((strcmp(a, c"--modules") == 0) && has_next):
			i = i + 1
			module_dirs.push(args_get(i))
		else:
			println2(c"usage: wcoverage [-j N] [--compiler <wv2>] [--roots <dir>]... [--modules <dir>]... [--harness <file>|none] [--covered]")
			return 2
		i = i + 1

	list[char*] roots = new list[char*]
	if (root_dirs.length == 0):
		wcov_collect(c"tests", 0, roots)
		wcov_collect(c"lib", 1, roots)
		wcov_collect(c"structures", 1, roots)
		wcov_collect(c"graphics", 1, roots)
		wcov_collect(c"libs", 1, roots)
		wcov_collect(c"tools", 1, roots)
	for char* d in root_dirs:
		wcov_collect(d, 0, roots)

	list[char*] modules = new list[char*]
	if (module_dirs.length == 0):
		module_dirs.push(c"lib")
		module_dirs.push(c"structures")
	for char* d in module_dirs:
		wcov_collect(d, 2, modules)
	if (modules.length == 0): wcov_fail(c"no modules under ", join(module_dirs, c", "))

	set[char*] seen = new set[char*]
	int failed = wcov_closures(roots, seen)

	set[char*] harness_closure = new set[char*]
	set[char*] direct = new set[char*]
	set[char*] runtime = new set[char*]
	if (harness != 0):
		list[char*] one = new list[char*]
		one.push(harness)
		if (wcov_closures(one, harness_closure) > 0): wcov_fail(c"the harness does not compile: ", harness)
		# The auto-imported runtime is in every program's closure, test
		# or not, so being reached through the harness says nothing extra
		# about it: measure it like any other module.
		char* empty = c"bin/wcoverage_empty.w"
		char* source = c"int main():\x0a\treturn 0\x0a"
		io_result wr
		if (file_write_text_checked(empty, source, strlen(source), &wr) != IO_OK): wcov_fail(c"cannot write ", empty)
		list[char*] bare = new list[char*]
		bare.push(empty)
		if (wcov_closures(bare, runtime) > 0): wcov_fail(c"an empty program does not compile: ", empty)
		for char* r in roots:
			wcov_direct_imports(r, direct)

	list[char*] covered = new list[char*]
	list[char*] harness_only = new list[char*]
	list[char*] uncovered = new list[char*]
	for char* m in modules:
		if ((m in seen) == 0): uncovered.push(m)
		elif ((m in harness_closure) && ((m in runtime) == 0) && ((m in direct) == 0)): harness_only.push(m)
		else: covered.push(m)

	print(c"roots: ")
	print(itoa(roots.length))
	print(c" (")
	print(itoa(failed))
	println(c" did not compile, skipped)")
	if (show_covered): wcov_print_list(c"covered modules", covered, modules.length)
	wcov_print_list(c"uncovered modules", uncovered, modules.length)
	if (harness_only.length > 0): wcov_print_list(c"reached only through the test harness", harness_only, modules.length)
	print(c"module coverage: ")
	print(itoa(covered.length))
	print(c"/")
	print(itoa(modules.length))
	print(c" (")
	print(itoa(covered.length * 100 / modules.length))
	println(c"%)")
	return 0
