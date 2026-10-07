import lib.testing
import lib.file
import lib.process
import lib.str

/*
C3.5 (#110): the optional AST optimizer pass (compiler/ast_opt.w,
--ast-opt). It folds constant if/elif/while conditions and removes the
arm the condition kills when nothing outside that arm refers to its
code.

The test_fold_* and test_dead_* functions pin what programs compute: this
file runs them compiled without the pass (the conventional target), then
compiled with it, on x86 and x64 (the steps below). Every shape the pass
rewrites is here, and every reason it keeps a dead arm (a call, a string,
a global, a label, a goto) has a case whose answer would change if the
arm's code were dropped wrongly.

The test_driver_* functions (default binary only) compile this file and
a warning fixture both ways and check what the pass must not change (the
diagnostics, the --streaming conflict) and that it did remove code.
*/
# wbuild: step="bin/wv2 --ast-opt tests/ast_opt_test.w -o bin/ast_opt_test_on"
# wbuild: step="bin/ast_opt_test_on --filter=fold_,dead_"
# wbuild: step="bin/wv2 x64 --ast-opt tests/ast_opt_test.w -o bin/ast_opt_test_on_64"
# wbuild: step="bin/ast_opt_test_on_64 --filter=fold_,dead_"
# wbuild: deps=tests/ast_control_walk_fixture.w


int opt_trace
int opt_global


void opt_mark(int digit):
	opt_trace = opt_trace * 10 + digit


int opt_call(int v):
	opt_mark(7)
	return v


# --- folded conditions -----------------------------------------------------

void test_fold_literal_conditions():
	int x = 0
	if (1): x = x + 1
	if (0): x = x + 10
	if (2 + 3 == 5): x = x + 100
	if (7 * 6 != 42): x = x + 1000
	if (true): x = x + 10000
	if (false): x = x + 100000
	assert_equal(10101, x)


void test_fold_operators():
	int x = 0
	if ((12 & 10) == 8): x = x + 1
	if ((12 | 3) == 15): x = x + 2
	if ((12 ^ 10) == 6): x = x + 4
	if ((1 << 4) == 16): x = x + 8
	if ((-64 >> 3) == -8): x = x + 16
	if ((17 / 5 == 3) && (17 % 5 == 2) && (-17 / 5 == -3) && (-17 % 5 == -2)): x = x + 32
	if ((~0 == -1) && (-(3) == -3) && (+4 == 4)): x = x + 64
	if (!0 && !!5 && !(3 < 2)): x = x + 128
	if ((3 < 4) && (4 <= 4) && (5 > 4) && (4 >= 4)): x = x + 256
	if (('a' == 97) && ('\n' == 10)): x = x + 512
	if (0 || 0 || 1): x = x + 1024
	if (1 && 0): x = x + 2048
	if (1 ? 0 : 1): x = x + 4096
	if (0 ? 0 : 3): x = x + 8192
	assert_equal(1 + 2 + 4 + 8 + 16 + 32 + 64 + 128 + 256 + 512 + 1024 + 8192, x)


void test_fold_word_size():
	int x = 0
	if (__word_size__ == 8): x = 64
	elif (__word_size__ == 4): x = 32
	else: x = -1
	if (__word_size__ * 8 == 64): assert_equal(64, x)
	else: assert_equal(32, x)
	if (__target_isa__ == 0): x = x + 1
	assert_equal(__word_size__ * 8 + 1, x)


# Values the pass will not fold (out of its +-2^30 range, a zero divisor
# behind '&&') still compute what the instructions compute.
void test_fold_edges():
	int x = 0
	if (0x40000000 + 0x40000000 != 0): x = x + 1
	if ((1 << 30) > 0): x = x + 2
	if (0 && (1 / 0)): x = x + 4
	if (1 || (1 / 0)): x = x + 8
	if (0x7fffffff + 1 < 0): x = x + 16
	if (__word_size__ == 8): assert_equal(1 + 2 + 8, x)
	else: assert_equal(1 + 2 + 8 + 16, x)


# Side effects in a condition are never folded away.
void test_fold_side_effects():
	opt_trace = 0
	int x = 0
	if (0 && opt_call(1)): x = 1
	if (1 || opt_call(1)): x = x + 2
	if (opt_call(0) || 1): x = x + 4
	if (opt_call(1) && 0): x = x + 8
	assert_equal(6, x)
	assert_equal(77, opt_trace)


# --- dead regions -------------------------------------------------------------

int dead_chain(int n):
	int x = 0
	if (0): x = 1
	elif (n > 5): x = 2
	elif (1): x = 3
	elif (n > 100): x = 4
	else: x = 5
	return x


void test_dead_elif_chains():
	assert_equal(2, dead_chain(9))
	assert_equal(3, dead_chain(1))
	int x = 0
	if (0): x = 1
	elif (0): x = 2
	else: x = 3
	assert_equal(3, x)
	if (1): x = 4
	elif (opt_call(1)): x = 5
	else: x = 6
	assert_equal(4, x)
	if (0): x = 7
	assert_equal(4, x)
	if (1):
		x = 8
	assert_equal(8, x)


void test_dead_while():
	int x = 0
	while (0):
		x = x + 1
		if (x > 3): break
		continue
	assert_equal(0, x)
	while (__word_size__ == 2):
		x = x + 100
	assert_equal(0, x)
	int n = 0
	while (1):
		n = n + 1
		if (n == 5): break
	assert_equal(5, n)
	while true:
		n = n + 1
		if (n > 9): break
	assert_equal(10, n)


# Dead arms holding locals, nested blocks and loops, and control transfer
# to enclosing loops.
int dead_nested(int n):
	int total = 0
	for i in range(n):
		if (0):
			int unused = i * 2
			while (unused < 100):
				unused = unused + 1
				if (unused == 50): break
				if (unused == 60): continue
			if (unused): break
			continue
		if (1):
			total = total + i
		else:
			int j = i
			while (j > 0):
				j = j - 1
				if (j == 1): continue
			break
		while (0):
			if (1): continue
			break
	return total


# A dead 'break' threads its jump into the loop's exit chain; the live
# code after the arm overwrites the arm's bytes before the loop's end
# resolves that chain, so the jump must leave the chain with the arm.
int dead_break_chain(int n):
	int total = 0
	for i in range(n):
		if (0): break
		total = total + i * 3 + (i << 2) - (i & 5) + (i ^ 9) * 7 - (i | 2) * 11 + (i % 7) * 13 - (i / 3) * 17
		total = total + i * 5 + (i << 3) - (i & 6) + (i ^ 8) * 3 - (i | 4) * 19 + (i % 5) * 23 - (i / 2) * 29
	return total


void test_dead_nested_regions():
	assert_equal(0, dead_nested(0))
	assert_equal(45, dead_nested(10))
	int want = 0
	for i in range(20):
		want = want + i * 3 + (i << 2) - (i & 5) + (i ^ 9) * 7 - (i | 2) * 11 + (i % 7) * 13 - (i / 3) * 17
		want = want + i * 5 + (i << 3) - (i & 6) + (i ^ 8) * 3 - (i | 4) * 19 + (i % 5) * 23 - (i / 2) * 29
	assert_equal(want, dead_break_chain(20))


int dead_return(int n):
	if (0): return n * 1000
	if (1):
		if (n > 3): return n
	else:
		return -1
	if (0):
		if (1): return 5
		else: return 6
	return 0


void test_dead_returns():
	assert_equal(9, dead_return(9))
	assert_equal(0, dead_return(1))


# Arms the pass keeps: their code is referred to from outside them, or
# refers to something whose record would go wrong without it. The program
# must behave the same either way.
int dead_kept_text(int n):
	char* s = c"live"
	if (0): s = c"dead text"
	if (0): opt_global = opt_call(n)
	if (1): opt_global = n + 1
	else: opt_global = opt_call(2)
	return strlen(s) * 100 + opt_global


int opt_late(int v);


# opt_late is defined below: each call to it before the definition links
# its address slot into a backpatch chain through the code, the dead
# arm's call included.
int dead_forward_call(int n):
	int x = opt_late(n)
	if (0): x = x + opt_late(100)
	x = x + opt_late(n + 1) * 3 + (n << 2) - (n & 5) + (n ^ 9) * 7 - (n | 2) * 11 + (n % 7) * 13
	return x


int opt_late(int v):
	return v * 2


void test_dead_kept_arms():
	opt_trace = 0
	opt_global = 0
	assert_equal(406, dead_kept_text(5))
	assert_equal(0, opt_trace)
	int n = 4
	assert_equal(8 + 30 + (n << 2) - (n & 5) + (n ^ 9) * 7 - (n | 2) * 11 + (n % 7) * 13, dead_forward_call(n))


int dead_goto(int n):
	int x = 0
	if (n == 1): goto into_dead
	if (0):
		into_dead:
		x = 42
	if (1): goto out
	x = 7
	out:
	return x


void test_dead_goto_label():
	assert_equal(42, dead_goto(1))
	assert_equal(0, dead_goto(0))


# A dead arm between live code that the register allocator promotes.
int dead_hot_loop(int n):
	int sum = 0
	int i = 0
	while (i < n):
		if (0): sum = sum - 1000
		sum = sum + i
		if (__word_size__ == 3): sum = 0
		i = i + 1
	return sum


void test_dead_hot_loop():
	assert_equal(4950, dead_hot_loop(100))


# --- driver (default binary only) ----------------------------------------------

process_result* opt_run(char** args):
	process_result* result = process_run(args[0], args, 0, 0, 120000)
	free(cast(void*, args))
	assert1(result != 0)
	return result


process_result* opt_compile(char* arch, int enabled, char* input, char* output):
	char** args = strv_new(12)
	int i = 0
	strv_set(args, i, c"bin/wv2")
	i = i + 1
	if (arch != 0):
		strv_set(args, i, arch)
		i = i + 1
	strv_set(args, i, c"--quiet")
	i = i + 1
	strv_set(args, i, c"--stats")
	i = i + 1
	if (enabled):
		strv_set(args, i, c"--ast-opt")
		i = i + 1
	strv_set(args, i, input)
	i = i + 1
	strv_set(args, i, c"-o")
	i = i + 1
	strv_set(args, i, output)
	return opt_run(args)


# The number after label in text, or -1.
int opt_stat(char* text, char* label):
	int at = index_of(text, label)
	if (at < 0): return -1
	return atoi(&text[at + strlen(label)])


int opt_file_size(char* path):
	int fd = open(path, 0, 0)
	assert1(fd >= 0)
	int size = file_size(fd)
	close(fd)
	return size


# The lines of a compile's stderr that are diagnostics, without the
# --stats counters (which the pass adds to).
char* opt_diagnostics(char* text):
	int end = index_of(text, c"sym_lookup calls: ")
	if (end < 0): end = strlen(text)
	char* out = cast(char*, malloc(end + 1))
	for i in range(end): out[i] = text[i]
	out[end] = 0
	return out


void opt_compare_self(char* arch, char* suffix):
	char* plain = strjoin(c"bin/ast_opt_plain", suffix)
	char* folded = strjoin(c"bin/ast_opt_folded", suffix)
	process_result* off = opt_compile(arch, 0, c"tests/ast_opt_test.w", plain)
	process_result* on = opt_compile(arch, 1, c"tests/ast_opt_test.w", folded)
	assert_equal(0, off.status)
	assert_equal(0, on.status)
	assert_equal(-1, opt_stat(off.stderr_text, c"AST optimizer folded conditions: "))
	assert1(opt_stat(on.stderr_text, c"AST optimizer folded conditions: ") >= 60)
	assert1(opt_stat(on.stderr_text, c"AST optimizer dead regions removed: ") >= 25)
	assert1(opt_stat(on.stderr_text, c"AST optimizer dead regions kept: ") >= 5)
	assert1(opt_stat(on.stderr_text, c"AST optimizer dead bytes removed: ") > 500)
	char* off_diagnostics = opt_diagnostics(off.stderr_text)
	char* on_diagnostics = opt_diagnostics(on.stderr_text)
	assert_strings_equal(off_diagnostics, on_diagnostics)
	assert1(opt_file_size(folded) <= opt_file_size(plain))
	free(off_diagnostics)
	free(on_diagnostics)
	process_result_free(off)
	process_result_free(on)


void test_driver_self_compile():
	opt_compare_self(0, c"")
	opt_compare_self(c"x64", c"_64")


# Warnings in folded conditions and in dead arms are reported as without
# the pass: the arms are parsed and lowered before their bytes go.
void test_driver_diagnostics():
	char* path = c"bin/ast_opt_warning_fixture.w"
	string_builder* source = string_new()
	string_append(source, c"int warned(int n):\n")
	string_append(source, c"\tbool a = n > 1\n")
	string_append(source, c"\tif (true | false): n = n + 1\n")
	string_append(source, c"\tif (0):\n")
	string_append(source, c"\t\tif (a | (n > 2)): n = n + 2\n")
	string_append(source, c"\twhile (0):\n")
	string_append(source, c"\t\tif (a & (n > 3)): break\n")
	string_append(source, c"\tif (1): return n\n")
	string_append(source, c"\telse:\n")
	string_append(source, c"\t\tif (a | a): return 0\n")
	string_append(source, c"\treturn n\n")
	string_append(source, c"\n")
	string_append(source, c"int main():\n")
	string_append(source, c"\treturn warned(1) - 2\n")
	file_write_text(path, source.data)
	string_free(source)
	char** inputs = strv_new(3)
	strv_set(inputs, 0, path)
	strv_set(inputs, 1, c"tests/ast_control_walk_fixture.w")
	for k in range(2):
		char* input = inputs[k]
		process_result* off = opt_compile(0, 0, input, c"bin/ast_opt_warn_plain")
		process_result* on = opt_compile(0, 1, input, c"bin/ast_opt_warn_folded")
		assert_equal(off.status, on.status)
		char* off_diagnostics = opt_diagnostics(off.stderr_text)
		char* on_diagnostics = opt_diagnostics(on.stderr_text)
		assert1(index_of(off_diagnostics, c"warning: bitwise") >= 0)
		assert_strings_equal(off_diagnostics, on_diagnostics)
		free(off_diagnostics)
		free(on_diagnostics)
		process_result_free(off)
		process_result_free(on)
	free(cast(void*, inputs))
	char** run = strv_new(2)
	strv_set(run, 0, c"bin/ast_opt_warn_folded")
	process_result* ran = opt_run(run)
	assert_equal(0, ran.status)
	process_result_free(ran)


void test_driver_streaming_conflict():
	char** args = strv_new(6)
	strv_set(args, 0, c"bin/wv2")
	strv_set(args, 1, c"--streaming")
	strv_set(args, 2, c"--ast-opt")
	strv_set(args, 3, c"tests/ast_opt_test.w")
	strv_set(args, 4, c"-o")
	strv_set(args, 5, c"bin/ast_opt_conflict")
	process_result* result = opt_run(args)
	assert1(result.status != 0)
	assert1(index_of(result.stderr_text, c"'--streaming' cannot be combined with '--ast-opt'") >= 0)
	process_result_free(result)


# The pass's self-host fixpoint, x86 and x64: a compiler built with
# --ast-opt rebuilds itself identically with --ast-opt, and without the
# flag it emits exactly the default compiler's image (bin/wv3), so the
# arms it removed from itself changed nothing it computes.
# wbuild: target=ast_opt_verify tag=tests dep=build dep=build_x64
# wbuild: step="bin/wv2 --ast-opt --strict w.w -o bin/ast_opt_wv3"
# wbuild: step="bin/ast_opt_wv3 --ast-opt --strict w.w -o bin/ast_opt_wv4"
# wbuild: step="cmp bin/ast_opt_wv3 bin/ast_opt_wv4"
# wbuild: step="bin/ast_opt_wv3 --strict w.w -o bin/ast_opt_off_wv4"
# wbuild: step="cmp bin/wv3 bin/ast_opt_off_wv4"
# wbuild: step="bin/wv2_64 x64 --ast-opt --strict w.w -o bin/ast_opt_wv3_64"
# wbuild: step="bin/ast_opt_wv3_64 x64 --ast-opt --strict w.w -o bin/ast_opt_wv4_64"
# wbuild: step="cmp bin/ast_opt_wv3_64 bin/ast_opt_wv4_64"
# wbuild: step="bin/ast_opt_wv3_64 x64 --strict w.w -o bin/ast_opt_off_wv4_64"
# wbuild: step="cmp bin/wv3_64 bin/ast_opt_off_wv4_64"
