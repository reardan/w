# wbench: compile-speed benchmark for the compiler itself.
#
#	bin/wbench [<compiler>] [-n <runs>]
#
# Runs a fixed set of workloads through <compiler> (default bin/wv2) and
# reports, per workload, the symbol-lookup counters from 'w --stats' and
# the best wall time of -n runs (default 3).
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


# Best-of-N wall time in ms, and the counters from the last run. Counters
# are deterministic, so any run's are as good as another's.
struct bench_result:
	int ok
	int best_ms
	int calls
	int visits
	char* failure


# Offset of the first occurrence of needle in haystack, or -1.
int bench_find(char* haystack, char* needle):
	int i = 0
	while (haystack[i] != 0):
		if (starts_with(&haystack[i], needle)):
			return i
		i = i + 1
	return -1


# Parse "sym_lookup calls: N records visited: M" out of the child's
# stderr. Returns -1 when the marker is absent, which is how a compiler
# built without --stats support reports itself.
int bench_field(char* text, char* label):
	int at = bench_find(text, label)
	if (at < 0):
		return -1
	int i = at + strlen(label)
	while ((text[i] == ' ') || (text[i] == ':')):
		i = i + 1
	int value = 0
	int seen = 0
	while ((text[i] >= '0') && (text[i] <= '9')):
		value = value * 10 + (text[i] - '0')
		seen = 1
		i = i + 1
	if (seen == 0):
		return -1
	return value


# One workload: compile source with the given compiler, runs times.
bench_result* bench_run(char* compiler, char* source, char* out_path, int runs):
	bench_result* r = new bench_result()
	r.ok = 0
	r.best_ms = -1
	r.calls = -1
	r.visits = -1
	r.failure = c"?"
	int i = 0
	while (i < runs):
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
		if ((r.best_ms < 0) || (elapsed < r.best_ms)):
			r.best_ms = elapsed
		r.calls = bench_field(result.stderr_text, c"sym_lookup calls")
		r.visits = bench_field(result.stderr_text, c"records visited")
		process_result_free(result)
		if (r.visits < 0):
			r.failure = c"no --stats counters in the compiler's stderr"
			return r
		i = i + 1
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
	print_int0(c"  best ", r.best_ms)
	print(c" ms")
	print_int0(c"   calls ", r.calls)
	print_int0(c"   records visited ", r.visits)
	println(c"")


# Generate a file with n functions, each referencing the one before it, so
# every added symbol is also looked up at least once.
void bench_generate(char* path, int n):
	int fd = open(path, 577, 493)
	asserts(c"wbench: could not write the generated workload", fd >= 0)
	char* head = c"int f0(int a):\x0a\treturn a\x0a"
	write(fd, head, strlen(head))
	int i = 1
	while (i < n):
		char* a = strjoin(c"int f", itoa(i))
		char* b = strjoin(a, c"(int a):\x0a\treturn f")
		char* d = strjoin(b, itoa(i - 1))
		char* body = strjoin(d, c"(a)\x0a")
		write(fd, body, strlen(body))
		free(a)
		free(b)
		free(d)
		free(body)
		i = i + 1
	char* tail = c"int main():\x0a\treturn 0\x0a"
	write(fd, tail, strlen(tail))
	close(fd)


int main(int argc, int argv):
	args_init(argc, argv)
	char* compiler = c"bin/wv2"
	int runs = 3
	int i = 1
	while (i < args_count()):
		char* a = args_get(i)
		if (strcmp(a, c"-n") == 0):
			i = i + 1
			runs = atoi(args_get(i))
		else:
			compiler = a
		i = i + 1

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

	bench_generate(c"bin/wbench_sym1000.w", 1000)
	bench_generate(c"bin/wbench_sym4000.w", 4000)

	bench_report(c"prelude", bench_run(compiler, c"bin/wbench_prelude.w", c"bin/wbench_out", runs))
	bench_report(c"sym1000", bench_run(compiler, c"bin/wbench_sym1000.w", c"bin/wbench_out", runs))
	bench_report(c"sym4000", bench_run(compiler, c"bin/wbench_sym4000.w", c"bin/wbench_out", runs))
	bench_report(c"self", bench_run(compiler, c"w.w", c"bin/wbench_out", runs))
	return 0
