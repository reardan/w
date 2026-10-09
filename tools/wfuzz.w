# wbuild: binary=wfuzz
# wbuild: target=wfuzz_test tag=tests dep=wfuzz data=tests/wcoverage/fuzz_target_fixture.w data=tests/wcoverage/fuzz_seeds/seed.w data=tests/wcoverage/fuzz_crash_input.w
# wbuild: step="bin/wv2 --coverage tests/wcoverage/fuzz_target_fixture.w -o bin/wfuzz_fixture"
# wbuild: step="rm -rf bin/wfuzz_test bin/wfuzz_test_again bin/wfuzz_test_min"
# wbuild: step="bin/wfuzz --binary bin/wfuzz_fixture --corpus tests/wcoverage/fuzz_seeds --out bin/wfuzz_test --seed 3 --cases 400" expect_stdout="cases: 400 (" expect_stdout="coverage grew: yes" expect_stdout="crashes: 1" expect_stdout="crash status 139 SIGSEGV: 1 inputs" expect_stdout="hangs: 0" timeout=120000
# wbuild: step="bin/wfuzz --binary bin/wfuzz_fixture --corpus tests/wcoverage/fuzz_seeds --out bin/wfuzz_test_again --seed 3 --cases 400 --fail-on-findings" expect_fail expect_stdout="crashes: 1" timeout=120000
# wbuild: step="diff -r bin/wfuzz_test/corpus bin/wfuzz_test_again/corpus"
# wbuild: step="diff -r bin/wfuzz_test/crashes bin/wfuzz_test_again/crashes"
# wbuild: step="bin/wfuzz --binary bin/wfuzz_fixture --out bin/wfuzz_test_min --minimize tests/wcoverage/fuzz_crash_input.w" expect_stdout="minimized: 11 bytes, status 139" expect_stdout="if (while ("
# wbuild: step="bin/wfuzz --binary bin/wfuzz_fixture --cases 1" expect_fail expect_stderr="wfuzz: --out is required"
# wbuild: target=wfuzz_compiler dep=wfuzz
# wbuild: step="mkdir -p bin/wfuzz_compiler"
# wbuild: step="bin/wv2 --coverage w.w -o bin/wfuzz_compiler/compiler_cov"
# wbuild: step="bin/wfuzz --binary bin/wfuzz_compiler/compiler_cov --arg {} --arg -o --arg {out} --diff bin/wv2 --diff-arg --streaming --diff-arg {} --diff-arg -o --diff-arg {out} --corpus tests --max-len 4096 --out bin/wfuzz_compiler/out" timeout=3600000
/*
wfuzz: coverage-guided fuzzer over --coverage builds
(docs/projects/line_coverage.md, "Fuzzing"; issue #440).

Usage:
  wfuzz --binary <exe> --out <dir> [--arg <a>]... [--seed N]
        [--cases N] [--seconds N] [--corpus <dir>] [--timeout-ms N]
        [--max-len N] [--diff <exe> [--diff-arg <a>]...]
        [--fail-on-findings]
  wfuzz --binary <exe> --out <dir> [--arg <a>]... --minimize <file>

<exe> is built with 'bin/wv2 --coverage', so <exe>.wprofmap exists.
Every case picks a corpus entry, mutates it (tools/fuzz/core.w's
wf_generate, or a stack of byte/token/line/splice edits), writes it to
<out>/work/case.w and runs <exe> with the --arg list ('{}' becomes the
case path, '{out}' a scratch output path; with no --arg the case path
is the only argument), $W_PROFILE_OUT set to a fresh dump and a
--timeout-ms limit (default 10000). Counter indices the run reached
that no earlier run did make the input a new corpus entry, saved to
<out>/corpus/<sha256>.w.

Outcomes: exit status 0 or 1 is normal (for a compiler: compiled or
diagnosed). Any other status, including a signal (128 + signum), is a
crash saved to <out>/crashes/<sha256>.w with a .log next to it holding
the status and the captured stderr; a timeout goes to <out>/hangs/.
Crashed runs flush no counters, so they never grow the corpus.

--diff <exe> adds a differential oracle: every case <exe> under test
exits 0 on is also run as <diff exe> <diff args> (default: the same
--arg list; '{out}' is a second scratch path), and a different exit
status, stdout or '{out}' file is saved to <out>/diffs/ (the two
'{out}' files as <sha256>.out and .out_ref). A seed that
already differs is saved there too but counted apart ("seed diffs"),
and the cases mutated from it skip the oracle, so a known divergence
does not resurface in every descendant.

The initial corpus is every .w file under --corpus (at most --max-len
bytes, default 16384; a seed that adds no coverage is dropped), or
tools/fuzz/core.w's compiler seed texts. The run stops after --cases
cases or --seconds seconds, whichever comes first; with neither,
$WFUZZ_SECONDS seconds (default 300). Case i draws from its own
wf_rng(seed, i) stream, so a --cases run is deterministic for a
deterministic target. The summary goes to stdout and to
<out>/summary.txt; exit status is 0, or 1 with --fail-on-findings when
something was found, or 2 on a usage error.

--minimize <file> runs <file> once and then deletes lines, then byte
runs, keeping every deletion after which the run still ends with the
same status; it writes <file's name>.min.w under <out> and prints the
result.
*/
import lib.lib
import lib.args
import lib.dir
import lib.env
import lib.file
import lib.path
import lib.process
import structures.string
import tools.fuzz.core


struct wfz_run:
	int status         # decoded exit status, or process_status_timeout
	char* stdout_text
	int stdout_length
	char* stderr_text


struct wfz_state:
	char* binary
	list[char*] args
	char* diff_binary
	list[char*] diff_args
	char* out
	char* work
	char* case_path
	char* dump_path
	char* out_path
	char* diff_out_path
	int timeout_ms
	int max_len
	char** env
	char* seen          # one byte per map counter: reached by some run
	int total           # counters in the map
	int covered
	list[char*] corpus
	list[int] corpus_differs   # the entry itself fails the --diff oracle
	int base_differs   # the current case mutates such an entry: no oracle
	int last_differs   # the last wfz_case failed the oracle
	int seed_diffs
	list[char*] found   # hashes of saved findings and corpus entries
	int crashes
	int hangs
	int diffs
	list[int] crash_statuses
	list[int] crash_counts
	list[char*] crash_first


void wfz_fail(char* detail):
	print2(c"wfuzz: ")
	println2(detail)
	exit(2)


void wfz_mkdir(char* path):
	mkdir(path, 493)
	if (path_exists(path) == 0): wfz_fail(f"cannot create {path}")


# The map header is '# wprofmap v1<TAB><arch><TAB><count>'.
int wfz_map_total(char* binary):
	char* map = f"{binary}.wprofmap"
	char* text = file_read_text(map)
	if (text == 0): wfz_fail(f"cannot read {map} (build the binary with --coverage)")
	if (starts_with(text, c"# wprofmap v1") == 0): wfz_fail(f"{map} is not a profile map")
	int i = 0
	int tabs = 0
	while ((text[i] != 0) && (text[i] != '\n') && (tabs < 2)):
		if (text[i] == '\t'): tabs = tabs + 1
		i = i + 1
	int total = atoi(text + i)
	free(text)
	if (total <= 0): wfz_fail(f"{map} has no counters")
	return total


char* wfz_subst(char* arg, char* case_path, char* out_path):
	if (strcmp(arg, c"{}") == 0): return case_path
	if (strcmp(arg, c"{out}") == 0): return out_path
	return arg


wfz_run* wfz_exec(wfz_state* st, char* binary, list[char*] args, char* out_path, char** env):
	int n = args.length
	if (n == 0): n = 1
	char** v = strv_new(n + 1)
	strv_set(v, 0, binary)
	if (args.length == 0): strv_set(v, 1, st.case_path)
	for i in range(args.length): strv_set(v, i + 1, wfz_subst(args[i], st.case_path, out_path))
	spawn_options* opts = spawn_options_new()
	opts.env = env
	opts.new_group = 1
	process_result* r = process_run(binary, v, opts, 0, st.timeout_ms)
	free(opts)
	free(cast(void*, v))
	if (r == 0): wfz_fail(f"cannot run {binary}")
	wfz_run* run = new wfz_run()
	run.status = r.status
	run.stdout_text = r.stdout_text
	run.stdout_length = r.stdout_length
	run.stderr_text = r.stderr_text
	free(r)
	return run


void wfz_run_free(wfz_run* run):
	free(run.stdout_text)
	free(run.stderr_text)
	free(run)


# Marks the dump's counters seen; returns how many were new.
int wfz_absorb(wfz_state* st):
	char* text = file_read_text(st.dump_path)
	if (text == 0): return 0
	int fresh = 0
	int i = 0
	while (text[i] != 0):
		int index = 0
		while ((text[i] >= '0') && (text[i] <= '9')):
			index = index * 10 + (text[i] - '0')
			i = i + 1
		if ((index >= 0) && (index < st.total) && (st.seen[index] == 0)):
			st.seen[index] = 1
			fresh = fresh + 1
		while ((text[i] != 0) && (text[i] != '\n')): i = i + 1
		if (text[i] == '\n'): i = i + 1
	free(text)
	st.covered = st.covered + fresh
	return fresh


int wfz_known(wfz_state* st, char* hash):
	for char* h in st.found:
		if (strcmp(h, hash) == 0): return 1
	return 0


char* wfz_signal_name(int status):
	if (status == 132): return c"SIGILL"
	if (status == 133): return c"SIGTRAP"
	if (status == 134): return c"SIGABRT"
	if (status == 135): return c"SIGBUS"
	if (status == 136): return c"SIGFPE"
	if (status == 137): return c"SIGKILL"
	if (status == 139): return c"SIGSEGV"
	return c""


# Saves text under <out>/<kind>/<hash>.w (once per input) with a .log.
void wfz_save(wfz_state* st, char* kind, char* text, char* hash, char* log):
	char* base = f"{st.out}/{kind}/{hash}"
	wf_write(f"{base}.w", text)
	if (log != 0): wf_write(f"{base}.log", log)


char* wfz_log(int case_id, wfz_run* run):
	string_builder* b = string_new()
	string_append(b, f"case {case_id}\nstatus {run.status}")
	char* name = wfz_signal_name(run.status)
	if (name[0] != 0): string_append(b, f" ({name})")
	string_append(b, c"\n--- stderr\n")
	string_append(b, run.stderr_text)
	char* text = strclone(b.data)
	string_free(b)
	return text


void wfz_note_crash(wfz_state* st, int status, char* path):
	for i in range(st.crash_statuses.length):
		if (st.crash_statuses[i] == status):
			st.crash_counts[i] = st.crash_counts[i] + 1
			return
	st.crash_statuses.push(status)
	st.crash_counts.push(1)
	st.crash_first.push(path)


# "missing" or the sha256 of the file at path.
char* wfz_describe(char* path):
	if (path_exists(path) == 0): return c"missing"
	return wf_file_hash(path)


# 1 when the reference run disagrees with the instrumented one.
int wfz_differs(wfz_state* st, wfz_run* a, wfz_run* b):
	if (a.status != b.status): return 1
	if (a.stdout_length != b.stdout_length): return 1
	if (strcmp(a.stdout_text, b.stdout_text) != 0): return 1
	int has_a = path_exists(st.out_path)
	int has_b = path_exists(st.diff_out_path)
	if (has_a != has_b): return 1
	if (has_a == 0): return 0
	char* ha = wf_file_hash(st.out_path)
	char* hb = wf_file_hash(st.diff_out_path)
	int differ = strcmp(ha, hb) != 0
	free(ha)
	free(hb)
	return differ


# Runs one input; returns the number of new counters it reached
# (0 for a crash, hang or difference, which are recorded instead).
int wfz_case(wfz_state* st, int case_id, char* text):
	wf_write(st.case_path, text)
	unlink(st.dump_path)
	unlink(st.out_path)
	wfz_run* run = wfz_exec(st, st.binary, st.args, st.out_path, st.env)
	int fresh = 0
	st.last_differs = 0
	char* hash = wf_hash(text, strlen(text))
	if (run.status == process_status_timeout):
		if (wfz_known(st, hash) == 0):
			st.found.push(hash)
			st.hangs = st.hangs + 1
			wfz_save(st, c"hangs", text, hash, f"case {case_id}\ntimeout after {st.timeout_ms} ms\n")
			println2(f"wfuzz: case {case_id}: hang, saved {st.out}/hangs/{hash}.w")
	elif ((run.status != 0) && (run.status != 1)):
		if (wfz_known(st, hash) == 0):
			st.found.push(hash)
			st.crashes = st.crashes + 1
			wfz_save(st, c"crashes", text, hash, wfz_log(case_id, run))
			wfz_note_crash(st, run.status, f"{st.out}/crashes/{hash}.w")
			println2(f"wfuzz: case {case_id}: crash, status {run.status}, saved {st.out}/crashes/{hash}.w")
	else:
		fresh = wfz_absorb(st)
		if ((run.status == 0) && (st.diff_binary != 0) && (st.base_differs == 0)):
			unlink(st.diff_out_path)
			wfz_run* ref = wfz_exec(st, st.diff_binary, st.diff_args, st.diff_out_path, 0)
			if (wfz_differs(st, run, ref)):
				st.last_differs = 1
				if (wfz_known(st, hash) == 0):
					st.found.push(hash)
					if (case_id < 0): st.seed_diffs = st.seed_diffs + 1
					else: st.diffs = st.diffs + 1
					char* outputs = f"{wfz_describe(st.out_path)} vs {wfz_describe(st.diff_out_path)}"
					char* log = f"case {case_id}\nstatus {run.status} vs {ref.status}\nstdout {run.stdout_length} vs {ref.stdout_length} bytes\noutput {outputs}\n--- stderr\n{run.stderr_text}--- reference stderr\n{ref.stderr_text}"
					wfz_save(st, c"diffs", text, hash, log)
					# Keep both outputs for inspection (absent ones stay absent).
					rename(st.out_path, f"{st.out}/diffs/{hash}.out")
					rename(st.diff_out_path, f"{st.out}/diffs/{hash}.out_ref")
					println2(f"wfuzz: case {case_id}: difference, saved {st.out}/diffs/{hash}.w")
			wfz_run_free(ref)
	wfz_run_free(run)
	return fresh


/* Mutation */

# tools/fuzz/core.w's wf_generate alphabet.
int wfz_char(prng* r):
	return c"\t\n :()[]{}#\"'0129+-*/&|<>abcdefghijklmnopqrstuvwxyz"[prng_range(r, 49)]


char* wfz_token(prng* r):
	int k = prng_range(r, 48)
	if (k == 0): return c"\n"
	if (k == 1): return c"\n\t"
	if (k == 2): return c"\n\t\t"
	if (k == 3): return c":\n\t"
	if (k == 4): return c"int "
	if (k == 5): return c"char* "
	if (k == 6): return c"byte "
	if (k == 7): return c"int64 "
	if (k == 8): return c"float "
	if (k == 9): return c"void "
	if (k == 10): return c"struct "
	if (k == 11): return c"if ("
	if (k == 12): return c"elif ("
	if (k == 13): return c"else:"
	if (k == 14): return c"while ("
	if (k == 15): return c"for i in range("
	if (k == 16): return c"return "
	if (k == 17): return c"break"
	if (k == 18): return c"continue"
	if (k == 19): return c"import lib.lib\n"
	if (k == 20): return c"new "
	if (k == 21): return c"list[int]"
	if (k == 22): return c"map[int, int]"
	if (k == 23): return c"cast(int, "
	if (k == 24): return c"sizeof("
	if (k == 25): return c"c\""
	if (k == 26): return c"f\"{"
	if (k == 27): return c"defer "
	if (k == 28): return c"fn("
	if (k == 29): return c"const "
	if (k == 30): return c"type "
	if (k == 31): return c"enum "
	if (k == 32): return c"0"
	if (k == 33): return c"-1"
	if (k == 34): return c"255"
	if (k == 35): return c"2147483647"
	if (k == 36): return c"-2147483648"
	if (k == 37): return c"0xffffffff"
	if (k == 38): return c"1.5"
	if (k == 39): return c" == "
	if (k == 40): return c" && "
	if (k == 41): return c" << "
	if (k == 42): return c" = "
	if (k == 43): return c"*"
	if (k == 44): return c"&"
	if (k == 45): return c"."
	if (k == 46): return c", "
	return c"[0]"


# text[0:pos] + insert[0:insert_length] + text[pos + remove:], capped.
char* wfz_edit(char* text, int pos, int remove, char* insert, int insert_length, int max_len):
	int length = strlen(text)
	if (pos > length): pos = length
	if (pos + remove > length): remove = length - pos
	string_builder* b = string_new()
	string_append_bytes(b, text, pos)
	string_append_bytes(b, insert, insert_length)
	string_append_bytes(b, text + pos + remove, length - pos - remove)
	if (b.length > max_len):
		b.length = max_len
		b.data[max_len] = 0
	char* out = strclone(b.data)
	string_free(b)
	return out


int wfz_line_start(char* text, int pos):
	while ((pos > 0) && (text[pos - 1] != '\n')): pos = pos - 1
	return pos


int wfz_line_end(char* text, int pos):
	while ((text[pos] != 0) && (text[pos] != '\n')): pos = pos + 1
	if (text[pos] == '\n'): pos = pos + 1
	return pos


char* wfz_mutate_once(wfz_state* st, prng* r, char* text):
	int length = strlen(text)
	int pos = prng_range(r, length + 1)
	int action = prng_range(r, 10)
	char* one = cast(char*, malloc(2))
	one[1] = 0
	if ((action == 0) && (pos < length)):
		one[0] = wfz_char(r)
		return wfz_edit(text, pos, 1, one, 1, st.max_len)
	if (action == 1):
		one[0] = wfz_char(r)
		return wfz_edit(text, pos, 0, one, 1, st.max_len)
	if (action == 2):
		return wfz_edit(text, pos, 1 + prng_range(r, 8), c"", 0, st.max_len)
	if ((action == 3) || (action == 8)):
		char* token = wfz_token(r)
		return wfz_edit(text, pos, 0, token, strlen(token), st.max_len)
	if (action == 9):
		char* replacement = wfz_token(r)
		return wfz_edit(text, pos, strlen(replacement), replacement, strlen(replacement), st.max_len)
	int start = wfz_line_start(text, pos)
	int end = wfz_line_end(text, pos)
	if (action == 4):
		# Duplicate the line under pos.
		return wfz_edit(text, end, 0, text + start, end - start, st.max_len)
	if (action == 5):
		return wfz_edit(text, start, end - start, c"", 0, st.max_len)
	if (action == 6):
		# Splice in a span of another corpus entry.
		char* other = st.corpus[prng_range(r, st.corpus.length)]
		int other_length = strlen(other)
		int from = prng_range(r, other_length + 1)
		int span = 1 + prng_range(r, 64)
		if (from + span > other_length): span = other_length - from
		return wfz_edit(text, pos, 0, other + from, span, st.max_len)
	# Move a line to another spot.
	int to = wfz_line_start(text, prng_range(r, length + 1))
	char* line = path_clone_range(text + start, end - start)
	char* without = wfz_edit(text, start, end - start, c"", 0, st.max_len)
	if (to > strlen(without)): to = strlen(without)
	char* moved = wfz_edit(without, to, 0, line, end - start, st.max_len)
	free(line)
	free(without)
	return moved


char* wfz_mutate(wfz_state* st, int seed, int case_id):
	prng* r = wf_rng(seed, case_id)
	# A third of the cases build on the newest entry: what was just
	# reached is the likeliest step to the next new counter.
	int which = st.corpus.length - 1
	if (prng_range(r, 3) != 0): which = prng_range(r, st.corpus.length)
	char* base = st.corpus[which]
	st.base_differs = st.corpus_differs[which]
	if (prng_range(r, 8) == 0):
		prng_free(r)
		return wf_generate(c"compiler", seed, case_id, base)
	char* text = strclone(base)
	int count = 1 + prng_range(r, 4)
	for i in range(count):
		char* next = wfz_mutate_once(st, r, text)
		free(text)
		text = next
	prng_free(r)
	return text


/* Driver */

wfz_state* wfz_state_new(char* binary, char* out):
	wfz_state* st = new wfz_state()
	st.binary = binary
	st.args = new list[char*]
	st.diff_binary = 0
	st.diff_args = new list[char*]
	st.out = out
	st.timeout_ms = 10000
	st.max_len = 16384
	st.corpus = new list[char*]
	st.corpus_differs = new list[int]
	st.base_differs = 0
	st.last_differs = 0
	st.seed_diffs = 0
	st.found = new list[char*]
	st.crash_statuses = new list[int]
	st.crash_counts = new list[int]
	st.crash_first = new list[char*]
	return st


void wfz_prepare(wfz_state* st):
	st.total = wfz_map_total(st.binary)
	st.seen = cast(char*, malloc(st.total))
	for i in range(st.total): st.seen[i] = 0
	st.covered = 0
	wfz_mkdir(st.out)
	st.work = f"{st.out}/work"
	wfz_mkdir(st.work)
	wfz_mkdir(f"{st.out}/corpus")
	wfz_mkdir(f"{st.out}/crashes")
	wfz_mkdir(f"{st.out}/hangs")
	wfz_mkdir(f"{st.out}/diffs")
	st.case_path = f"{st.work}/case.w"
	st.dump_path = f"{st.work}/case.raw"
	st.out_path = f"{st.work}/out"
	st.diff_out_path = f"{st.work}/out_ref"
	# An absolute dump path: the target may change directory.
	char* dump = st.dump_path
	if (dump[0] != '/'):
		char* cwd = cast(char*, malloc(4096))
		if (getcwd(cwd, 4096) > 0): dump = f"{cwd}/{dump}"
	st.env = env_copy_with(env_current(), c"W_PROFILE_OUT", dump)


void wfz_load_seeds(wfz_state* st, char* corpus_dir):
	list[char*] texts = new list[char*]
	if (corpus_dir != 0):
		list[char*] files = new list[char*]
		dir_walk_files(corpus_dir, files)
		for char* path in files:
			if (ends_with(path, c".w")):
				char* text = file_read_text(path)
				if ((text != 0) && (strlen(text) <= st.max_len)): texts.push(text)
		if (texts.length == 0): wfz_fail(f"no .w seeds under {corpus_dir}")
	else:
		for i in range(3): texts.push(wf_seed_text(c"compiler", i))
	int done = 0
	for char* text in texts:
		done = done + 1
		if (done % 100 == 0): println2(f"wfuzz: {done}/{texts.length} seeds run, {st.covered}/{st.total} counters")
		if (wfz_case(st, -1, text) > 0):
			st.corpus.push(text)
			st.corpus_differs.push(st.last_differs)
	if (st.corpus.length == 0):
		st.corpus.push(texts[0])
		st.corpus_differs.push(0)


int wfz_minimize(wfz_state* st, char* path):
	char* text = file_read_text(path)
	if (text == 0): wfz_fail(f"cannot read {path}")
	wf_write(st.case_path, text)
	wfz_run* first = wfz_exec(st, st.binary, st.args, st.out_path, st.env)
	int status = first.status
	wfz_run_free(first)
	# Whole lines first, then single bytes.
	int phase = 0
	while (phase < 2):
		int pos = 0
		while (text[pos] != 0):
			int end = wfz_line_end(text, pos)
			if (phase == 1): end = pos + 1
			char* shorter = wfz_edit(text, pos, end - pos, c"", 0, st.max_len)
			wf_write(st.case_path, shorter)
			wfz_run* run = wfz_exec(st, st.binary, st.args, st.out_path, st.env)
			if (run.status == status):
				free(text)
				text = shorter
			else:
				free(shorter)
				if (phase == 0): pos = wfz_line_end(text, pos)
				else: pos = pos + 1
			wfz_run_free(run)
		phase = phase + 1
	char* name = path_basename(path)
	char* out = f"{st.out}/{name}.min.w"
	wf_write(out, text)
	println(f"minimized: {strlen(text)} bytes, status {status}, written to {out}")
	println(c"--- input")
	print(text)
	if ((strlen(text) > 0) && (text[strlen(text) - 1] != '\n')): println(c"")
	return 0


void wfz_summary(wfz_state* st, int cases, int seeds_covered, int elapsed_ms):
	string_builder* b = string_new()
	string_append(b, f"binary: {st.binary}\n")
	string_append(b, f"cases: {cases} ({elapsed_ms / 1000} s)\n")
	string_append(b, f"corpus: {st.corpus.length}\n")
	string_append(b, f"coverage: {st.covered}/{st.total} counters (seeds alone: {seeds_covered})\n")
	char* grew = c"no"
	if (st.covered > seeds_covered): grew = c"yes"
	string_append(b, f"coverage grew: {grew}\n")
	string_append(b, f"crashes: {st.crashes}\n")
	for i in range(st.crash_statuses.length):
		int status = st.crash_statuses[i]
		char* name = wfz_signal_name(status)
		int count = st.crash_counts[i]
		char* first = st.crash_first[i]
		string_append(b, f"  crash status {status} {name}: {count} inputs, first {first}\n")
	string_append(b, f"hangs: {st.hangs}\n")
	string_append(b, f"diffs: {st.diffs}\n")
	if (st.seed_diffs > 0): string_append(b, f"seed diffs: {st.seed_diffs} (corpus inputs that already differ; their mutants skip the oracle)\n")
	print(b.data)
	wf_write(f"{st.out}/summary.txt", b.data)
	string_free(b)


int main(int argc, int argv):
	args_init(argc, argv)
	char* binary = 0
	char* out = 0
	char* corpus_dir = 0
	char* minimize = 0
	int seed = 1
	int cases = -1
	int seconds = -1
	int fail_on_findings = 0
	list[char*] args = new list[char*]
	list[char*] diff_args = new list[char*]
	char* diff_binary = 0
	int timeout_ms = 10000
	int max_len = 16384
	int i = 1
	while (i < args_count()):
		char* a = args_get(i)
		int has_next = i + 1 < args_count()
		char* v = c""
		if (has_next): v = args_get(i + 1)
		int takes = 1
		if (strcmp(a, c"--fail-on-findings") == 0):
			fail_on_findings = 1
			takes = 0
		elif (has_next == 0): wfz_fail(f"{a} needs a value (or is unknown)")
		elif (strcmp(a, c"--binary") == 0): binary = v
		elif (strcmp(a, c"--out") == 0): out = v
		elif (strcmp(a, c"--arg") == 0): args.push(v)
		elif (strcmp(a, c"--seed") == 0): seed = atoi(v)
		elif (strcmp(a, c"--cases") == 0): cases = atoi(v)
		elif (strcmp(a, c"--seconds") == 0): seconds = atoi(v)
		elif (strcmp(a, c"--corpus") == 0): corpus_dir = v
		elif (strcmp(a, c"--timeout-ms") == 0): timeout_ms = atoi(v)
		elif (strcmp(a, c"--max-len") == 0): max_len = atoi(v)
		elif (strcmp(a, c"--diff") == 0): diff_binary = v
		elif (strcmp(a, c"--diff-arg") == 0): diff_args.push(v)
		elif (strcmp(a, c"--minimize") == 0): minimize = v
		else: wfz_fail(f"unknown option {a}")
		i = i + 1 + takes
	if (binary == 0): wfz_fail(c"--binary is required")
	if (out == 0): wfz_fail(c"--out is required")
	wfz_state* st = wfz_state_new(binary, out)
	st.args = args
	st.timeout_ms = timeout_ms
	st.max_len = max_len
	st.diff_binary = diff_binary
	st.diff_args = diff_args
	if ((diff_binary != 0) && (diff_args.length == 0)): st.diff_args = args
	wfz_prepare(st)
	if (minimize != 0): return wfz_minimize(st, minimize)
	if ((cases < 0) && (seconds < 0)):
		seconds = 300
		char* env_seconds = env_get(c"WFUZZ_SECONDS")
		if (env_seconds != 0): seconds = atoi(env_seconds)
	int started = process_monotonic_ms()
	wfz_load_seeds(st, corpus_dir)
	int seeds_covered = st.covered
	println2(f"wfuzz: {st.corpus.length} seeds, {seeds_covered}/{st.total} counters")
	int done = 0
	while ((cases < 0) || (done < cases)):
		if ((seconds >= 0) && (process_monotonic_ms() - started >= seconds * 1000)): break
		char* text = wfz_mutate(st, seed, done)
		if (wfz_case(st, done, text) > 0):
			char* hash = wf_hash(text, strlen(text))
			if (wfz_known(st, hash) == 0):
				st.found.push(hash)
				st.corpus.push(text)
				st.corpus_differs.push(st.last_differs)
				wf_write(f"{st.out}/corpus/{hash}.w", text)
				println2(f"wfuzz: case {done}: new coverage, {st.covered}/{st.total} counters, corpus {st.corpus.length}")
			else: free(text)
		else: free(text)
		done = done + 1
		if (done % 500 == 0):
			println2(f"wfuzz: {done} cases, corpus {st.corpus.length}, {st.covered}/{st.total} counters, {st.crashes} crashes, {st.hangs} hangs, {st.diffs} diffs")
	wfz_summary(st, done, seeds_covered, process_monotonic_ms() - started)
	if (fail_on_findings && (st.crashes + st.hangs + st.diffs > 0)): return 1
	return 0
