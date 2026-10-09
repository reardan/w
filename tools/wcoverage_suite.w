/*
wcoverage suite: statement coverage of the compiler, the REPL and wdbg
under a whole test run (docs/projects/line_coverage.md, "Compiler
coverage"; ./wbuild compiler_coverage).

Usage: wcoverage suite [--out <dir>] [--baseline <file>] [--prefix <p>]...
                       [--no-run] [<target>...]

1. Builds --coverage x86 and x64 copies of the compiler (w.w), the REPL
   (repl.w) and wdbg (debugger/debugger.w) into <dir> (default
   bin/coverage) with bin/wv2.
2. Runs 'bin/wexec --no-cache --keep-going <target>...' (default: tests)
   with $W_COVERAGE_COMPILER[_64], $W_COVERAGE_REPL[_64],
   $W_COVERAGE_WDBG[_64] and $W_COVERAGE_OUT set, so every compiler,
   REPL and debugger process the run starts -- manifest steps, wfixture,
   and the compilers tests spawn themselves -- re-executes as the
   instrumented build (compiler/coverage_exec.w) and appends its counters
   to <dir>/<tag>_<arch>/<pid>.raw. --no-run reuses the dumps of an
   earlier run (to re-render reports or retry a baseline).
3. Merges every map with its dumps and writes, under <dir>:
     summary.txt               per top-level directory
     files.txt                 per file
     functions_uncovered.txt   functions no run entered
     lines_uncovered.txt       executable lines no run reached
     diagnostics.txt           error/warning call sites and hit/miss
     lcov.info                 lcov tracefile (genhtml, Codecov, editors)
     coverage.json             one JSON object per file
   and prints summary.txt. The default selection is the compiler-side
   tree (--prefix replaces it): the lib/ and structures/ lines in these
   maps are only what the compiler itself imports, so they are not a
   measure of the library's tests (plain 'wcoverage' covers those).
4. --baseline <file> checks '<prefix> <percent>' floors against the
   merged result (tools/coverage_baseline.txt) and exits 1 on a drop.

A test that fails under the instrumented builds still contributes the
counters it flushed; the run's failures are reported, not fatal.
*/
import lib.lib
import lib.args
import lib.dir
import lib.env
import lib.file
import lib.path
import lib.process
import tools.wcoverage_lines


struct wcov_suite_build:
	char* source     # the program's root source
	char* tag        # dump subdirectory stem, as coverage_exec_redirect names it
	char* variable   # the environment variable its uninstrumented builds read
	char* binary     # <dir>/<tag>_<arch>_cov
	char* dumps      # <dir>/<tag>_<arch>
	int x64


void wcov_suite_fail(char* detail):
	print2(c"wcoverage suite: ")
	println2(detail)
	exit(2)


int wcov_suite_spawn(char** argv, char** env):
	spawn_options* opts = spawn_options_new()
	opts.env = env
	process* child = process_spawn(argv[0], argv, opts)
	if (child == 0): return 127
	int status = process_wait(child)
	process_free(child)
	return status


list[wcov_suite_build*] wcov_suite_builds(char* out):
	list[wcov_suite_build*] builds = new list[wcov_suite_build*]
	list[char*] sources = new list[char*]
	sources.push(c"w.w")
	sources.push(c"repl.w")
	sources.push(c"debugger/debugger.w")
	list[char*] tags = new list[char*]
	tags.push(c"compiler")
	tags.push(c"repl")
	tags.push(c"wdbg")
	list[char*] variables = new list[char*]
	variables.push(c"W_COVERAGE_COMPILER")
	variables.push(c"W_COVERAGE_REPL")
	variables.push(c"W_COVERAGE_WDBG")
	for i in range(sources.length):
		for x64 in range(2):
			wcov_suite_build* b = new wcov_suite_build()
			b.source = sources[i]
			b.tag = tags[i]
			b.x64 = x64
			char* arch = c"x86"
			b.variable = variables[i]
			if (x64):
				arch = c"x64"
				b.variable = strjoin(variables[i], c"_64")
			b.dumps = f"{out}/{tags[i]}_{arch}"
			b.binary = f"{out}/{tags[i]}_{arch}_cov"
			builds.push(b)
	return builds


void wcov_suite_build_all(list[wcov_suite_build*] builds):
	for wcov_suite_build* b in builds:
		list[char*] argv = new list[char*]
		argv.push(c"bin/wv2")
		if (b.x64): argv.push(c"x64")
		argv.push(c"--coverage")
		argv.push(b.source)
		argv.push(c"-o")
		argv.push(b.binary)
		char** v = strv_new(argv.length)
		for i in range(argv.length): strv_set(v, i, argv[i])
		println2(f"wcoverage suite: building {b.binary}")
		if (wcov_suite_spawn(v, 0) != 0): wcov_suite_fail(f"could not build {b.binary}")


# Run report() with stdout sent to <out>/<name>.
int wcov_suite_write(char* out, char* name, wcov_state* st, wcov_options* opt):
	char* path = f"{out}/{name}"
	int fd = open(path, 577, 420)
	if (fd < 0): wcov_suite_fail(f"cannot write {path}")
	dup2(1, 63)
	dup2(fd, 1)
	close(fd)
	int status = wcov_report(st, opt)
	dup2(63, 1)
	close(63)
	return status


int wcov_suite_main():
	char* out = c"bin/coverage"
	char* baseline = 0
	int run = 1
	list[char*] prefixes = new list[char*]
	list[char*] targets = new list[char*]
	int i = 2
	while (i < args_count()):
		char* a = args_get(i)
		int has_next = i + 1 < args_count()
		if ((strcmp(a, c"--out") == 0) && has_next):
			i = i + 1
			out = args_get(i)
		elif ((strcmp(a, c"--baseline") == 0) && has_next):
			i = i + 1
			baseline = args_get(i)
		elif ((strcmp(a, c"--prefix") == 0) && has_next):
			i = i + 1
			prefixes.push(args_get(i))
		elif (strcmp(a, c"--no-run") == 0): run = 0
		elif (a[0] == '-'): wcov_suite_fail(c"usage: wcoverage suite [--out <dir>] [--baseline <file>] [--prefix <p>]... [--no-run] [<target>...]")
		else: targets.push(a)
		i = i + 1
	if (targets.length == 0): targets.push(c"tests")
	if (prefixes.length == 0):
		prefixes.push(c"compiler/")
		prefixes.push(c"grammar/")
		prefixes.push(c"code_generator/")
		prefixes.push(c"repl/")
		prefixes.push(c"repl.w")
		prefixes.push(c"debugger/")
		prefixes.push(c"w.w")
		prefixes.push(c"grammar.w")
		prefixes.push(c"codegen.w")

	# Absolute paths: tests run from scratch directories of their own.
	if (out[0] != '/'):
		char* cwd = cast(char*, malloc(4096))
		if (getcwd(cwd, 4096) < 0): wcov_suite_fail(c"getcwd failed")
		out = path_join(cwd, out)
	mkdir(out, 493)
	list[wcov_suite_build*] builds = wcov_suite_builds(out)

	if (run):
		for wcov_suite_build* b in builds:
			dir_remove_all(b.dumps)
			mkdir(b.dumps, 493)
		wcov_suite_build_all(builds)
		char** env = env_copy_with(env_current(), c"W_COVERAGE_OUT", out)
		for wcov_suite_build* b in builds: env = env_copy_with(env, b.variable, b.binary)
		# The run rebuilds bin/wexec and bin/wcoverage (--no-cache), so
		# drive it from a copy; ./wbuild compiler_coverage runs this
		# tool from a copy too.
		char* wexec = f"{out}/wexec"
		char** cp = strv_new(3)
		strv_set(cp, 0, c"/bin/cp")
		strv_set(cp, 1, c"bin/wexec")
		strv_set(cp, 2, wexec)
		if (wcov_suite_spawn(cp, 0) != 0): wcov_suite_fail(c"cannot copy bin/wexec")
		char** argv = strv_new(3 + targets.length)
		strv_set(argv, 0, wexec)
		strv_set(argv, 1, c"--no-cache")
		strv_set(argv, 2, c"--keep-going")
		for k in range(targets.length): strv_set(argv, 3 + k, targets[k])
		println2(f"wcoverage suite: running {join(targets, c" ")} under the instrumented builds")
		int status = wcov_suite_spawn(argv, env)
		if (status != 0): println2(f"wcoverage suite: warning: the test run exited {status}; its counters are still merged")

	wcov_state* st = wcov_state_new()
	int loaded = 0
	for wcov_suite_build* b in builds:
		char* map_path = strjoin(b.binary, c".wprofmap")
		list[char*] names = dir_names(b.dumps)
		if ((names == 0) || (names.length == 0) || (path_exists(map_path) == 0)):
			println2(f"wcoverage suite: no runs of {b.binary}")
			continue
		wcov_line_map(st, map_path)
		wcov_dump_arg(st, b.dumps)
		println2(f"wcoverage suite: merged {names.length} dumps of {b.binary}")
		loaded = loaded + 1
	if (loaded == 0): wcov_suite_fail(c"no instrumented runs to report")

	wcov_options* opt = wcov_options_new()
	for char* p in prefixes: opt.prefixes.push(p)
	opt.summary = c"dir"
	wcov_suite_write(out, c"summary.txt", st, opt)
	opt.summary = c"file"
	wcov_suite_write(out, c"files.txt", st, opt)
	opt.summary = c"function"
	opt.uncovered_only = 1
	wcov_suite_write(out, c"functions_uncovered.txt", st, opt)
	opt.summary = 0
	wcov_suite_write(out, c"lines_uncovered.txt", st, opt)
	opt.uncovered_only = 0
	opt.diagnostics = 1
	wcov_suite_write(out, c"diagnostics.txt", st, opt)
	opt.diagnostics = 0
	opt.format = c"lcov"
	wcov_suite_write(out, c"lcov.info", st, opt)
	opt.format = c"json"
	wcov_suite_write(out, c"coverage.json", st, opt)
	opt.format = c"text"
	opt.summary = c"dir"
	println(f"compiler coverage ({out}):")
	if (baseline != 0): opt.baseline = baseline
	return wcov_report(st, opt)
