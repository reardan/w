# wbuild: timeout=1800000
/*
Differential sweep for register promotion (unit R2,
docs/projects/register_allocation_pgo.md §5), direct calls (unit A4,
docs/projects/codegen_gap_plan.md §2.4), the condition chains of
unit A6 (§2.6, grammar/cond_branch.w), the addressing modes of unit
A2 (§2.2, code_generator/x86.w), the loop rotation of unit A7
(§2.5, grammar/loop_rotate.w), the opt-in inlining of unit A5
(§2.4, compiler/inline_table.w), the expression register stack of
unit A3 (§2.3, code_generator/x86.w's ers_* section), the narrow
integer promotion of unit A8 (§2.7, compiler/regalloc_scan.w) and the
x86-32 register budget of unit A9 (§2.7, compiler/regalloc_scan.w's
loop pass): every conventional compile-and-run target of the generated
manifest is built eleven times, with the defaults, with --no-regs,
with --no-direct-calls, with --no-cond-branch, with --no-addr-modes,
with --no-loop-rotate, with --no-expr-regs, with --no-narrow-regs,
with --no-x86-budget, with all eight opt-outs together, and with
--inline, on the width its target names (x86 or x64), and the binaries
must behave identically: exit status, stdout and stderr. The same
source is also compiled by compilers that were themselves built with
each opt-out, with all eight, and with --inline, and those outputs must
be byte-identical to bin/wv2's (no unit may change what the compiler
emits, only how the compiler's own code runs).

Selection is manifest-driven (tools/wbuildgen_lib.w generates the same
manifest wexec runs): a target qualifies when its two steps are
'bin/wv2 [x64] src.w -o bin/out' and 'bin/out' with no arguments. The
run inherits the step's stdin and timeout. Sources that spawn
processes, write files or reference bin/ are skipped by a textual
hazard scan, because this test runs concurrently with the real target
under ./wbuild tests and two instances of such a program would race on
their outputs; sources importing the compiler itself are skipped too
(tests/elf.w prints its own ELF layout, which the two builds cannot
share, and the in-process-compiler tests are the slowest to build).
Both binaries run with the same argv[0] (their shared base name), so a
loader message naming the program compares equal. A mismatch is re-checked by running the --no-regs build
a second time, and so is the promoted build: a program whose two
runs of either build differ is reported as nondeterministic and not
counted (the race and timing tests). Hexadecimal addresses in the
outputs ('0x...': lib/testing.w prints each test function's address,
and code addresses differ between the two builds by construction) are
blanked before the comparison.

The sweep is split across shard processes (this program re-executes
itself with --shard k); the parent builds the opt-out compilers, waits
for the shards and fails when any of them reported a mismatch.

The sweep is the slowest target in the tree, so build.base.json pins it
to its own umbrella, tests_codegen_diff, which CI runs as a separate
job beside the full suite; `./wbuild tests` leaves it out, and
`wtest changed` still selects it for compiler changes. CI also splits
the sweep across runners: W_REGALLOC_DIFF_PART=k/n keeps only every
n-th selected target starting at the k-th (0-based), so n jobs with
k = 0..n-1 cover the whole manifest once. Unset, the run covers it all.
*/
import lib.lib
import lib.assert
import lib.process
import lib.file
import lib.env
import structures.json
import tools.wbuildgen_lib


const int shard_count = 4
const int default_timeout_ms = 60000
char* scratch_dir():
	return c"bin/regalloc_diff"


char* noregs_compiler():
	return c"bin/regalloc_diff/wv2_noregs"


char* nodirect_compiler():
	return c"bin/regalloc_diff/wv2_nodirect"


char* nocond_compiler():
	return c"bin/regalloc_diff/wv2_nocond"


char* noaddr_compiler():
	return c"bin/regalloc_diff/wv2_noaddr"


char* norotate_compiler():
	return c"bin/regalloc_diff/wv2_norotate"


char* noexpr_compiler():
	return c"bin/regalloc_diff/wv2_noexpr"


char* nonarrow_compiler():
	return c"bin/regalloc_diff/wv2_nonarrow"
char* nobudget_compiler():
	return c"bin/regalloc_diff/wv2_nobudget"


# Built with every opt-out at once
char* noopt_compiler():
	return c"bin/regalloc_diff/wv2_noopt"


# Built with --inline (unit A5 is opt-in: the inlined build is the
# variant, the default the reference)
char* inline_compiler():
	return c"bin/regalloc_diff/wv2_inline"


int has_text(char* haystack, char* needle):
	int n = strlen(needle)
	int i = 0
	while (haystack[i] != 0):
		int j = 0
		while ((j < n) && (haystack[i + j] == needle[j])): j = j + 1
		if (j == n): return 1
		i = i + 1
	return 0


# Programs that would race with their own manifest run.
int source_hazard(char* text):
	if (has_text(text, c"import lib.process")): return 1
	if (has_text(text, c"import lib.file")): return 1
	if (has_text(text, c"import tools.")): return 1
	if (has_text(text, c"process_run")): return 1
	if (has_text(text, c"process_spawn")): return 1
	if (has_text(text, c"file_write")): return 1
	if (has_text(text, c"open(")): return 1
	if (has_text(text, c"mkdir")): return 1
	if (has_text(text, c"unlink(")): return 1
	if (has_text(text, c"rename(")): return 1
	if (has_text(text, c"/tmp")): return 1
	if (has_text(text, c"bin/")): return 1
	if (has_text(text, c"system(")): return 1
	if (has_text(text, c"import codegen")): return 1
	if (has_text(text, c"import compiler.")): return 1
	if (has_text(text, c"import code_generator.")): return 1
	return 0


char* json_text(json_value* v):
	if (v == 0): return 0
	return v.string_value


char* arg_at(json_value* cmd, int i):
	return json_text(json_array_get(cmd, i))


process_result* run_argv(char** argv, char* stdin_text, int timeout_ms):
	process_result* r = process_run(argv[0], argv, 0, stdin_text, timeout_ms)
	asserts(c"process_run", r != 0)
	return r


# Run path with argv[0] = name (the two builds share it).
process_result* run_as(char* path, char* name, char* stdin_text, int timeout_ms):
	char** argv = strv_new(1)
	argv[0] = name
	process_result* r = process_run(path, argv, 0, stdin_text, timeout_ms)
	asserts(c"process_run", r != 0)
	free(cast(void*, argv))
	return r


# bin/wv2 [x64] [--no-regs] [--no-direct-calls] [--no-cond-branch]
# [--no-addr-modes] [--no-loop-rotate] [--inline] [--no-expr-regs]
# [--no-narrow-regs] [--no-x86-budget] src -o out; opt_out is a
# bitmask: 1 = --no-regs, 2 = --no-direct-calls, 4 = --no-cond-branch,
# 8 = --no-addr-modes, 16 = --no-loop-rotate, 64 = --no-expr-regs,
# 128 = --no-narrow-regs, 256 = --no-x86-budget (opt_out_all is every
# opt-out at once), 32 = --inline (an opt-in, unit A5: not part of
# opt_out_all)
const int opt_out_all = 479
const int opt_in_inline = 32
process_result* compile_with(char* compiler, int arch64, int opt_out, char* src, char* out):
	char** argv = strv_new(16)
	int n = 0
	argv[n] = compiler
	n = n + 1
	argv[n] = c"--quiet"
	n = n + 1
	if (arch64):
		argv[n] = c"x64"
		n = n + 1
	if (opt_out & 1):
		argv[n] = c"--no-regs"
		n = n + 1
	if (opt_out & 2):
		argv[n] = c"--no-direct-calls"
		n = n + 1
	if (opt_out & 4):
		argv[n] = c"--no-cond-branch"
		n = n + 1
	if (opt_out & 8):
		argv[n] = c"--no-addr-modes"
		n = n + 1
	if (opt_out & 16):
		argv[n] = c"--no-loop-rotate"
		n = n + 1
	if (opt_out & 32):
		argv[n] = c"--inline"
		n = n + 1
	if (opt_out & 256):
		argv[n] = c"--no-x86-budget"
		n = n + 1
	if (opt_out & 64):
		argv[n] = c"--no-expr-regs"
		n = n + 1
	if (opt_out & 128):
		argv[n] = c"--no-narrow-regs"
		n = n + 1
	argv[n] = src
	argv[n + 1] = c"-o"
	argv[n + 2] = out
	process_result* r = run_argv(argv, 0, 300000)
	free(cast(void*, argv))
	return r


int shell_status(char* cmd, char* a, char* b):
	char** argv = strv_new(3)
	argv[0] = cmd
	argv[1] = a
	argv[2] = b
	process_result* r = run_argv(argv, 0, 60000)
	free(cast(void*, argv))
	return r.status


int is_hex_digit(int c):
	if ((c >= '0') && (c <= '9')): return 1
	if ((c >= 'a') && (c <= 'f')): return 1
	return (c >= 'A') && (c <= 'F')


# A copy of text with the digits of every 0x... literal removed.
char* blank_addresses(char* text):
	int n = strlen(text)
	char* out = cast(char*, malloc(n + 1))
	int i = 0
	int j = 0
	while (i < n):
		out[j] = text[i]
		j = j + 1
		if ((text[i] == 'x') && (i > 0) && (text[i - 1] == '0')):
			i = i + 1
			while ((i < n) && is_hex_digit(text[i])): i = i + 1
		else: i = i + 1
	out[j] = 0
	return out


int same_text(char* a, char* b):
	char* na = blank_addresses(a)
	char* nb = blank_addresses(b)
	int same = strcmp(na, nb) == 0
	free(na)
	free(nb)
	return same


int same_result(process_result* a, process_result* b):
	if (a.status != b.status): return 0
	if (same_text(a.stdout_text, b.stdout_text) == 0): return 0
	return same_text(a.stderr_text, b.stderr_text)


void report(char* what, char* name, char* detail):
	print(c"regalloc_diff: ")
	print(what)
	print(c" ")
	print(name)
	if (detail != 0):
		print(c": ")
		print(detail)
	println(c"")


int mismatches
int compared
int skipped


# The default build's run ra against the variant build at path other:
# 1 when they agree; 0 after reporting a mismatch or a nondeterministic
# program (either build differing from a second run of itself).
int compare_runs(process_result* ra, char* regs, char* other, char* flag, char* name, char* stdin_text, int timeout_ms):
	process_result* rb = run_as(other, name, stdin_text, timeout_ms)
	if (same_result(ra, rb)): return 1
	process_result* rb2 = run_as(other, name, stdin_text, timeout_ms)
	process_result* ra2 = run_as(regs, name, stdin_text, timeout_ms)
	if ((same_result(rb, rb2) == 0) || (same_result(ra, ra2) == 0)):
		report(c"nondeterministic (two runs of one build differ), not compared", name, 0)
		skipped = skipped + 1
		return 0
	mismatches = mismatches + 1
	report(c"MISMATCH (behaviour)", name, 0)
	print(c"  ")
	print(flag)
	print(c": status ")
	print(itoa(ra.status))
	print(c" vs ")
	println(itoa(rb.status))
	if (same_text(ra.stdout_text, rb.stdout_text) == 0): println(c"  stdout differs")
	if (same_text(ra.stderr_text, rb.stderr_text) == 0): println(c"  stderr differs")
	return 0


# Two failed compiles of one source must fail alike: 1 when they do,
# 0 after reporting the mismatch.
int same_compile(process_result* ca, process_result* cb, char* what, char* name):
	if ((ca.status == cb.status) && (strcmp(ca.stderr_text, cb.stderr_text) == 0)): return 1
	mismatches = mismatches + 1
	report(what, name, cb.stderr_text)
	return 0


# compiler (built with an opt-out) compiling src to out must produce the
# bytes kept in keep: 1 when it does, 0 after reporting the mismatch.
int same_output(char* compiler, int arch64, char* src, char* out, char* keep, char* which, char* name):
	process_result* cc = compile_with(compiler, arch64, 0, src, out)
	if ((cc.status == 0) && (shell_status(c"/usr/bin/cmp", out, keep) == 0)): return 1
	mismatches = mismatches + 1
	print(c"regalloc_diff: MISMATCH (compiler output differs from the ")
	print(which)
	print(c" compiler) ")
	println(name)
	return 0


void sweep_target(char* name, int arch64, char* src, char* stdin_text, int timeout_ms):
	char* text = file_read_text(src)
	if (text == 0):
		skipped = skipped + 1
		return
	if (source_hazard(text)):
		free(text)
		skipped = skipped + 1
		return
	free(text)
	char* regs = strjoin(c"bin/regalloc_diff/", name)
	char* regs_keep = strjoin(regs, c".keep")
	char* noregs = strjoin(regs, c".noregs")
	char* nodirect = strjoin(regs, c".nodirect")
	char* nocond = strjoin(regs, c".nocond")
	char* noaddr = strjoin(regs, c".noaddr")
	char* norotate = strjoin(regs, c".norotate")
	char* noexpr = strjoin(regs, c".noexpr")
	char* nonarrow = strjoin(regs, c".nonarrow")
	char* nobudget = strjoin(regs, c".nobudget")
	char* noopt = strjoin(regs, c".noopt")
	char* inl = strjoin(regs, c".inline")

	process_result* ca = compile_with(c"bin/wv2", arch64, 0, src, regs)
	process_result* cb = compile_with(c"bin/wv2", arch64, 1, src, noregs)
	process_result* cd = compile_with(c"bin/wv2", arch64, 2, src, nodirect)
	process_result* cn = compile_with(c"bin/wv2", arch64, 4, src, nocond)
	process_result* cm = compile_with(c"bin/wv2", arch64, 8, src, noaddr)
	process_result* cr = compile_with(c"bin/wv2", arch64, 16, src, norotate)
	process_result* ce = compile_with(c"bin/wv2", arch64, 64, src, noexpr)
	process_result* cw = compile_with(c"bin/wv2", arch64, 128, src, nonarrow)
	process_result* cx = compile_with(c"bin/wv2", arch64, 256, src, nobudget)
	process_result* co = compile_with(c"bin/wv2", arch64, opt_out_all, src, noopt)
	process_result* ci = compile_with(c"bin/wv2", arch64, opt_in_inline, src, inl)
	if ((ca.status != 0) || (cb.status != 0) || (cd.status != 0) || (cn.status != 0) || (cm.status != 0) || (cr.status != 0) || (ce.status != 0) || (cw.status != 0) || (cx.status != 0) || (co.status != 0) || (ci.status != 0)):
		# A source that does not compile is still a comparison: every
		# build must fail the same way
		if (same_compile(ca, cb, c"MISMATCH (compile)", name) == 0): return
		if (same_compile(ca, cd, c"MISMATCH (compile, --no-direct-calls)", name) == 0): return
		if (same_compile(ca, cn, c"MISMATCH (compile, --no-cond-branch)", name) == 0): return
		if (same_compile(ca, cm, c"MISMATCH (compile, --no-addr-modes)", name) == 0): return
		if (same_compile(ca, cr, c"MISMATCH (compile, --no-loop-rotate)", name) == 0): return
		if (same_compile(ca, ce, c"MISMATCH (compile, --no-expr-regs)", name) == 0): return
		if (same_compile(ca, cw, c"MISMATCH (compile, --no-narrow-regs)", name) == 0): return
		if (same_compile(ca, cx, c"MISMATCH (compile, --no-x86-budget)", name) == 0): return
		if (same_compile(ca, co, c"MISMATCH (compile, every opt-out)", name) == 0): return
		if (same_compile(ca, ci, c"MISMATCH (compile, --inline)", name) == 0): return
		skipped = skipped + 1
		return

	# The compilers built with each opt-out, and with all of them, must
	# emit the same bytes as bin/wv2 (same output path: the binary embeds
	# its own name).
	shell_status(c"/bin/cp", regs, regs_keep)
	if (same_output(noregs_compiler(), arch64, src, regs, regs_keep, c"--no-regs-built", name) == 0): return
	if (same_output(nodirect_compiler(), arch64, src, regs, regs_keep, c"--no-direct-calls-built", name) == 0): return
	if (same_output(nocond_compiler(), arch64, src, regs, regs_keep, c"--no-cond-branch-built", name) == 0): return
	if (same_output(noaddr_compiler(), arch64, src, regs, regs_keep, c"--no-addr-modes-built", name) == 0): return
	if (same_output(norotate_compiler(), arch64, src, regs, regs_keep, c"--no-loop-rotate-built", name) == 0): return
	if (same_output(noexpr_compiler(), arch64, src, regs, regs_keep, c"--no-expr-regs-built", name) == 0): return
	if (same_output(nonarrow_compiler(), arch64, src, regs, regs_keep, c"--no-narrow-regs-built", name) == 0): return
	if (same_output(nobudget_compiler(), arch64, src, regs, regs_keep, c"--no-x86-budget-built", name) == 0): return
	if (same_output(noopt_compiler(), arch64, src, regs, regs_keep, c"every-opt-out-built", name) == 0): return
	if (same_output(inline_compiler(), arch64, src, regs, regs_keep, c"--inline-built", name) == 0): return

	process_result* ra = run_as(regs, name, stdin_text, timeout_ms)
	if (compare_runs(ra, regs, noregs, c"--no-regs", name, stdin_text, timeout_ms) == 0): return
	if (compare_runs(ra, regs, nodirect, c"--no-direct-calls", name, stdin_text, timeout_ms) == 0): return
	if (compare_runs(ra, regs, nocond, c"--no-cond-branch", name, stdin_text, timeout_ms) == 0): return
	if (compare_runs(ra, regs, noaddr, c"--no-addr-modes", name, stdin_text, timeout_ms) == 0): return
	if (compare_runs(ra, regs, norotate, c"--no-loop-rotate", name, stdin_text, timeout_ms) == 0): return
	if (compare_runs(ra, regs, noexpr, c"--no-expr-regs", name, stdin_text, timeout_ms) == 0): return
	if (compare_runs(ra, regs, nonarrow, c"--no-narrow-regs", name, stdin_text, timeout_ms) == 0): return
	if (compare_runs(ra, regs, nobudget, c"--no-x86-budget", name, stdin_text, timeout_ms) == 0): return
	if (compare_runs(ra, regs, noopt, c"--no-regs --no-direct-calls --no-cond-branch --no-addr-modes --no-loop-rotate --no-expr-regs --no-narrow-regs --no-x86-budget", name, stdin_text, timeout_ms) == 0): return
	if (compare_runs(ra, regs, inl, c"--inline", name, stdin_text, timeout_ms) == 0): return
	compared = compared + 1


int part_index
int part_count


# W_REGALLOC_DIFF_PART=k/n (header comment); a malformed value fails
# the run rather than silently sweeping a different slice.
void read_part():
	part_index = 0
	part_count = 1
	char* spec = env_get(c"W_REGALLOC_DIFF_PART")
	if (spec == 0): return
	int slash = 0
	while ((spec[slash] != 0) && (spec[slash] != '/')): slash = slash + 1
	asserts(c"W_REGALLOC_DIFF_PART is k/n", spec[slash] == '/')
	part_index = atoi(spec)
	part_count = atoi(&spec[slash + 1])
	asserts(c"W_REGALLOC_DIFF_PART has 0 <= k < n", (part_count > 0) && (part_index >= 0) && (part_index < part_count))


# The sweep over the manifest; shard -1 means every target.
void run_shard(int shard):
	read_part()
	json_value* manifest = json_parse(wbg_generate(c"build.base.json", 1))
	asserts(c"manifest parses", manifest != 0)
	json_value* targets = json_object_get(manifest, c"targets")
	asserts(c"manifest has targets", targets != 0)
	int candidates = 0
	int selected = 0
	for i in range(json_array_length(targets)):
		json_value* t = json_array_get(targets, i)
		json_value* steps = json_object_get(t, c"steps")
		if (steps == 0): continue
		if (json_array_length(steps) != 2): continue
		json_value* c0 = json_object_get(json_array_get(steps, 0), c"cmd")
		json_value* run = json_array_get(steps, 1)
		json_value* c1 = json_object_get(run, c"cmd")
		if ((c0 == 0) || (c1 == 0)): continue
		int n0 = json_array_length(c0)
		if ((n0 != 4) && (n0 != 5)): continue
		if (strcmp(arg_at(c0, 0), c"bin/wv2") != 0): continue
		int arch64 = 0
		if (n0 == 5):
			if (strcmp(arg_at(c0, 1), c"x64") != 0): continue
			arch64 = 1
		if (strcmp(arg_at(c0, n0 - 2), c"-o") != 0): continue
		char* src = arg_at(c0, n0 - 3)
		char* out = arg_at(c0, n0 - 1)
		if (json_array_length(c1) != 1): continue
		if (strcmp(arg_at(c1, 0), out) != 0): continue
		int in_part = (candidates % part_count) == part_index
		candidates = candidates + 1
		if (in_part == 0): continue
		int mine = (shard < 0) || ((selected % shard_count) == shard)
		selected = selected + 1
		if (mine == 0): continue
		char* stdin_text = json_text(json_object_get(run, c"stdin"))
		int timeout_ms = default_timeout_ms
		json_value* limit = json_object_get(run, c"timeout_ms")
		if (limit != 0): timeout_ms = limit.int_value
		sweep_target(json_text(json_object_get(t, c"name")), arch64, src, stdin_text, timeout_ms)
	print(c"regalloc_diff: part ")
	print(itoa(part_index))
	print(c"/")
	print(itoa(part_count))
	print(c", shard ")
	print(itoa(shard))
	print(c": ")
	print(itoa(compared))
	print(c" compared, ")
	print(itoa(skipped))
	print(c" skipped, ")
	print(itoa(mismatches))
	println(c" mismatches")


int main(int argc, char** argv):
	if ((argc == 3) && (strcmp(argv[1], c"--shard") == 0)):
		run_shard(atoi(argv[2]))
		if (mismatches > 0): return 1
		return 0

	read_part()
	shell_status(c"/bin/mkdir", c"-p", scratch_dir())
	process_result* build = compile_with(c"bin/wv2", 0, 1, c"w.w", noregs_compiler())
	asserts(c"building the --no-regs compiler", build.status == 0)
	build = compile_with(c"bin/wv2", 0, 2, c"w.w", nodirect_compiler())
	asserts(c"building the --no-direct-calls compiler", build.status == 0)
	build = compile_with(c"bin/wv2", 0, 4, c"w.w", nocond_compiler())
	asserts(c"building the --no-cond-branch compiler", build.status == 0)
	build = compile_with(c"bin/wv2", 0, 8, c"w.w", noaddr_compiler())
	asserts(c"building the --no-addr-modes compiler", build.status == 0)
	build = compile_with(c"bin/wv2", 0, 16, c"w.w", norotate_compiler())
	asserts(c"building the --no-loop-rotate compiler", build.status == 0)
	build = compile_with(c"bin/wv2", 0, 64, c"w.w", noexpr_compiler())
	asserts(c"building the --no-expr-regs compiler", build.status == 0)
	build = compile_with(c"bin/wv2", 0, 128, c"w.w", nonarrow_compiler())
	asserts(c"building the --no-narrow-regs compiler", build.status == 0)
	build = compile_with(c"bin/wv2", 0, 256, c"w.w", nobudget_compiler())
	asserts(c"building the --no-x86-budget compiler", build.status == 0)
	build = compile_with(c"bin/wv2", 0, opt_out_all, c"w.w", noopt_compiler())
	asserts(c"building the every-opt-out compiler", build.status == 0)
	build = compile_with(c"bin/wv2", 0, opt_in_inline, c"w.w", inline_compiler())
	asserts(c"building the --inline compiler", build.status == 0)

	process** shards = cast(process**, malloc(shard_count * __word_size__))
	for k in range(shard_count):
		char** args = strv_new(3)
		args[0] = argv[0]
		args[1] = c"--shard"
		args[2] = itoa(k)
		shards[k] = process_spawn(argv[0], args, 0)
		asserts(c"spawning a shard", cast(int, shards[k]) != 0)
	int failed = 0
	for k in range(shard_count):
		if (process_wait(shards[k]) != 0): failed = failed + 1
	if (failed > 0):
		print(c"regalloc_diff_test: ")
		print(itoa(failed))
		println(c" shard(s) reported mismatches")
		return 1
	println(c"regalloc_diff_test passed")
	return 0
