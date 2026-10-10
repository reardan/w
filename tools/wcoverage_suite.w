/*
wcoverage suite: statement coverage of the compiler, the REPL and wdbg
under a whole test run (docs/projects/line_coverage.md, "Compiler
coverage"; ./wbuild compiler_coverage).

Usage: wcoverage suite [--out <dir>] [--baseline <file>] [--prefix <p>]...
                       [--no-run | --prepare-only | --skip-build] [--shard I/N]
                       [--merge-shards N] [<target>...]

1. Builds --coverage x86 and x64 copies of the compiler (w.w), the REPL
   (repl.w), shell (wsh.w), wdbg (debugger/debugger.w), and compiler API
   test harnesses into <dir> (default bin/coverage) with bin/wv2. The
   harnesses exercise owned-tree APIs ordinary subprocesses never call.
2. Runs 'bin/wexec --no-cache --keep-going <target>...' (default: tests)
   with $W_COVERAGE_COMPILER[_64], $W_COVERAGE_REPL[_64],
   $W_COVERAGE_WSH[_64], $W_COVERAGE_WDBG[_64] and $W_COVERAGE_OUT set, so
   every compiler, REPL, shell and debugger process the run starts --
   manifest steps, wfixture,
   and the compilers tests spawn themselves -- re-executes as the
   instrumented build (compiler/coverage_exec.w) and appends its counters
   to <dir>/.dumps/<tag>_<arch>/<pid>.raw. --no-run reuses the dumps of an
   earlier run (to re-render reports or retry a baseline).
   Then runs each API harness directly with its own W_PROFILE_OUT dump;
   harness failures fail the suite after the reports have been written.
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
counters it flushed; reports are retained, but failures are fatal.
*/
import lib.lib
import lib.args
import lib.dir
import lib.env
import lib.file
import lib.path
import lib.process
import lib.time
import tools.wcoverage_lines


struct wcov_suite_build:
	char* source     # the program's root source
	char* tag        # dump subdirectory stem, as coverage_exec_redirect names it
	char* variable   # the environment variable its uninstrumented builds read
	char* binary     # <dir>/<tag>_<arch>_cov
	char* dumps      # <dir>/.dumps/<tag>_<arch>
	int x64
	int harness      # direct test run, with no compiler redirect variable


char* wcov_suite_report_dir


void wcov_suite_fail(char* detail):
	if (wcov_suite_report_dir != 0): file_write_text(f"{wcov_suite_report_dir}/completeness.txt", f"INCOMPLETE: {detail}\n")
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
	sources.push(c"wsh.w")
	sources.push(c"debugger/debugger.w")
	sources.push(c"tests/tile_analysis_unit_test.w")
	sources.push(c"tests/tile_ast_test.w")
	sources.push(c"tests/ast_function_record_test.w")
	list[char*] tags = new list[char*]
	tags.push(c"compiler")
	tags.push(c"repl")
	tags.push(c"wsh")
	tags.push(c"wdbg")
	tags.push(c"tile_analysis_test")
	tags.push(c"tile_ast_test")
	tags.push(c"function_record_test")
	list[char*] variables = new list[char*]
	variables.push(c"W_COVERAGE_COMPILER")
	variables.push(c"W_COVERAGE_REPL")
	variables.push(c"W_COVERAGE_WSH")
	variables.push(c"W_COVERAGE_WDBG")
	variables.push(0)
	variables.push(0)
	variables.push(0)
	for i in range(sources.length):
		for x64 in range(2):
			wcov_suite_build* b = new wcov_suite_build()
			b.source = sources[i]
			b.tag = tags[i]
			b.x64 = x64
			char* arch = c"x86"
			b.variable = variables[i]
			b.harness = b.variable == 0
			if (x64):
				arch = c"x64"
				if (b.variable != 0): b.variable = strjoin(b.variable, c"_64")
			# Daemons ignore dot directories: per-counter dump writes must
			# not overflow their source-change inotify queues.
			b.dumps = f"{out}/.dumps/{tags[i]}_{arch}"
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


char** wcov_suite_env(char** base, char* dumps, list[wcov_suite_build*] builds):
	char** env = env_copy_with(base, c"W_COVERAGE_OUT", dumps)
	for wcov_suite_build* b in builds:
		if (b.variable != 0): env = env_copy_with(env, b.variable, b.binary)
	# Large differential tests spawn thousands of instrumented compilers.
	# Allow an hour per step for counter overhead, preserving caller overrides.
	char* timeout = 0
	for i in range(env_vector_count(base)):
		char* entry = env_entry_at(base, i)
		int offset = env_match_name(entry, c"WEXEC_STEP_TIMEOUT_MS")
		if (offset >= 0): timeout = entry + offset
	if ((timeout == 0) || (timeout[0] == 0)):
		env = env_copy_with(env, c"WEXEC_STEP_TIMEOUT_MS", c"3600000")
	return env


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


# Phase durations are independent of wexec's per-target timings.
void wcov_suite_timing(char* out, char* phase, int started):
	int elapsed = time_monotonic_ms() - started
	println2(f"wcoverage suite: {phase}: {elapsed} ms")
	int fd = open(f"{out}/phases.tsv", 1089, 420)
	if (fd < 0): wcov_suite_fail(c"cannot write phase timings")
	char* row = f"{phase}\t{elapsed}\n"
	if (write(fd, row, strlen(row)) != strlen(row)): wcov_suite_fail(c"cannot write phase timings")
	close(fd)


void wcov_suite_save(char* path, char* text):
	if (file_write_text(path, text) == 0): wcov_suite_fail(f"cannot write {path}")


# The completion receipt is written only after the executor returned. Its
# identity and target set must match; killed/missing shards cannot pass gates.
int wcov_suite_receipt(char* dir, char* identity, char* targets):
	list[char*] lines = file_read_lines(f"{dir}/run.status")
	if ((lines == 0) || (lines.length != 4)): wcov_suite_fail(f"missing or incomplete run: {dir}")
	if ((strcmp(lines[0], c"wcoverage suite v1") != 0) || (strcmp(lines[1], identity) != 0) || (strcmp(lines[2], targets) != 0)):
		wcov_suite_fail(f"run identity or targets do not match: {dir}")
	return wcov_small_decimal(lines[3])


# Maps travel inside each shard artifact, next to its namespaced PID dumps.
# Comparing them with preparation prevents accidental mixing of builds.
void wcov_suite_validate(char* dir, list[wcov_suite_build*] prepared):
	char* prepared_id = file_read_text(f"{wcov_suite_report_dir}/preparation.id")
	char* shard_id = file_read_text(f"{dir}/preparation.id")
	if ((prepared_id == 0) || (shard_id == 0)): wcov_suite_fail(f"missing preparation identity: {dir}")
	if (strcmp(prepared_id, shard_id) != 0): wcov_suite_fail(f"preparation identity does not match: {dir}")
	free(prepared_id)
	free(shard_id)
	list[wcov_suite_build*] builds = wcov_suite_builds(dir)
	for i in range(builds.length):
		wcov_suite_build* b = builds[i]
		char* map_path = strjoin(b.binary, c".wprofmap")
		char* expected = file_read_text(strjoin(prepared[i].binary, c".wprofmap"))
		char* actual = file_read_text(map_path)
		if ((expected == 0) || (actual == 0)): wcov_suite_fail(f"missing coverage map: {map_path}")
		if (strcmp(expected, actual) != 0): wcov_suite_fail(f"coverage map does not match preparation: {map_path}")
		free(expected)
		free(actual)
		list[char*] names = dir_names(b.dumps)
		if (names == 0): wcov_suite_fail(f"missing dump directory: {b.dumps}")


# One map per prepared binary, with all shards' counters accumulated into
# that map. Re-reading the large maps per shard wastes memory and time.
int wcov_suite_load(wcov_state* st, list[char*] dirs, list[wcov_suite_build*] builds):
	int loaded = 0
	for wcov_suite_build* b in builds:
		wcov_line_map(st, strjoin(b.binary, c".wprofmap"))
		char* arch = c"x86"
		if (b.x64): arch = c"x64"
		for char* dir in dirs:
			char* dumps = f"{dir}/.dumps/{b.tag}_{arch}"
			list[char*] names = dir_names(dumps)
			if (names == 0): wcov_suite_fail(f"missing dump directory: {dumps}")
			wcov_dump_arg(st, dumps)
			println2(f"wcoverage suite: merged {names.length} dumps from {dumps}")
			loaded = loaded + names.length
	return loaded



int wcov_suite_main():
	char* out = c"bin/coverage"
	char* baseline = 0
	int run = 1
	int prepare = 0
	int skip_build = 0
	int merge = 0
	char* shard = 0
	int shard_index = 0
	int shard_count = 0
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
		elif (strcmp(a, c"--prepare-only") == 0): prepare = 1
		elif (strcmp(a, c"--skip-build") == 0): skip_build = 1
		elif ((strcmp(a, c"--shard") == 0) && has_next):
			i = i + 1
			shard = args_get(i)
			list[char*] pair = split(shard, '/')
			if (pair.length != 2): wcov_suite_fail(c"--shard takes zero-based I/N")
			shard_index = wcov_small_decimal(pair[0])
			shard_count = wcov_small_decimal(pair[1])
			if ((shard_count == 0) || (shard_index >= shard_count)): wcov_suite_fail(c"--shard requires 0 <= I < N")
			shard = f"{shard_index}/{shard_count}"
		elif ((strcmp(a, c"--merge-shards") == 0) && has_next):
			i = i + 1
			merge = wcov_small_decimal(args_get(i))
			if (merge == 0): wcov_suite_fail(c"--merge-shards requires a positive count")
		elif (a[0] == '-'): wcov_suite_fail(c"usage: wcoverage suite [--out <dir>] [--baseline <file>] [--prefix <p>]... [--no-run | --prepare-only | --skip-build] [--shard I/N] [--merge-shards N] [<target>...]")
		else: targets.push(a)
		i = i + 1
	if (prepare && ((run == 0) || skip_build || (shard != 0) || merge)): wcov_suite_fail(c"--prepare-only cannot be combined with run or merge flags")
	if (merge && ((shard != 0) || prepare || skip_build)): wcov_suite_fail(c"--merge-shards cannot be combined with run flags")
	if (shard && ((run == 0) || (baseline != 0))): wcov_suite_fail(c"shards run tests only; apply baseline after --merge-shards")
	if (targets.length == 0): targets.push(c"tests")
	if (prefixes.length == 0):
		prefixes.push(c"compiler/")
		prefixes.push(c"grammar/")
		prefixes.push(c"code_generator/")
		prefixes.push(c"repl/")
		prefixes.push(c"repl.w")
		prefixes.push(c"wsh.w")
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
	wcov_suite_report_dir = out
	# A rejected or interrupted rerun must never publish an older report.
	for char* report in split(c"summary.txt files.txt functions_uncovered.txt lines_uncovered.txt diagnostics.txt lcov.info coverage.json", ' '):
		unlink(f"{out}/{report}")
	wcov_suite_save(f"{out}/completeness.txt", c"INCOMPLETE: command has not finished\n")
	list[wcov_suite_build*] builds = wcov_suite_builds(out)

	char* run_out = out
	char* identity = c"local"
	if (shard != 0):
		mkdir(f"{out}/shards", 493)
		run_out = f"{out}/shards/{shard_index}-of-{shard_count}"
		identity = shard
		mkdir(run_out, 493)
	char* target_set = join(targets, c" ")
	int failed = 0
	if (prepare || (run && (merge == 0))):
		unlink(f"{run_out}/run.status")
		unlink(f"{run_out}/phases.tsv")
		int started = time_monotonic_ms()
		if (skip_build == 0):
			wcov_suite_build_all(builds)
			wcov_suite_save(f"{out}/preparation.id", f"{time_now()}-{getpid()}\n")
		for wcov_suite_build* b in builds:
			if ((path_exists(b.binary) == 0) || (path_exists(strjoin(b.binary, c".wprofmap")) == 0)):
				wcov_suite_fail(f"missing prepared build: {b.binary}")
		wcov_suite_timing(run_out, c"prepare", started)
		if (prepare): return 0
		char* preparation_id = file_read_text(f"{out}/preparation.id")
		if (preparation_id == 0): wcov_suite_fail(c"missing preparation identity")
		if (shard != 0): wcov_suite_save(f"{run_out}/preparation.id", preparation_id)
		free(preparation_id)
		char* dumps = f"{run_out}/.dumps"
		mkdir(dumps, 493)
		list[wcov_suite_build*] run_builds = wcov_suite_builds(run_out)
		for k in range(builds.length):
			wcov_suite_build* b = run_builds[k]
			dir_remove_all(b.dumps)
			mkdir(b.dumps, 493)
			if (shard != 0):
				char* map_text = file_read_text(strjoin(builds[k].binary, c".wprofmap"))
				if (map_text == 0): wcov_suite_fail(c"cannot read prepared map")
				wcov_suite_save(strjoin(b.binary, c".wprofmap"), map_text)
				free(map_text)
		char** env = wcov_suite_env(env_current(), dumps, builds)
		# The no-cache run rebuilds wexec; execute an isolated copy.
		char* wexec = f"{run_out}/wexec"
		char** cp = strv_new(3)
		strv_set(cp, 0, c"/bin/cp")
		strv_set(cp, 1, c"bin/wexec")
		strv_set(cp, 2, wexec)
		if (wcov_suite_spawn(cp, 0) != 0): wcov_suite_fail(c"cannot copy bin/wexec")
		list[char*] command = new list[char*]
		command.push(wexec)
		command.push(c"--no-cache")
		command.push(c"--keep-going")
		command.push(c"--timings")
		command.push(f"{run_out}/targets.jsonl")
		if (shard != 0):
			command.push(c"--shard")
			command.push(shard)
		for char* target in targets: command.push(target)
		char** argv = strv_new(command.length)
		for k in range(command.length): strv_set(argv, k, command[k])
		println2(f"wcoverage suite: running {target_set} ({identity}) under the instrumented builds")
		started = time_monotonic_ms()
		failed = wcov_suite_spawn(argv, env)
		# Run the prepared API binaries in every shard. Their exact maps
		# travel with that shard, and failures must enter its receipt too.
		for k in range(builds.length):
			wcov_suite_build* b = builds[k]
			if (b.harness == 0): continue
			char** test_argv = strv_new(1)
			strv_set(test_argv, 0, b.binary)
			wcov_suite_build* destination = run_builds[k]
			char** test_env = env_copy_with(env, c"W_PROFILE_OUT", f"{destination.dumps}/harness.raw")
			println2(f"wcoverage suite: running compiler API harness {b.binary}")
			int test_status = wcov_suite_spawn(test_argv, test_env)
			if (test_status != 0):
				println2(f"wcoverage suite: compiler API harness {b.binary} failed: {test_status}")
				failed = 1
		wcov_suite_timing(run_out, c"tests", started)
		wcov_suite_save(f"{run_out}/run.status", f"wcoverage suite v1\n{identity}\n{target_set}\n{failed}\n")
		if (failed != 0): println2(f"wcoverage suite: test run exited {failed}; retaining counters and failing completeness")
		if (shard != 0):
			wcov_suite_save(f"{run_out}/completeness.txt", f"executor exit: {failed}\n")
			return failed != 0

	int started = time_monotonic_ms()
	wcov_state* st = wcov_state_new()
	list[char*] dirs = new list[char*]
	if (merge):
		for k in range(merge):
			char* dir = f"{out}/shards/{k}-of-{merge}"
			int status = wcov_suite_receipt(dir, f"{k}/{merge}", target_set)
			if (status != 0):
				println2(f"wcoverage suite: shard {k}/{merge} failed (exit {status})")
				failed = 1
			wcov_suite_validate(dir, builds)
			dirs.push(dir)
	else:
		failed = wcov_suite_receipt(out, c"local", target_set)
		wcov_suite_validate(out, builds)
		dirs.push(out)
	int loaded = wcov_suite_load(st, dirs, builds)
	if (loaded == 0): wcov_suite_fail(c"no instrumented runs to report")
	wcov_suite_timing(out, c"merge", started)
	started = time_monotonic_ms()

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
	int status = wcov_report(st, opt)
	wcov_suite_timing(out, c"reports", started)
	if (failed != 0):
		wcov_suite_save(f"{out}/completeness.txt", c"INCOMPLETE: test failures; reports retained for diagnosis\n")
		println2(c"wcoverage suite: INCOMPLETE: test failures; reports retained for diagnosis")
		return 1
	wcov_suite_save(f"{out}/completeness.txt", c"COMPLETE: all requested test runs finished successfully\n")
	return status
