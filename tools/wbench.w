# wbuild: binary=wbench
# wbuild: target=wbench_compare dep=wbench dep=wv2
# wbuild: step="bin/wbench -n 1 --compare tools/wbench_baseline.txt"
# wbuild: target=wbench_compare_test tag=tests dep=wbench dep=wv2
# wbuild: step="bin/wbench -n 1 --only prelude --compare tests/wbench/baseline_generous.txt" expect_stdout="prelude     ok" expect_stdout="wbench: no regression against tests/wbench/baseline_generous.txt" reject_stdout="REGRESSION"
# wbuild: step="bin/wbench -n 1 --only prelude --compare tests/wbench/baseline_regressed.txt" expect_fail expect_stdout="prelude     REGRESSION: records visited" expect_stdout="prelude     REGRESSION: output bytes" expect_stdout="wbench: 1 workload(s) regressed"
# wbuild: step="bin/wbench -n 1 --only prelude --tolerance 1000000 --compare tests/wbench/baseline_regressed.txt" expect_stdout="wbench: no regression"
# wbuild: step="bin/wbench -n 1 --only prelude --time-factor 1 --compare tests/wbench/baseline_slow_time.txt" expect_fail expect_stdout="prelude     REGRESSION: wall time"
# wbuild: step="bin/wbench -n 1 --only prelude --write-baseline bin/wbench_baseline_roundtrip.txt"
# wbuild: step="bin/wbench -n 1 --only prelude --compare bin/wbench_baseline_roundtrip.txt" expect_stdout="prelude     ok"
# wbuild: step="bin/wbench -n 1 --only prelude --compare tests/wbench/no_such_baseline.txt" expect_fail expect_stderr="wbench: cannot read baseline"
# wbench: compile-speed benchmark for the compiler itself.
#
#	bin/wbench [<compiler>] [-n <runs>] [--only <workload>]
#	           [--write-baseline <file>]
#	           [--compare <file> [--tolerance <pct>] [--time-factor <x>]]
#
# Runs a fixed set of workloads through <compiler> (default bin/wv2) and
# reports, per workload, the symbol-lookup counters from 'w --stats', the
# size of the produced executable, and the best wall time of -n runs
# (default 3). --only restricts the run to one workload.
#
# Regression tracking (docs/testing.md, "Performance"):
# --write-baseline records the results to <file> (one line per workload:
# "<name> <calls> <visits> <bytes> <ms>", '#' comments allowed);
# tools/wbench_baseline.txt is the committed baseline. --compare reads a
# baseline and fails (exit 1) when a workload's calls, records visited or
# output bytes exceed the baseline by more than --tolerance percent
# (default 10). Those three are deterministic, so the check is exact on
# any machine. Wall time is machine- and load-dependent, so it is only
# reported unless --time-factor <x> is given, which also fails when the
# best time exceeds x times the baseline's (plus 50 ms of slack for tiny
# workloads). `./wbuild wbench_compare` runs the comparison against the
# committed baseline.
#
# Why the counters and not just the clock: 'records visited' is the number
# of symbol records sym_lookup walks (compiler/symbol_table.w), and it is
# a pure function of the input, so it is comparable across machines and
# across loaded/idle boxes, and a regression in it is unambiguous. Wall
# time on a shared CI runner is not. Both are printed; only the counters
# are worth pasting into a commit message as an exact figure.
#
# The workloads deliberately span the range where the cost curve bends:
# 'prelude' is the fixed floor every compile pays (the auto-imported
# container runtime alone), 'self' is the compiler compiling itself, and
# the sym<N> pair are generated files that add N symbols each, which is
# what the cost is actually quadratic in. See
# docs/projects/compiler_performance.md.
import lib.args
import lib.file
import lib.process
import lib.str
import structures.string


# Best-of-N wall time in ms, and the counters from the last run. Counters
# are deterministic, so any run's are as good as another's.
struct bench_result:
	int ok
	int best_ms
	int calls
	int visits
	int bytes          # size of the produced executable
	char* failure


# Parse "sym_lookup calls: N records visited: M" out of the child's
# stderr. Returns -1 when the marker is absent, which is how a compiler
# built without --stats support reports itself.
int bench_field(char* text, char* label):
	int at = index_of(text, label)
	if (at < 0): return -1
	int i = at + strlen(label)
	while ((text[i] == ' ') || (text[i] == ':')): i = i + 1
	int value = 0
	int seen = 0
	while ((text[i] >= '0') && (text[i] <= '9')):
		value = value * 10 + (text[i] - '0')
		seen = 1
		i = i + 1
	if (seen == 0): return -1
	return value


# One workload: compile source with the given compiler, runs times.
bench_result* bench_run(char* compiler, char* source, char* out_path, int runs):
	bench_result* r = new bench_result()
	r.ok = 0
	r.best_ms = -1
	r.calls = -1
	r.visits = -1
	r.bytes = -1
	r.failure = c"?"
	for i in range(runs):
		char** full = strv_new(6)
		strv_set(full, 0, compiler)
		strv_set(full, 1, c"--quiet")
		strv_set(full, 2, c"--stats")
		strv_set(full, 3, source)
		strv_set(full, 4, c"-o")
		strv_set(full, 5, out_path)
		int t0 = process_monotonic_ms()
		process_result* result = process_run(compiler, full, 0, 0, 600000)
		int elapsed = process_monotonic_ms() - t0
		free(cast(char*, full))
		if (result == 0):
			r.failure = c"could not run the compiler"
			return r
		if (result.status != 0):
			# The overwhelmingly likely cause is a compiler predating
			# --stats, which rejects it as an unknown option. Say so
			# rather than leaving a bare failure.
			r.failure = c"compiler exited non-zero (does it support --stats?)"
			process_result_free(result)
			return r
		if ((r.best_ms < 0) || (elapsed < r.best_ms)): r.best_ms = elapsed
		r.calls = bench_field(result.stderr_text, c"sym_lookup calls")
		r.visits = bench_field(result.stderr_text, c"records visited")
		process_result_free(result)
		if (r.visits < 0):
			r.failure = c"no --stats counters in the compiler's stderr"
			return r
	int fd = open(out_path, 0, 0)
	if (fd >= 0):
		r.bytes = file_size(fd)
		close(fd)
	r.ok = 1
	return r


void bench_report(char* label, bench_result* r):
	print(label)
	int pad = 10 - strlen(label)
	while (pad > 0):
		print(c" ")
		pad = pad - 1
	if (r.ok == 0):
		print(c"  FAILED: ")
		println(r.failure)
		return
	# All on stdout (print_int0 writes stderr, which interleaved badly
	# once the output was captured).
	print(c"  best ")
	print(itoa(r.best_ms))
	print(c" ms   calls ")
	print(itoa(r.calls))
	print(c"   records visited ")
	print(itoa(r.visits))
	print(c"   bytes ")
	println(itoa(r.bytes))


# Generate a file with n functions, each referencing the one before it, so
# every added symbol is also looked up at least once.
void bench_generate(char* path, int n):
	int fd = open(path, 577, 493)
	asserts(c"wbench: could not write the generated workload", fd >= 0)
	char* head = c"int f0(int a):\x0a\treturn a\x0a"
	write(fd, head, strlen(head))
	for i in range(1, n):
		char* a = strjoin(c"int f", itoa(i))
		char* b = strjoin(a, c"(int a):\x0a\treturn f")
		char* d = strjoin(b, itoa(i - 1))
		char* body = strjoin(d, c"(a)\x0a")
		write(fd, body, strlen(body))
		free(a)
		free(b)
		free(d)
		free(body)
	char* tail = c"int main():\x0a\treturn 0\x0a"
	write(fd, tail, strlen(tail))
	close(fd)


/* Baselines. */

struct bench_entry:
	char* name
	bench_result* result


# One baseline line: "<name> <calls> <visits> <bytes> <ms>".
struct bench_base:
	char* name
	int calls
	int visits
	int bytes
	int ms


# Leading/trailing blanks and a trailing CR stripped (a new string).
char* bench_trim(char* s):
	int start = 0
	while ((s[start] == ' ') || (s[start] == '\x09')): start = start + 1
	int end = strlen(s)
	while ((end > start) && ((s[end - 1] == ' ') || (s[end - 1] == '\x09') || (s[end - 1] == '\x0d'))): end = end - 1
	return substring(s, start, end)


# Reads a baseline file; exits 2 when it cannot be read or a line is
# malformed (a corrupt baseline must not compare as "no regression").
list[bench_base*] bench_read_baseline(char* path):
	char* text = file_read_text(path)
	if (text == 0):
		print2(c"wbench: cannot read baseline ")
		println2(path)
		exit(2)
	list[bench_base*] out = new list[bench_base*]
	for char* line in split(text, '\x0a'):
		char* t = bench_trim(line)
		if ((t[0] == 0) || (t[0] == '#')): continue
		list[char*] f = new list[char*]
		for char* piece in split(t, ' '):
			if (piece[0] != 0): f.push(piece)
		if (f.length != 5):
			print2(c"wbench: malformed baseline line in ")
			print2(path)
			print2(c": ")
			println2(t)
			exit(2)
		bench_base* b = new bench_base()
		b.name = f[0]
		b.calls = atoi(f[1])
		b.visits = atoi(f[2])
		b.bytes = atoi(f[3])
		b.ms = atoi(f[4])
		out.push(b)
	return out


void bench_write_baseline(char* path, list[bench_entry*] entries):
	string_builder* s = string_new()
	string_append(s, c"# wbench baseline: <workload> <sym_lookup calls> <records visited> <output bytes> <best ms>\x0a")
	string_append(s, c"# Regenerate with: bin/wbench --write-baseline <this file> (docs/testing.md)\x0a")
	for bench_entry* e in entries:
		if (e.result.ok == 0): continue
		string_append(s, e.name)
		string_append(s, c" ")
		string_append(s, itoa(e.result.calls))
		string_append(s, c" ")
		string_append(s, itoa(e.result.visits))
		string_append(s, c" ")
		string_append(s, itoa(e.result.bytes))
		string_append(s, c" ")
		string_append(s, itoa(e.result.best_ms))
		string_append(s, c"\x0a")
	io_result r
	if (file_write_text_checked(path, s.data, s.length, &r) != IO_OK):
		print2(c"wbench: cannot write baseline ")
		println2(path)
		exit(2)
	print(c"wbench: wrote baseline ")
	println(path)


# Is now more than tolerance percent above base? Integer math on 32-bit
# words: the allowance is (base / 100) * tolerance (at least one unit per
# percent), and an allowance past the int range never trips.
int bench_over(int now, int base, int tolerance):
	if (now <= base): return 0
	int step = base / 100
	if (step < 1): step = 1
	if ((tolerance > 0) && (step > 2000000000 / tolerance)): return 0
	return now - base > step * tolerance


void bench_flag(char* name, char* what, int now, int base):
	print(name)
	int pad = 10 - strlen(name)
	while (pad > 0):
		print(c" ")
		pad = pad - 1
	print(c"  REGRESSION: ")
	print(what)
	print(c" ")
	print(itoa(now))
	print(c" vs baseline ")
	println(itoa(base))


# Compares one result with its baseline line; returns 1 on a regression.
int bench_compare_one(bench_entry* e, bench_base* b, int tolerance, int time_factor):
	bench_result* r = e.result
	int bad = 0
	if (bench_over(r.calls, b.calls, tolerance)):
		bench_flag(e.name, c"sym_lookup calls", r.calls, b.calls)
		bad = 1
	if (bench_over(r.visits, b.visits, tolerance)):
		bench_flag(e.name, c"records visited", r.visits, b.visits)
		bad = 1
	if (bench_over(r.bytes, b.bytes, tolerance)):
		bench_flag(e.name, c"output bytes", r.bytes, b.bytes)
		bad = 1
	if ((time_factor > 0) && (r.best_ms > b.ms * time_factor + 50)):
		bench_flag(e.name, c"wall time ms", r.best_ms, b.ms)
		bad = 1
	if (bad == 0):
		print(e.name)
		int pad = 10 - strlen(e.name)
		while (pad > 0):
			print(c" ")
			pad = pad - 1
		print(c"  ok (visits ")
		print(itoa(r.visits))
		print(c" vs ")
		print(itoa(b.visits))
		print(c", bytes ")
		print(itoa(r.bytes))
		print(c" vs ")
		print(itoa(b.bytes))
		print(c", ms ")
		print(itoa(r.best_ms))
		print(c" vs ")
		print(itoa(b.ms))
		println(c")")
	return bad


# Returns the process exit status: 0, or 1 when a workload regressed,
# failed to run, or is missing from the baseline.
int bench_compare(char* path, list[bench_entry*] entries, int tolerance, int time_factor):
	list[bench_base*] base = bench_read_baseline(path)
	println(c"")
	print(c"comparing against ")
	print(path)
	print(c" (tolerance ")
	print(itoa(tolerance))
	print(c"%")
	if (time_factor > 0):
		print(c", time factor ")
		print(itoa(time_factor))
	println(c")")
	int regressed = 0
	for bench_entry* e in entries:
		bench_base* match = 0
		for bench_base* b in base:
			if (strcmp(b.name, e.name) == 0): match = b
		if (e.result.ok == 0):
			print(e.name)
			println(c"  FAILED to run")
			regressed = regressed + 1
		elif (match == 0):
			print(e.name)
			println(c"  missing from the baseline")
			regressed = regressed + 1
		else: regressed = regressed + bench_compare_one(e, match, tolerance, time_factor)
	if (regressed > 0):
		print(c"wbench: ")
		print(itoa(regressed))
		println(c" workload(s) regressed (an intended change: refresh the baseline, docs/testing.md)")
		return 1
	print(c"wbench: no regression against ")
	println(path)
	return 0


int bench_wanted(char* only, char* name):
	return (only == 0) || (strcmp(only, name) == 0)


void bench_add(list[bench_entry*] entries, char* name, bench_result* r):
	bench_report(name, r)
	bench_entry* e = new bench_entry()
	e.name = name
	e.result = r
	entries.push(e)


int main(int argc, int argv):
	args_init(argc, argv)
	char* compiler = c"bin/wv2"
	int runs = 3
	char* only = 0
	char* write_path = 0
	char* compare_path = 0
	int tolerance = 10
	int time_factor = 0
	int i = 1
	while (i < args_count()):
		char* a = args_get(i)
		int has_next = i + 1 < args_count()
		if ((strcmp(a, c"-n") == 0) && has_next):
			i = i + 1
			runs = atoi(args_get(i))
		elif ((strcmp(a, c"--only") == 0) && has_next):
			i = i + 1
			only = args_get(i)
		elif ((strcmp(a, c"--write-baseline") == 0) && has_next):
			i = i + 1
			write_path = args_get(i)
		elif ((strcmp(a, c"--compare") == 0) && has_next):
			i = i + 1
			compare_path = args_get(i)
		elif ((strcmp(a, c"--tolerance") == 0) && has_next):
			i = i + 1
			tolerance = atoi(args_get(i))
		elif ((strcmp(a, c"--time-factor") == 0) && has_next):
			i = i + 1
			time_factor = atoi(args_get(i))
		elif (a[0] == '-'):
			println2(c"usage: wbench [<compiler>] [-n <runs>] [--only <workload>] [--write-baseline <file>] [--compare <file> [--tolerance <pct>] [--time-factor <x>]]")
			return 2
		else: compiler = a
		i = i + 1
	if (runs < 1): runs = 1
	# Read the baseline first: a missing file should fail before minutes
	# of benchmarking, not after.
	if (compare_path != 0): bench_read_baseline(compare_path)

	println(c"wbench: compile-speed benchmark (best of the runs; counters are exact)")
	print(c"compiler: ")
	println(compiler)
	println(c"")

	# The prelude floor: a program with no content still compiles the
	# auto-imported container runtime.
	int fd = open(c"bin/wbench_prelude.w", 577, 493)
	asserts(c"wbench: could not write bin/wbench_prelude.w", fd >= 0)
	char* tiny = c"int main():\x0a\treturn 0\x0a"
	write(fd, tiny, strlen(tiny))
	close(fd)

	list[bench_entry*] entries = new list[bench_entry*]
	if (bench_wanted(only, c"prelude")):
		bench_add(entries, c"prelude", bench_run(compiler, c"bin/wbench_prelude.w", c"bin/wbench_out", runs))
	if (bench_wanted(only, c"sym1000")):
		bench_generate(c"bin/wbench_sym1000.w", 1000)
		bench_add(entries, c"sym1000", bench_run(compiler, c"bin/wbench_sym1000.w", c"bin/wbench_out", runs))
	if (bench_wanted(only, c"sym4000")):
		bench_generate(c"bin/wbench_sym4000.w", 4000)
		bench_add(entries, c"sym4000", bench_run(compiler, c"bin/wbench_sym4000.w", c"bin/wbench_out", runs))
	if (bench_wanted(only, c"self")):
		bench_add(entries, c"self", bench_run(compiler, c"w.w", c"bin/wbench_out", runs))
	if (entries.length == 0):
		print2(c"wbench: no workload named ")
		println2(only)
		return 2

	int status = 0
	if (write_path != 0): bench_write_baseline(write_path, entries)
	if (compare_path != 0): status = bench_compare(compare_path, entries, tolerance, time_factor)
	return status
