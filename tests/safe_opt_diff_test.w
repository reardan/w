# wbuild: x64
# wbuild: timeout=1800000
# wbuild: deps=tests/safe_opt_order_fixture.w deps=tests/safe_opt_order_manual_fixture.w deps=tests/safe_opt_bounds_fixture.w deps=tests/safe_opt_log.w
# wbuild: deps=tests/safe_aggregate_groups_runtime_fixture.w deps=tests/safe_aggregate_runtime_fixture.w deps=tests/safe_arena_runtime_fixture.w
# wbuild: deps=tests/safe_buffer_prototype_runtime_fixture.w deps=tests/safe_callable_runtime_fixture.w deps=tests/safe_callback_storage_runtime_fixture.w
# wbuild: deps=tests/safe_collection_runtime_fixture.w deps=tests/safe_control_flow_runtime_fixture.w deps=tests/safe_disjoint_field_runtime_fixture.w
# wbuild: deps=tests/safe_extension_runtime_fixture.w deps=tests/safe_generic_inference_runtime_fixture.w deps=tests/safe_generic_method_runtime_fixture.w
# wbuild: deps=tests/safe_generic_runtime_fixture.w deps=tests/safe_generic_shape_runtime_fixture.w deps=tests/safe_methods_runtime_fixture.w
# wbuild: deps=tests/safe_mixed_owner_exclusive_runtime_fixture.w deps=tests/safe_mixed_owner_runtime_fixture.w deps=tests/safe_mixed_owner_views_runtime_fixture.w
# wbuild: deps=tests/safe_mutable_record_runtime_fixture.w deps=tests/safe_mutable_view_runtime_fixture.w deps=tests/safe_nested_aggregate_runtime_fixture.w
# wbuild: deps=tests/safe_nested_move_runtime_fixture.w deps=tests/safe_nested_replacement_runtime_fixture.w deps=tests/safe_optional_field_runtime_fixture.w
# wbuild: deps=tests/safe_optional_owner_runtime_fixture.w deps=tests/safe_optional_runtime_fixture.w deps=tests/safe_optional_view_runtime_fixture.w
# wbuild: deps=tests/safe_outlives_runtime_fixture.w deps=tests/safe_owned_aggregate_runtime_fixture.w deps=tests/safe_owned_buffer_runtime_fixture.w
# wbuild: deps=tests/safe_owned_field_runtime_fixture.w deps=tests/safe_partial_move_runtime_fixture.w deps=tests/safe_qualified_inference_runtime_fixture.w
# wbuild: deps=tests/safe_reference_field_runtime_fixture.w deps=tests/safe_runtime_fixture.w deps=tests/safe_scalar_field_runtime_fixture.w
# wbuild: deps=tests/safe_scoped_defer_runtime_fixture.w deps=tests/safe_slice_runtime_fixture.w deps=tests/safe_sync_runtime_fixture.w
# wbuild: deps=tests/safe_thread_runtime_fixture.w deps=tests/safe_win64_runtime_fixture.w
/*
Ownership-preserving optimization: differential validation (#714,
docs/projects/safe_mode.md "Ownership-preserving optimization
validation").

Every checked runtime fixture (tests/safe_*_runtime_fixture.w, found by
listing tests/, plus tests/safe_runtime_fixture.w) and the logging
fixtures tests/safe_opt_order_fixture.w and tests/safe_opt_bounds_fixture.w
are compiled under every optimization configuration the compiler offers
for this test's word size (the x86 build checks x86, the x64 twin
checks x64): the defaults, -O0, each single opt-out (--no-regs,
--no-inline, --no-cond-branch, --no-loop-rotate, --no-expr-regs,
--no-addr-modes, --no-direct-calls, --no-narrow-regs, and --no-x86-budget
on x86 or --no-ivopts / --no-reg-args on x64), all opt-outs together,
--inline, the C3.5 optimizer (--ast-opt), and --inline with a
--profile-use profile that marks every function of the fixture hot
(generated from 'bin/wv2 defhash', so even bodies that call are inlining
candidates). Each binary runs with W_DEBUG_ALLOC=1 and must match the
'-O0 --no-inline' build exactly: exit status, stdout, and stderr less
stack-trace frames (inlining legitimately removes frames). The logging
fixtures print a line for every destruction ("drop n", from the free
hook in tests/safe_opt_log.w), transfer point and deferred action
("mark n"), so the comparison covers drop order, deferred-work order and
transfer points, not just results; they also compile with --safe, and
the --safe builds must print the same log as the plain reference.

tests/safe_opt_order_manual_fixture.w performs the same work with raw
pointers and explicit free() calls: under every configuration its output
must equal the checked program's reference (checked cleanup costs no
observable behaviour against hand-written cleanup).

tests/safe_opt_bounds_fixture.w runs once per SAFE_OPT_CASE: case 0
must exit 0, and cases 1-6 must exit nonzero with "index out of range"
on stderr after the same log, under every configuration -- the checks
in optimized loops, inlined leaves and slice views still trap at the
same point.

The inliner refuses functions with checked parameters, results or
declarations (compiler/inline_table.w, code_generator/statement_ast.w).
With '-v -v -v --inline' and the all-hot profile, the test asserts that
every such function of the two logging fixtures is refused
('inline_body_end(..., ok=0') and never inlined, that their scalar
neighbours are recorded, that a scalar wrapper moving an owner between
two refused calls (opt_feed) and a scalar leaf with an index check
(bounds_pick) really are inlined, and that the manual twin's raw
versions of the refused functions are recorded (the refusal is about
checked types, not body shape; that compile uses plain --inline).
*/
import lib.lib
import lib.assert
import lib.process
import lib.file
import lib.env
import lib.dir
import lib.str


int arch64
int failures
int comparisons


char* scratch():
	if (arch64): return c"bin/safe_opt_diff64"
	return c"bin/safe_opt_diff"


char* reference_flags():
	return c"-O0 --no-inline"


# The configurations compared against reference_flags(); "HOT" stands
# for --profile-use=<the fixture's all-hot profile>.
list[char*] configurations():
	list[char*] c = new list[char*]
	c.push(c"")
	c.push(c"-O0")
	c.push(c"--no-regs")
	c.push(c"--no-inline")
	c.push(c"--inline")
	c.push(c"--ast-opt")
	c.push(c"--no-cond-branch")
	c.push(c"--no-loop-rotate")
	c.push(c"--no-expr-regs")
	c.push(c"--no-addr-modes")
	c.push(c"--no-direct-calls")
	c.push(c"--no-narrow-regs")
	if (arch64):
		c.push(c"--no-ivopts")
		c.push(c"--no-reg-args")
	else:
		c.push(c"--no-x86-budget")
	c.push(c"--no-regs --no-direct-calls --no-cond-branch --no-addr-modes --no-loop-rotate --no-expr-regs --no-narrow-regs --no-x86-budget --no-inline --no-ivopts --no-reg-args")
	c.push(c"--inline HOT")
	return c


# Configurations added for fixtures that also compile with --safe.
list[char*] safe_configurations():
	list[char*] c = new list[char*]
	c.push(c"--safe")
	c.push(c"--safe -O0 --no-inline")
	c.push(c"--safe --inline HOT")
	return c


void fail(char* what, char* name, char* config, char* detail):
	failures = failures + 1
	print(c"safe_opt_diff: ")
	print(what)
	print(c": ")
	print(name)
	print(c" [")
	print(config)
	print(c"]")
	if (detail != 0):
		print(c"\n  ")
		print(detail)
	println(c"")


# Splits flags on spaces into argv after bin/wv2 --quiet [x64].
char** compile_argv(char* flags, char* profile, char* src, char* out, int verbose):
	char** argv = strv_new(40)
	int n = 0
	argv[n] = c"bin/wv2"
	n = n + 1
	if (verbose == 0):
		argv[n] = c"--quiet"
		n = n + 1
	if (arch64):
		argv[n] = c"x64"
		n = n + 1
	for v in range(verbose):
		argv[n] = c"-v"
		n = n + 1
	int len = strlen(flags)
	int start = 0
	while (start < len):
		int end = start
		while ((end < len) && (flags[end] != ' ')): end = end + 1
		if (end > start):
			char* word = str_copy_range(flags, start, end)
			if (strcmp(word, c"HOT") == 0): word = strjoin(c"--profile-use=", profile)
			argv[n] = word
			n = n + 1
		start = end + 1
	argv[n] = src
	argv[n + 1] = c"-o"
	argv[n + 2] = out
	return argv


process_result* run_argv(char** argv, char** env):
	spawn_options* opts = spawn_options_new()
	opts.env = env
	process_result* r = process_run(argv[0], argv, opts, 0, 120000)
	free(opts)
	asserts(c"process_run", r != 0)
	return r


# The fixture's base name without directory and ".w".
char* base_name(char* src):
	int len = strlen(src)
	int start = len
	while ((start > 0) && (src[start - 1] != '/')): start = start - 1
	return str_copy_range(src, start, len - 2)


# The string value following key in one NDJSON line, or 0.
char* json_field(char* line, char* key):
	int at = index_of(line, key)
	if (at < 0): return 0
	int start = at + strlen(key)
	int end = start
	while ((line[end] != 0) && (line[end] != '"')): end = end + 1
	return str_copy_range(line, start, end)


# Writes an all-hot profile for src's own functions (bin/wv2 defhash)
# and returns its path.
char* hot_profile(char* src):
	char* path = strjoin(strjoin(strjoin(scratch(), c"/"), base_name(src)), c".wprof")
	char** argv = strv_new(4)
	argv[0] = c"bin/wv2"
	argv[1] = c"defhash"
	if (arch64):
		argv[2] = c"x64"
		argv[3] = src
	else: argv[2] = src
	process_result* r = run_argv(argv, 0)
	if (r.status != 0):
		fail(c"defhash failed", src, c"", r.stderr_text)
		return path
	char* text = r.stdout_text
	char* out = c""
	int i = 0
	int functions = 0
	while (text[i] != 0):
		int end = i
		while ((text[end] != 0) && (text[end] != 10)): end = end + 1
		char* line = str_copy_range(text, i, end)
		char* name = json_field(line, c"\"name\": \"")
		char* hash = json_field(line, c"\"hash\": \"")
		if (contains(line, c"\"kind\": \"function\"") && (name != 0) && (hash != 0)):
			out = strjoin(out, strjoin(c"f ", strjoin(hash, strjoin(c" ", strjoin(name, strjoin(c" ", strjoin(src, c" 1 entries=100000\n")))))))
			functions = functions + 1
		i = end
		if (text[i] == 10): i = i + 1
	if (functions == 0): fail(c"defhash listed no functions", src, c"", 0)
	assert1(file_write_text(path, out))
	return path


# stderr without stack-trace lines: inlining removes frames, and frames
# name absolute paths and line numbers that are not part of the contract.
char* normalized_stderr(char* text):
	char* out = c""
	int i = 0
	while (text[i] != 0):
		int end = i
		while ((text[end] != 0) && (text[end] != 10)): end = end + 1
		char* line = str_copy_range(text, i, end)
		if ((starts_with(line, c"stack trace") == 0) && (starts_with(line, c"  at ") == 0)):
			out = strjoin(out, strjoin(line, c"\n"))
		i = end
		if (text[i] == 10): i = i + 1
	return out


struct observed:
	int status
	char* out
	char* err


observed* run_binary(char* path, int which):
	char** env = env_copy_with(env_current(), c"W_DEBUG_ALLOC", c"1")
	if (which > 0): env = env_copy_with(env, c"SAFE_OPT_CASE", itoa(which))
	char** argv = strv_new(1)
	argv[0] = path
	process_result* r = run_argv(argv, env)
	observed* o = new observed
	o.status = r.status
	o.out = r.stdout_text
	o.err = normalized_stderr(r.stderr_text)
	return o


int same(observed* a, observed* b):
	if (a.status != b.status): return 0
	if (strcmp(a.out, b.out) != 0): return 0
	return strcmp(a.err, b.err) == 0


char* describe(observed* want, observed* got):
	char* s = strjoin(c"want exit ", itoa(want.status))
	s = strjoin(s, strjoin(c", got exit ", itoa(got.status)))
	s = strjoin(s, strjoin(c"\n  want stdout:\n", want.out))
	s = strjoin(s, strjoin(c"\n  got stdout:\n", got.out))
	s = strjoin(s, strjoin(c"\n  want stderr:\n", want.err))
	return strjoin(s, strjoin(c"\n  got stderr:\n", got.err))


# Compiles src with flags into the scratch directory; 0 on failure.
char* build(char* src, char* flags, char* profile, int index):
	char* out = strjoin(strjoin(strjoin(scratch(), c"/"), base_name(src)), strjoin(c".", itoa(index)))
	unlink(out)
	char** argv = compile_argv(flags, profile, src, out, 0)
	process_result* r = run_argv(argv, 0)
	if (r.status != 0):
		fail(c"compile failed", src, flags, r.stderr_text)
		return 0
	return out


# Cases a fixture runs: 0 only, or 0..6 for the bounds fixture.
int case_count(char* src):
	if (contains(src, c"safe_opt_bounds_fixture")): return 7
	return 1


void check_case_contract(char* src, char* flags, int which, observed* o):
	if (which == 0):
		if (o.status != 0): fail(c"nonzero exit", src, flags, describe(o, o))
		return;
	if (o.status == 0): fail(c"bounds case did not trap", src, flags, itoa(which))
	if (contains(o.err, c"index out of range") == 0): fail(c"bounds case missing trap message", src, flags, o.err)


# Compiles src under every configuration (and twin, when given, which
# must behave like src's reference) and compares every run.
void sweep(char* src, char* twin, int safe_capable):
	char* profile = hot_profile(src)
	int cases = case_count(src)
	char* ref_bin = build(src, reference_flags(), profile, 0)
	if (ref_bin == 0): return;
	list[observed*] refs = new list[observed*]
	for which in range(cases):
		observed* o = run_binary(ref_bin, which)
		check_case_contract(src, reference_flags(), which, o)
		refs.push(o)
	list[char*] configs = configurations()
	if (safe_capable):
		for char* extra in safe_configurations(): configs.push(extra)
	int index = 1
	list[char*] sources = new list[char*]
	sources.push(src)
	if (twin != 0): sources.push(twin)
	for char* source in sources:
		char* source_profile = profile
		if (source != src): source_profile = hot_profile(source)
		list[char*] variants = new list[char*]
		if (source != src): variants.push(reference_flags())
		for char* c in configs:
			if ((source == src) || (contains(c, c"--safe") == 0)): variants.push(c)
		for char* flags in variants:
			char* bin = build(source, flags, source_profile, index)
			index = index + 1
			if (bin == 0): continue
			for which in range(cases):
				observed* o = run_binary(bin, which)
				comparisons = comparisons + 1
				if (same(refs[which], o) == 0):
					char* label = flags
					if (which > 0): label = strjoin(flags, strjoin(c" SAFE_OPT_CASE=", itoa(which)))
					if (source != src): label = strjoin(c"manual twin ", label)
					fail(c"MISMATCH against the -O0 --no-inline reference", src, label, describe(refs[which], o))


# 'inline_body_end('name', ok=N' from a -v -v -v compile: N, or -1 when
# the name was never captured.
int capture_ok(char* log, char* name):
	char* key = strjoin(strjoin(c"inline_body_end('", name), c"', ok=")
	int at = index_of(log, key)
	if (at < 0): return -1
	return log[at + strlen(key)] - '0'


int inlined(char* log, char* name):
	return index_of(log, strjoin(strjoin(c"\n", name), c": inlined\n")) >= 0


char* verbose_log(char* src, char* flags):
	char* out = strjoin(strjoin(strjoin(scratch(), c"/"), base_name(src)), c".verbose")
	char** argv = compile_argv(flags, hot_profile(src), src, out, 3)
	process_result* r = run_argv(argv, 0)
	if (r.status != 0): fail(c"verbose compile failed", src, flags, r.stderr_text)
	return strjoin(c"\n", r.stderr_text)


void expect_capture(char* log, char* src, char* name, int ok):
	int got = capture_ok(log, name)
	if (got != ok):
		char* detail = strjoin(name, strjoin(c": want ok=", strjoin(itoa(ok), strjoin(c", got ", itoa(got)))))
		fail(c"inliner capture", src, c"-v -v -v --inline", detail)
	if ((ok == 0) && inlined(log, name)): fail(c"checked function inlined", src, c"-v -v -v --inline", name)


void expect_inlined(char* log, char* src, char* name):
	if (inlined(log, name) == 0): fail(c"expected an inlined site", src, c"-v -v -v --inline", name)


void check_inliner_exclusion():
	char* order = c"tests/safe_opt_order_fixture.w"
	char* log = verbose_log(order, c"--inline HOT")
	# checked parameters, results or declarations: refused
	expect_capture(log, order, c"opt_box", 0)
	expect_capture(log, order, c"opt_consume", 0)
	expect_capture(log, order, c"opt_peek", 0)
	expect_capture(log, order, c"opt_bump", 0)
	expect_capture(log, order, c"opt_pass_through", 0)
	expect_capture(log, order, c"opt_local_view", 0)
	expect_capture(log, order, c"opt_local_ref", 0)
	# scalar neighbours: recorded, and inlined where hot
	expect_capture(log, order, c"opt_untag", 1)
	expect_capture(log, order, c"opt_twice", 1)
	expect_capture(log, order, c"opt_feed", 1)
	expect_inlined(log, order, c"opt_feed")
	expect_inlined(log, order, c"opt_untag")
	char* bounds = c"tests/safe_opt_bounds_fixture.w"
	log = verbose_log(bounds, c"--inline HOT")
	expect_capture(log, bounds, c"bounds_at", 0)
	expect_capture(log, bounds, c"bounds_box", 0)
	expect_capture(log, bounds, c"bounds_pick", 1)
	expect_inlined(log, bounds, c"bounds_pick")
	# the manual twin's raw versions of the refused functions are recorded
	# (plain --inline: a hot profile would inline their own callees into
	# them first and push some past the capture size cap)
	char* manual = c"tests/safe_opt_order_manual_fixture.w"
	log = verbose_log(manual, c"--inline")
	expect_capture(log, manual, c"opt_box", 1)
	expect_capture(log, manual, c"opt_consume", 1)
	expect_capture(log, manual, c"opt_peek", 1)
	expect_capture(log, manual, c"opt_bump", 1)
	expect_capture(log, manual, c"opt_pass_through", 1)
	expect_capture(log, manual, c"opt_local_view", 1)
	expect_capture(log, manual, c"opt_local_ref", 1)


# tests/safe_*_runtime_fixture.w, sorted, plus tests/safe_runtime_fixture.w.
# Each must be declared as a deps= input above, so editing it reselects
# and reruns this target.
list[char*] runtime_fixtures():
	char* self = file_read_text(c"tests/safe_opt_diff_test.w")
	assert1(self != 0)
	list[char*] names = dir_names(c"tests")
	asserts(c"cannot list tests/", names != 0)
	list[char*] found = new list[char*]
	for char* name in names:
		if (starts_with(name, c"safe_") && ends_with(name, c"_runtime_fixture.w")): found.push(strjoin(c"tests/", name))
	# insertion sort: a stable order makes the report reproducible
	for i in range(found.length):
		int j = i
		while ((j > 0) && (strcmp(found[j - 1], found[j]) > 0)):
			char* t = found[j - 1]
			found[j - 1] = found[j]
			found[j] = t
			j = j - 1
	for char* path in found:
		if (contains(self, strjoin(c"deps=", path)) == 0): fail(c"fixture not declared as a deps= input of tests/safe_opt_diff_test.w", path, c"", 0)
	return found


int main():
	arch64 = __word_size__ == 8
	mkdir(c"bin", 493)
	mkdir(scratch(), 493)
	check_inliner_exclusion()
	sweep(c"tests/safe_opt_order_fixture.w", c"tests/safe_opt_order_manual_fixture.w", 1)
	sweep(c"tests/safe_opt_bounds_fixture.w", 0, 1)
	list[char*] fixtures = runtime_fixtures()
	asserts(c"no runtime fixtures found", fixtures.length >= 30)
	for char* src in fixtures: sweep(src, 0, 0)
	print(c"safe_opt_diff: ")
	print(itoa(fixtures.length + 3))
	print(c" programs, ")
	print(itoa(comparisons))
	print(c" comparisons, ")
	print(itoa(failures))
	println(c" failures")
	if (failures != 0): return 1
	return 0
