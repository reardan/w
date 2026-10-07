# bench regex_backtrack: lib/regex.w's recursive backtracking matcher
# (rx_here was 74% of regex_test, docs/projects/register_allocation_pgo.md
# §1.2). Each round runs one pathological match that exhausts the step
# budget (a*a*a*a*b against a run of a's) and a handful of ordinary
# searches over a generated 16 KB text; size = rounds. The checksum
# folds every result. C twin: tests/bench/c/regex_backtrack.c, a port of
# lib/regex.w.
# wbuild: target=bench_regex_backtrack tag=bench dep=wv2
# wbuild: step="bin/wv2 tests/bench/regex_backtrack.w -o bin/bench_regex_backtrack"
# wbuild: step="bin/bench_regex_backtrack" expect_stdout="regex_backtrack size=24 checksum=ceddedd0"
# wbuild: step="bin/wv2 x64 tests/bench/regex_backtrack.w -o bin/bench_regex_backtrack_64"
# wbuild: step="bin/bench_regex_backtrack_64" expect_stdout="regex_backtrack size=24 checksum=ceddedd0"
# wbuild: target=bench_regex_backtrack_smoke_test tag=tests dep=wv2
# wbuild: step="bin/wv2 tests/bench/regex_backtrack.w -o bin/bench_regex_backtrack_smoke"
# wbuild: step="bin/bench_regex_backtrack_smoke 1" expect_stdout="regex_backtrack size=1 checksum=1514b1fe"
# wbuild: step="bin/wv2 x64 tests/bench/regex_backtrack.w -o bin/bench_regex_backtrack_smoke_64"
# wbuild: step="bin/bench_regex_backtrack_smoke_64 1" expect_stdout="regex_backtrack size=1 checksum=1514b1fe"
import lib.lib
import lib.regex
import tests.bench.bench_lib


# A deterministic lowercase text with spaces and newlines, length n.
char* rb_text(int n):
	char* text = malloc(n + 1)
	int state = 123456789
	int i = 0
	while (i < n):
		int r = bench_rand(&state) & 63
		if (r < 48): text[i] = 'a' + ((bench_rand(&state) & 0x7fffffff) % 26)
		else if (r < 62): text[i] = ' '
		else: text[i] = 10
		i = i + 1
	text[n] = 0
	return text


int main(int argc, char** argv):
	int rounds = bench_size(argc, argv, 24)
	char* text = rb_text(16384)
	char* run = malloc(65)
	int i = 0
	while (i < 64):
		run[i] = 'a'
		i = i + 1
	run[64] = 0
	int h = 0
	int r = 0
	while (r < rounds):
		# Exponential backtracking, cut off by RX_STEP_BUDGET.
		h = bench_fold(h, regex_match(c"a*a*a*a*b", run))
		# Ordinary searches: a literal, a class with a quantifier, an
		# anchored tail, a dot-star and a per-line scan.
		h = bench_fold(h, regex_search(c"zq", text))
		h = bench_fold(h, regex_search(c"[a-m]+ [n-z]+ [a-m]+ q", text))
		h = bench_fold(h, regex_search(c"x.*y.*zz$", text))
		h = bench_fold(h, regex_search(c"qu[aeiou]+x", text))
		int pos = 0
		int lines = 0
		while (text[pos] != 0):
			int len = regex_match_length(c"[a-z ]*[aeiou]q", text, pos)
			if (len > 0): lines = lines + 1
			while ((text[pos] != 0) && (text[pos] != 10)): pos = pos + 1
			if (text[pos] == 10): pos = pos + 1
		h = bench_fold(h, lines)
		r = r + 1
	bench_report(c"regex_backtrack", rounds, h)
	return 0
