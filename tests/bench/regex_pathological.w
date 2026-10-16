# bench regex_pathological: the patterns that blow up a backtracking
# matcher, run through lib/regex.w and libs/standard/text/re.w's Pike
# VM, which are linear in len(text) * len(pattern). size = the length of
# the run of a's, and time grows linearly with it (4x the size is ~4x
# the time), where a backtracker grows exponentially. Before the P1.1c
# port, lib/regex.w's step budget cut these off: regex_search of
# a*...a*b over "aaa...axb" returned -1 (wrong) instead of the index of
# the b. The checksum folds every
# answer's distance from the right one, so a regression to a budgeted
# matcher changes the line and an exponential one trips the smoke
# target's timeout.
# wbuild: target=bench_regex_pathological tag=bench dep=wv2
# wbuild: step="bin/wv2 tests/bench/regex_pathological.w -o bin/bench_regex_pathological"
# wbuild: step="bin/bench_regex_pathological" expect_stdout="regex_pathological size=400000 checksum=00000000"
# wbuild: step="bin/wv2 x64 tests/bench/regex_pathological.w -o bin/bench_regex_pathological_64"
# wbuild: step="bin/bench_regex_pathological_64" expect_stdout="regex_pathological size=400000 checksum=00000000"
# wbuild: target=bench_regex_pathological_smoke_test tag=tests dep=wv2
# wbuild: step="bin/wv2 tests/bench/regex_pathological.w -o bin/bench_regex_pathological_smoke"
# wbuild: step="bin/bench_regex_pathological_smoke 20000" expect_stdout="regex_pathological size=20000 checksum=00000000" timeout=60000
# wbuild: step="bin/wv2 x64 tests/bench/regex_pathological.w -o bin/bench_regex_pathological_smoke_64"
# wbuild: step="bin/bench_regex_pathological_smoke_64 20000" expect_stdout="regex_pathological size=20000 checksum=00000000" timeout=60000
import lib.lib
import lib.regex
import libs.standard.text.re
import tests.bench.bench_lib


# n a's followed by tail (malloc'd).
char* rp_run(int n, char* tail):
	int t = strlen(tail)
	char* text = cast(char*, malloc(n + t + 1))
	for i in range(n): text[i] = 'a'
	for k in range(t): text[n + k] = tail[k]
	text[n + t] = 0
	return text


# Start of the first re.w match of pattern in text, or -1.
int rp_re_search(char* pattern, char* text):
	re_pattern* p = re_compile(pattern, 0)
	re_result* m = re_search(p, text)
	re_free(p)
	if (m == 0): return -1
	int at = re_start(m, 0)
	re_result_free(m)
	return at


# End of the re.w fullmatch of pattern on text, or -1.
int rp_re_fullmatch(char* pattern, char* text):
	re_pattern* p = re_compile(pattern, 0)
	re_result* m = re_fullmatch(p, text)
	re_free(p)
	if (m == 0): return -1
	int end = re_end(m, 0)
	re_result_free(m)
	return end


int main(int argc, char** argv):
	int n = bench_size(argc, argv, 400000)
	char* run = rp_run(n, c"")
	char* run_xb = rp_run(n, c"xb")
	char* run_b = rp_run(n, c"b")
	char* thirty = rp_run(30, c"")
	# Each term folds (answer - correct answer), so the checksum is
	# 00000000 at every size exactly when every answer is right.
	int h = 0
	# lib/regex.w: stacked stars with no match, a match only at the
	# end of the text, and a greedy span over the whole run.
	h = bench_fold(h, regex_match(c"a*a*a*a*a*a*a*a*a*b", run))
	h = bench_fold(h, regex_search(c"a*a*a*a*a*a*a*a*a*b", run_xb) - (n + 1))
	h = bench_fold(h, regex_match_length(c"a*a*a*a*a*a*a*a*a*b", run_b, 0) - (n + 1))
	# re.w: nested and ambiguous repetition.
	h = bench_fold(h, rp_re_search(c"(a*)*b", run) + 1)
	h = bench_fold(h, rp_re_search(c"(a|a)*b", run_xb) - (n + 1))
	h = bench_fold(h, rp_re_fullmatch(c"(a|aa)*", run) - n)
	h = bench_fold(h, rp_re_fullmatch(c"(a?){30}a{30}", thirty) - 30)
	free(run)
	free(run_xb)
	free(run_b)
	free(thirty)
	bench_report(c"regex_pathological", n, h)
	return 0
