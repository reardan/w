# wbuild: binary=wbench
# wbuild: target=wbench_compare dep=wbench dep=wv2
# wbuild: step="bin/wbench -n 1 --write-baseline bin/wbench_results.txt --compare tools/wbench_baseline.txt"
# wbuild: target=wbench_compare_test tag=tests dep=wbench dep=wv2
# wbuild: step="bin/wbench -n 1 --only prelude --compare tests/wbench/baseline_generous.txt" expect_stdout="prelude     ok" expect_stdout="wbench: no regression against tests/wbench/baseline_generous.txt" reject_stdout="REGRESSION"
# wbuild: step="bin/wbench -n 1 --only prelude --compare tests/wbench/baseline_regressed.txt" expect_fail expect_stdout="prelude     REGRESSION: sym_lookup calls" expect_stdout="prelude     REGRESSION: records visited" expect_stdout="prelude     REGRESSION: output bytes" expect_stdout="wbench: 1 workload(s) regressed"
# wbuild: step="bin/wbench -n 1 --only prelude --tolerance 1000000 --compare tests/wbench/baseline_regressed.txt" expect_stdout="wbench: no regression"
# wbuild: step="bin/wbench -n 1 --only prelude --compare tests/wbench/baseline_slow_time.txt" expect_stdout="wbench: no regression" reject_stdout="REGRESSION"
# wbuild: step="bin/wbench -n 1 --only prelude --time-factor 1 --compare tests/wbench/baseline_slow_time.txt" expect_fail expect_stdout="prelude     REGRESSION: wall time"
# wbuild: step="bin/wbench -n 1 --only prelude --write-baseline bin/wbench_baseline_roundtrip.txt"
# wbuild: step="bin/wbench -n 1 --only prelude --compare bin/wbench_baseline_roundtrip.txt" expect_stdout="prelude     ok"
# wbuild: step="bin/wbench -n 1 --only prelude --compare tests/wbench/no_such_baseline.txt" expect_fail expect_stderr="wbench: cannot read baseline"
# wbuild: step="bin/wbench --programs --only sum --size 1000 -n 1 --no-valgrind --prefix bin/wbench_test_prog_ --compare tests/bench/fixtures/baseline_generous.txt" expect_stdout="sum.x86" expect_stdout="sum.x64" expect_stdout="ok (bytes" expect_stdout="wbench: no regression against tests/bench/fixtures/baseline_generous.txt" reject_stdout="REGRESSION"
# wbuild: step="bin/wbench --programs --only sum --size 1000 -n 1 --no-valgrind --prefix bin/wbench_test_prog_ --compare tests/bench/fixtures/baseline_regressed.txt" expect_fail expect_stdout="sum.x86     REGRESSION: output bytes" expect_stdout="sum.x64     REGRESSION: output bytes" expect_stdout="wbench: 2 workload(s) regressed"
# wbuild: step="bin/wbench --programs --only sum --size 1000 -n 1 --no-valgrind --prefix bin/wbench_test_prog_ --compare tests/bench/fixtures/baseline_ir_regressed.txt" expect_stdout="kIr skipped" expect_stdout="wbench: no regression" reject_stdout="REGRESSION"
# wbuild: step="bin/wbench --programs --only sum --size 1000 -n 1 --no-valgrind --prefix bin/wbench_test_prog_ --compare tests/bench/fixtures/baseline_missing_row.txt" expect_fail expect_stdout="sum.x64     missing from the baseline"
# wbuild: step="bin/wbench --programs --only sum --size 1000 -n 1 --no-valgrind --prefix bin/wbench_test_prog_ --write-baseline bin/wbench_programs_roundtrip.txt"
# wbuild: step="bin/wbench --programs --only sum --size 1000 -n 1 --no-valgrind --prefix bin/wbench_test_prog_ --compare bin/wbench_programs_roundtrip.txt" expect_stdout="sum.x86     ok" expect_stdout="sum.x64     ok"
# wbuild: target=bench_report dep=wbench dep=wv2 dep=build_x64 dep=bench_sum dep=bench_sieve dep=bench_sha256_1m dep=bench_siphash_keys dep=bench_inflate_corpus dep=bench_regex_backtrack dep=bench_matmul_256 dep=bench_strcmp_sort
# wbuild: step="bin/wbench --programs -n 3 --write-baseline bin/bench.txt" timeout=3600000
# wbuild: target=bench_compare dep=wbench dep=wv2 dep=build_x64
# wbuild: step="bin/wbench --programs -n 3 --write-baseline bin/bench.txt --compare tests/bench/baseline.txt" timeout=3600000
# wbench: compile-speed benchmark for the compiler itself, and (with
# --programs) the run-time benchmark corpus of tests/bench/.
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
#
# Program benchmarks (docs/projects/register_allocation_pgo.md §5):
#
#	bin/wbench --programs [--compiler <path>] [--compiler64 <path>]
#	           [--arch x86|x64|both] [-n <runs>] [--only <name>]
#	           [--size <n>] [--no-valgrind] [--prefix <path-prefix>]
#	           [--write-baseline <file>]
#	           [--compare <file> [--tolerance <pct>] [--time-factor <x>]]
#
# compiles every program of tests/bench/ (sum, sieve, sha256_1m,
# siphash_keys, inflate_corpus, regex_backtrack, matmul_256, strcmp_sort)
# with <compiler> for x86 and for x64, runs each -n times and reports, per
# <name>.<arch> row, the executable size in bytes, the callgrind
# instruction count in thousands (kIr; measured once per row when
# `valgrind` is on PATH and --no-valgrind is not given -- it is a
# deterministic property of the binary, like the size) with the three
# hottest functions, and the best wall time. 'self' is the compiler
# compiling w.w: the x86 row runs <compiler>, the x64 row runs the
# x64-built compiler <compiler64> (default bin/wv2_64 from build_x64; the
# row is skipped when it does not exist). The x86 and x64 builds of a
# program must print the same checksum line, or the row fails.
#
# --compiler is how the orchestrator of a compiler change runs the same
# corpus with a baseline compiler and a new one; --size passes one size
# argument to every program (the smoke runs in wbench_compare_test);
# --prefix is where the compiled programs go (default bin/wbench_prog_).
#
# Baselines use the same rules as the compile-speed mode: one row per
# line, "<name> <arch> <bytes> <kIr> <ms>" (kIr -1 when not measured), '#'
# comments allowed; --compare gates bytes and -- when both sides measured
# it -- kIr within --tolerance percent, reports wall time (gated only by
# --time-factor), and skips, never fails, the kIr check when valgrind is
# absent. `./wbuild bench` runs the corpus and writes bin/bench.txt (a
# baseline file with the top functions as comments), `./wbuild
# bench_compare` additionally compares against tests/bench/baseline.txt;
# refresh that file by copying bin/bench.txt over it after an intended
# change. tools/bench_vs_c.sh compares the same programs against their C
# twins in tests/bench/c/ built with gcc/clang.
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


void bench_pad(char* label, int width):
	int pad = width - strlen(label)
	while (pad > 0):
		print(c" ")
		pad = pad - 1


void bench_report(char* label, bench_result* r):
	print(label)
	bench_pad(label, 10)
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


void bench_baseline_error(char* path, char* what, char* line):
	print2(c"wbench: ")
	print2(what)
	print2(path)
	if (line != 0):
		print2(c": ")
		print2(line)
	println2(c"")
	exit(2)


# The non-blank, non-comment lines of a baseline file, each split into
# its whitespace-separated fields (exactly `fields` of them). Exits 2
# when the file cannot be read or a line is malformed: a corrupt
# baseline must not compare as "no regression".
list[list[char*]] bench_read_rows(char* path, int fields):
	char* text = file_read_text(path)
	if (text == 0): bench_baseline_error(path, c"cannot read baseline ", 0)
	list[list[char*]] rows = new list[list[char*]]
	for char* line in split(text, '\x0a'):
		char* t = bench_trim(line)
		if ((t[0] == 0) || (t[0] == '#')): continue
		list[char*] f = new list[char*]
		for char* piece in split(t, ' '):
			if (piece[0] != 0): f.push(piece)
		if (f.length != fields): bench_baseline_error(path, c"malformed baseline line in ", t)
		rows.push(f)
	return rows


list[bench_base*] bench_read_baseline(char* path):
	list[bench_base*] out = new list[bench_base*]
	for list[char*] f in bench_read_rows(path, 5):
		bench_base* b = new bench_base()
		b.name = f[0]
		b.calls = atoi(f[1])
		b.visits = atoi(f[2])
		b.bytes = atoi(f[3])
		b.ms = atoi(f[4])
		out.push(b)
	return out


void bench_write_file(char* path, string_builder* s):
	io_result r
	if (file_write_text_checked(path, s.data, s.length, &r) != IO_OK):
		print2(c"wbench: cannot write baseline ")
		println2(path)
		exit(2)
	print(c"wbench: wrote baseline ")
	println(path)


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
	bench_write_file(path, s)


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
	bench_pad(name, 10)
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
		bench_pad(e.name, 10)
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


void bench_compare_header(char* path, int tolerance, int time_factor):
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


# The exit status for `regressed` bad rows, with the closing line.
int bench_compare_verdict(char* path, int regressed):
	if (regressed > 0):
		print(c"wbench: ")
		print(itoa(regressed))
		println(c" workload(s) regressed (an intended change: refresh the baseline, docs/testing.md)")
		return 1
	print(c"wbench: no regression against ")
	println(path)
	return 0


# Returns the process exit status: 0, or 1 when a workload regressed,
# failed to run, or is missing from the baseline.
int bench_compare(char* path, list[bench_entry*] entries, int tolerance, int time_factor):
	list[bench_base*] base = bench_read_baseline(path)
	bench_compare_header(path, tolerance, time_factor)
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
	return bench_compare_verdict(path, regressed)


int bench_wanted(char* only, char* name):
	return (only == 0) || (strcmp(only, name) == 0)


void bench_add(list[bench_entry*] entries, char* name, bench_result* r):
	bench_report(name, r)
	bench_entry* e = new bench_entry()
	e.name = name
	e.result = r
	entries.push(e)


/* Program benchmarks (--programs). */

# One <name>.<arch> row.
struct prog_result:
	int ok
	char* failure
	int bytes          # executable size
	int kir            # callgrind Ir / 1000, -1 when not measured
	int best_ms
	char* output       # the program's stdout (its checksum line)
	char* top          # "f 95.2%, g 4.4%, h 0.3%" or 0


struct prog_entry:
	char* name         # "sum"
	char* arch         # "x86" / "x64"
	char* key          # "sum.x86"
	prog_result* result


# One baseline row: "<name> <arch> <bytes> <kIr> <ms>".
struct prog_base:
	char* key
	int bytes
	int kir
	int ms


char* prog_valgrind        # path, or 0 when absent / --no-valgrind
char* prog_annotate        # callgrind_annotate path, or 0
char* prog_nm              # nm path, or 0


# The corpus: tests/bench/<name>.w for each name, 'self' handled apart.
list[char*] prog_names():
	list[char*] names = new list[char*]
	names.push(c"sum")
	names.push(c"sieve")
	names.push(c"sha256_1m")
	names.push(c"siphash_keys")
	names.push(c"inflate_corpus")
	names.push(c"regex_backtrack")
	names.push(c"matmul_256")
	names.push(c"strcmp_sort")
	names.push(c"self")
	return names


char* prog_concat3(char* a, char* b, char* d):
	char* ab = strjoin(a, b)
	char* out = strjoin(ab, d)
	free(ab)
	return out


prog_result* prog_fail(prog_result* r, char* why):
	r.ok = 0
	r.failure = why
	return r


int prog_file_size(char* path):
	int fd = open(path, 0, 0)
	if (fd < 0): return -1
	int n = file_size(fd)
	close(fd)
	return n


# Runs argv (argv[0] is the program) once, capturing both streams; 0 when
# it could not be started. The caller frees the result.
process_result* prog_exec(char** argv, int timeout_ms):
	return process_run(strv_get(argv, 0), argv, 0, 0, timeout_ms)


# "Collected : 365706575" from callgrind's summary, as thousands; -1
# when absent.
int prog_parse_collected(char* text):
	int at = index_of(text, c"Collected : ")
	if (at < 0): return -1
	int i = at + 12
	int digits = 0
	while ((text[i + digits] >= '0') && (text[i + digits] <= '9')): digits = digits + 1
	if (digits == 0): return -1
	# Drop the last three digits rather than dividing: the full count
	# overflows a 32-bit word for the self-compile.
	int keep = digits - 3
	int value = 0
	int k = 0
	while (k < keep):
		value = value * 10 + (text[i + k] - '0')
		k = k + 1
	return value


# The function symbol at or before address in a `nm -n` listing (lines
# "<hex> <type> <name>"), or 0.
char* prog_symbol_at(char* nm_text, int address):
	char* best = 0
	int best_addr = 0
	int have = 0
	# Unsigned comparison through sign-flipped words: addresses at or
	# above 0x80000000 compare negative in a 32-bit word, and flipping
	# bit 31 of both sides restores their order.
	int target = address ^ (1 << 31)
	for char* line in split(nm_text, '\x0a'):
		list[char*] f = new list[char*]
		for char* piece in split(line, ' '):
			if (piece[0] != 0): f.push(piece)
		if (f.length != 3): continue
		if ((f[1][0] != 'T') && (f[1][0] != 't')): continue
		int a = from_hex(f[0]) ^ (1 << 31)
		if ((a <= target) && ((have == 0) || (a > best_addr))):
			best_addr = a
			best = f[2]
			have = 1
	return best


# "file:function" from callgrind_annotate -> the function's name. W
# binaries carry DWARF line tables but valgrind does not read their
# symbol table, so the function column is "file.w:0x08060abc"; resolve
# the address with nm when it is on PATH, else keep the address.
char* prog_function_name(char* column, char* nm_text):
	int colon = -1
	int i = 0
	while (column[i] != 0):
		if (column[i] == ':'): colon = i
		i = i + 1
	char* fn = column
	if (colon >= 0): fn = column + colon + 1
	# callgrind marks recursion cycles with a '<n> suffix ("0x0806012f'2");
	# it is not part of the address.
	i = 0
	while ((fn[i] != 0) && (fn[i] != 39)): i = i + 1
	fn = substring(fn, 0, i)
	if ((fn[0] == '0') && (fn[1] == 'x') && (nm_text != 0)):
		char* name = prog_symbol_at(nm_text, from_hex(fn))
		if (name != 0): return name
	return strclone(fn)


# The three hottest functions of a callgrind profile, "name pct%, ...".
char* prog_top_functions(char* profile, char* binary):
	if (prog_annotate == 0): return 0
	char** argv = strv_new(2)
	strv_set(argv, 0, prog_annotate)
	strv_set(argv, 1, profile)
	process_result* res = prog_exec(argv, 600000)
	free(cast(char*, argv))
	if ((res == 0) || (res.status != 0)): return 0
	char* nm_text = 0
	if (prog_nm != 0):
		char** nm_argv = strv_new(3)
		strv_set(nm_argv, 0, prog_nm)
		strv_set(nm_argv, 1, c"-n")
		strv_set(nm_argv, 2, binary)
		process_result* nm_res = prog_exec(nm_argv, 600000)
		free(cast(char*, nm_argv))
		if ((nm_res != 0) && (nm_res.status == 0)): nm_text = nm_res.stdout_text
	string_builder* out = string_new()
	int seen_header = 0
	int count = 0
	for char* line in split(res.stdout_text, '\x0a'):
		if (count >= 3): break
		if (seen_header == 0):
			if (index_of(line, c"file:function") >= 0): seen_header = 1
			continue
		# "348,249,696 (95.23%)  file:function [binary]"
		int i = 0
		while (line[i] == ' '): i = i + 1
		if ((line[i] < '0') || (line[i] > '9')): continue
		while (((line[i] >= '0') && (line[i] <= '9')) || (line[i] == ',')): i = i + 1
		while (line[i] == ' '): i = i + 1
		if (line[i] != '('): continue
		int pct_start = i + 1
		while (line[pct_start] == ' '): pct_start = pct_start + 1
		while ((line[i] != 0) && (line[i] != ')')): i = i + 1
		char* pct = substring(line, pct_start, i)
		if (line[i] == ')'): i = i + 1
		while (line[i] == ' '): i = i + 1
		int col_start = i
		while ((line[i] != 0) && (line[i] != ' ') && (line[i] != '\x09')): i = i + 1
		char* column = substring(line, col_start, i)
		if (count > 0): string_append(out, c", ")
		string_append(out, prog_function_name(column, nm_text))
		string_append(out, c" ")
		string_append(out, pct)
		count = count + 1
	process_result_free(res)
	if (count == 0): return 0
	return out.data


# Runs argv under callgrind, filling r.kir and r.top. A valgrind failure
# is reported in the row's top line and leaves kir at -1 (skipped).
void prog_measure_ir(prog_result* r, char** argv, int argc, char* binary, char* profile):
	if (prog_valgrind == 0): return
	char** full = strv_new(argc + 3)
	strv_set(full, 0, prog_valgrind)
	strv_set(full, 1, c"--tool=callgrind")
	char* out_opt = strjoin(c"--callgrind-out-file=", profile)
	strv_set(full, 2, out_opt)
	for i in range(argc): strv_set(full, 3 + i, strv_get(argv, i))
	process_result* res = prog_exec(full, 3600000)
	free(cast(char*, full))
	free(out_opt)
	if (res == 0):
		r.top = c"(valgrind could not be started)"
		return
	if (res.status != 0):
		r.top = c"(valgrind exited non-zero)"
		process_result_free(res)
		return
	r.kir = prog_parse_collected(res.stderr_text)
	process_result_free(res)
	r.top = prog_top_functions(profile, binary)


# Runs argv `runs` times for the best wall time; the first run's stdout
# is kept as the program's output. Returns 0 on success.
int prog_time_runs(prog_result* r, char** argv, int runs, int want_output):
	for i in range(runs):
		int t0 = process_monotonic_ms()
		process_result* res = prog_exec(argv, 3600000)
		int elapsed = process_monotonic_ms() - t0
		if (res == 0):
			prog_fail(r, c"could not start the program")
			return 1
		if (res.status != 0):
			prog_fail(r, c"the program exited non-zero")
			process_result_free(res)
			return 1
		if ((r.best_ms < 0) || (elapsed < r.best_ms)): r.best_ms = elapsed
		if (want_output):
			char* out = bench_trim(res.stdout_text)
			if (r.output == 0): r.output = out
			elif (strcmp(r.output, out) != 0):
				prog_fail(r, c"output differs between runs")
				process_result_free(res)
				return 1
		process_result_free(res)
	return 0


prog_result* prog_result_new():
	prog_result* r = new prog_result()
	r.ok = 1
	r.failure = 0
	r.bytes = -1
	r.kir = -1
	r.best_ms = -1
	r.output = 0
	r.top = 0
	return r


# One tests/bench program for one arch: compile, time, measure.
prog_result* prog_run(char* compiler, char* name, char* arch, char* prefix, int runs, char* size):
	prog_result* r = prog_result_new()
	char* source = prog_concat3(c"tests/bench/", name, c".w")
	char* binary = prog_concat3(prefix, name, strjoin(c"_", arch))
	int is_x64 = strcmp(arch, c"x64") == 0
	int argc = 5
	if (is_x64): argc = 6
	char** argv = strv_new(argc)
	int i = 0
	strv_set(argv, i, compiler)
	i = i + 1
	if (is_x64):
		strv_set(argv, i, c"x64")
		i = i + 1
	strv_set(argv, i, c"--quiet")
	strv_set(argv, i + 1, source)
	strv_set(argv, i + 2, c"-o")
	strv_set(argv, i + 3, binary)
	process_result* res = prog_exec(argv, 600000)
	free(cast(char*, argv))
	if (res == 0): return prog_fail(r, c"could not run the compiler")
	if (res.status != 0):
		process_result_free(res)
		return prog_fail(r, c"the compiler rejected the program")
	process_result_free(res)
	r.bytes = prog_file_size(binary)
	int run_argc = 1
	if (size != 0): run_argc = 2
	char** run_argv = strv_new(run_argc)
	strv_set(run_argv, 0, binary)
	if (size != 0): strv_set(run_argv, 1, size)
	if (prog_time_runs(r, run_argv, runs, 1)): return r
	prog_measure_ir(r, run_argv, run_argc, binary, strjoin(binary, c".callgrind"))
	return r


# The self-compile row: compiler (x86) or compiler64 (x64) compiling w.w.
prog_result* prog_run_self(char* compiler, char* arch, char* prefix, int runs):
	prog_result* r = prog_result_new()
	char* out = prog_concat3(prefix, c"self_", arch)
	int is_x64 = strcmp(arch, c"x64") == 0
	int argc = 5
	if (is_x64): argc = 6
	char** argv = strv_new(argc)
	int i = 0
	strv_set(argv, i, compiler)
	i = i + 1
	if (is_x64):
		strv_set(argv, i, c"x64")
		i = i + 1
	strv_set(argv, i, c"--quiet")
	strv_set(argv, i + 1, c"w.w")
	strv_set(argv, i + 2, c"-o")
	strv_set(argv, i + 3, out)
	if (prog_time_runs(r, argv, runs, 0)): return r
	r.bytes = prog_file_size(out)
	r.output = c"(the compiled compiler)"
	prog_measure_ir(r, argv, argc, compiler, strjoin(out, c".callgrind"))
	return r


void prog_report(prog_entry* e):
	prog_result* r = e.result
	print(e.key)
	bench_pad(e.key, 20)
	if (r.ok == 0):
		print(c"  FAILED: ")
		println(r.failure)
		return
	print(c"  bytes ")
	print(itoa(r.bytes))
	print(c"   kIr ")
	if (r.kir >= 0): print(itoa(r.kir))
	else: print(c"-")
	print(c"   best ")
	print(itoa(r.best_ms))
	println(c" ms")
	if (r.top != 0):
		print(c"                        top: ")
		println(r.top)


list[prog_base*] prog_read_baseline(char* path):
	list[prog_base*] out = new list[prog_base*]
	for list[char*] f in bench_read_rows(path, 5):
		prog_base* b = new prog_base()
		b.key = prog_concat3(f[0], c".", f[1])
		b.bytes = atoi(f[2])
		b.kir = atoi(f[3])
		b.ms = atoi(f[4])
		out.push(b)
	return out


void prog_write_baseline(char* path, list[prog_entry*] entries, char* compiler, char* compiler64):
	string_builder* s = string_new()
	string_append(s, c"# wbench program baseline: <program> <arch> <output bytes> <kIr: callgrind Ir / 1000, -1 = not measured> <best ms>\x0a")
	string_append(s, c"# Regenerate with: ./wbuild bench, then copy bin/bench.txt here (docs/testing.md, \"Performance\").\x0a")
	string_append(s, c"# compiler: ")
	string_append(s, compiler)
	if (compiler64 != 0):
		string_append(s, c"   x64 self-compile: ")
		string_append(s, compiler64)
	string_append(s, c"\x0a")
	for prog_entry* e in entries:
		prog_result* r = e.result
		if (r.ok == 0): continue
		string_append(s, e.name)
		string_append(s, c" ")
		string_append(s, e.arch)
		string_append(s, c" ")
		string_append(s, itoa(r.bytes))
		string_append(s, c" ")
		string_append(s, itoa(r.kir))
		string_append(s, c" ")
		string_append(s, itoa(r.best_ms))
		string_append(s, c"\x0a")
		if (r.top != 0):
			string_append(s, c"#   top: ")
			string_append(s, r.top)
			string_append(s, c"\x0a")
	bench_write_file(path, s)


# Compares one row with its baseline; returns 1 on a regression. kIr is
# gated only when both sides measured it, and says so otherwise.
int prog_compare_one(prog_entry* e, prog_base* b, int tolerance, int time_factor):
	prog_result* r = e.result
	int bad = 0
	if (bench_over(r.bytes, b.bytes, tolerance)):
		bench_flag(e.key, c"output bytes", r.bytes, b.bytes)
		bad = 1
	int ir_gated = (r.kir >= 0) && (b.kir >= 0)
	if (ir_gated && bench_over(r.kir, b.kir, tolerance)):
		bench_flag(e.key, c"instructions kIr", r.kir, b.kir)
		bad = 1
	if ((time_factor > 0) && (r.best_ms > b.ms * time_factor + 50)):
		bench_flag(e.key, c"wall time ms", r.best_ms, b.ms)
		bad = 1
	if (bad == 0):
		print(e.key)
		bench_pad(e.key, 10)
		print(c"  ok (bytes ")
		print(itoa(r.bytes))
		print(c" vs ")
		print(itoa(b.bytes))
		if (ir_gated):
			print(c", kIr ")
			print(itoa(r.kir))
			print(c" vs ")
			print(itoa(b.kir))
		else: print(c", kIr skipped")
		print(c", ms ")
		print(itoa(r.best_ms))
		print(c" vs ")
		print(itoa(b.ms))
		println(c")")
	return bad


int prog_compare(char* path, list[prog_entry*] entries, int tolerance, int time_factor):
	list[prog_base*] base = prog_read_baseline(path)
	bench_compare_header(path, tolerance, time_factor)
	int regressed = 0
	for prog_entry* e in entries:
		prog_base* match = 0
		for prog_base* b in base:
			if (strcmp(b.key, e.key) == 0): match = b
		if (e.result.ok == 0):
			print(e.key)
			bench_pad(e.key, 10)
			print(c"  FAILED: ")
			println(e.result.failure)
			regressed = regressed + 1
		elif (match == 0):
			print(e.key)
			bench_pad(e.key, 10)
			println(c"  missing from the baseline")
			regressed = regressed + 1
		else: regressed = regressed + prog_compare_one(e, match, tolerance, time_factor)
	return bench_compare_verdict(path, regressed)


# The x86 and x64 builds of one program must agree on their output.
void prog_check_outputs(list[prog_entry*] entries):
	for prog_entry* a in entries:
		if ((a.result.ok == 0) || (strcmp(a.arch, c"x86") != 0)): continue
		for prog_entry* b in entries:
			if ((b.result.ok == 0) || (strcmp(b.arch, c"x64") != 0)): continue
			if (strcmp(a.name, b.name) != 0): continue
			if (strcmp(a.result.output, b.result.output) != 0):
				prog_fail(b.result, c"output differs from the x86 build")
				print(b.key)
				bench_pad(b.key, 20)
				print(c"  FAILED: x86 printed '")
				print(a.result.output)
				print(c"', x64 printed '")
				print(b.result.output)
				println(c"'")


int prog_main(char* compiler, char* compiler64, char* arch, int runs, char* only, char* size, int no_valgrind, char* prefix, char* write_path, char* compare_path, int tolerance, int time_factor):
	if (compare_path != 0): prog_read_baseline(compare_path)
	if (no_valgrind == 0):
		prog_valgrind = process_which(c"valgrind")
		prog_annotate = process_which(c"callgrind_annotate")
		prog_nm = process_which(c"nm")
	if (compiler64 == 0):
		if (prog_file_size(c"bin/wv2_64") > 0): compiler64 = c"bin/wv2_64"
	int want_x86 = (strcmp(arch, c"both") == 0) || (strcmp(arch, c"x86") == 0)
	int want_x64 = (strcmp(arch, c"both") == 0) || (strcmp(arch, c"x64") == 0)

	println(c"wbench: program benchmarks (best of the runs; bytes and kIr are exact)")
	print(c"compiler: ")
	print(compiler)
	if (compiler64 != 0):
		print(c"   x64 self-compile: ")
		print(compiler64)
	println(c"")
	print(c"valgrind: ")
	if (prog_valgrind != 0): println(prog_valgrind)
	elif (no_valgrind): println(c"disabled (--no-valgrind), kIr not measured")
	else: println(c"not on PATH, kIr not measured")
	println(c"")

	list[prog_entry*] entries = new list[prog_entry*]
	for char* name in prog_names():
		if (bench_wanted(only, name) == 0): continue
		int is_self = strcmp(name, c"self") == 0
		list[char*] archs = new list[char*]
		if (want_x86): archs.push(c"x86")
		if (want_x64): archs.push(c"x64")
		for char* a in archs:
			prog_entry* e = new prog_entry()
			e.name = name
			e.arch = a
			e.key = prog_concat3(name, c".", a)
			if (is_self):
				if (strcmp(a, c"x64") == 0):
					if (compiler64 == 0):
						print(e.key)
						bench_pad(e.key, 20)
						println(c"  skipped (no x64 compiler: ./wbuild build_x64, or --compiler64)")
						continue
					e.result = prog_run_self(compiler64, a, prefix, runs)
				else: e.result = prog_run_self(compiler, a, prefix, runs)
			else: e.result = prog_run(compiler, name, a, prefix, runs, size)
			prog_report(e)
			entries.push(e)
	if (entries.length == 0):
		print2(c"wbench: no program named ")
		println2(only)
		return 2
	prog_check_outputs(entries)

	int status = 0
	if (write_path != 0): prog_write_baseline(write_path, entries, compiler, compiler64)
	if (compare_path != 0): status = prog_compare(compare_path, entries, tolerance, time_factor)
	elif (write_path == 0):
		for prog_entry* e in entries:
			if (e.result.ok == 0): status = 1
	return status


int main(int argc, int argv):
	args_init(argc, argv)
	char* compiler = c"bin/wv2"
	char* compiler64 = 0
	int runs = 3
	char* only = 0
	char* write_path = 0
	char* compare_path = 0
	int tolerance = 10
	int time_factor = 0
	int programs = 0
	char* arch = c"both"
	char* size = 0
	int no_valgrind = 0
	char* prefix = c"bin/wbench_prog_"
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
		elif (strcmp(a, c"--programs") == 0): programs = 1
		elif ((strcmp(a, c"--compiler") == 0) && has_next):
			i = i + 1
			compiler = args_get(i)
		elif ((strcmp(a, c"--compiler64") == 0) && has_next):
			i = i + 1
			compiler64 = args_get(i)
		elif ((strcmp(a, c"--arch") == 0) && has_next):
			i = i + 1
			arch = args_get(i)
			if ((strcmp(arch, c"x86") != 0) && (strcmp(arch, c"x64") != 0) && (strcmp(arch, c"both") != 0)):
				println2(c"wbench: --arch takes x86, x64 or both")
				return 2
		elif ((strcmp(a, c"--size") == 0) && has_next):
			i = i + 1
			size = args_get(i)
		elif (strcmp(a, c"--no-valgrind") == 0): no_valgrind = 1
		elif ((strcmp(a, c"--prefix") == 0) && has_next):
			i = i + 1
			prefix = args_get(i)
		elif (a[0] == '-'):
			println2(c"usage: wbench [<compiler>] [-n <runs>] [--only <workload>] [--write-baseline <file>] [--compare <file> [--tolerance <pct>] [--time-factor <x>]]")
			println2(c"       wbench --programs [--compiler <path>] [--compiler64 <path>] [--arch x86|x64|both] [-n <runs>] [--only <name>] [--size <n>] [--no-valgrind] [--prefix <path-prefix>] [--write-baseline <file>] [--compare <file> ...]")
			return 2
		else: compiler = a
		i = i + 1
	if (runs < 1): runs = 1
	if (programs): return prog_main(compiler, compiler64, arch, runs, only, size, no_valgrind, prefix, write_path, compare_path, tolerance, time_factor)
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
