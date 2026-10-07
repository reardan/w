# wbuild: timeout=1800000
/*
Differential sweep for register promotion (unit R2,
docs/projects/register_allocation_pgo.md §5): every conventional
compile-and-run target of the generated manifest is built twice, with
promotion (the default) and with --no-regs, on the width its target
names (x86 or x64), and the two binaries must behave identically: exit
status, stdout and stderr. The same source is also compiled by a
compiler that was itself built with --no-regs, and that output must be
byte-identical to bin/wv2's (promotion must not change what the
compiler emits, only how the compiler's own code runs).

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
itself with --shard k); the parent builds the --no-regs compiler, waits
for the shards and fails when any of them reported a mismatch.
*/
import lib.lib
import lib.assert
import lib.process
import lib.file
import structures.json
import tools.wbuildgen_lib


const int shard_count = 4
const int default_timeout_ms = 60000
char* scratch_dir():
	return c"bin/regalloc_diff"


char* noregs_compiler():
	return c"bin/regalloc_diff/wv2_noregs"


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


# bin/wv2 [x64] [--no-regs] src -o out
process_result* compile_with(char* compiler, int arch64, int no_regs, char* src, char* out):
	char** argv = strv_new(7)
	int n = 0
	argv[n] = compiler
	n = n + 1
	argv[n] = c"--quiet"
	n = n + 1
	if (arch64):
		argv[n] = c"x64"
		n = n + 1
	if (no_regs):
		argv[n] = c"--no-regs"
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

	process_result* ca = compile_with(c"bin/wv2", arch64, 0, src, regs)
	process_result* cb = compile_with(c"bin/wv2", arch64, 1, src, noregs)
	if ((ca.status != 0) || (cb.status != 0)):
		# A source that does not compile is still a comparison: both
		# builds must fail the same way
		if ((ca.status != cb.status) || (strcmp(ca.stderr_text, cb.stderr_text) != 0)):
			mismatches = mismatches + 1
			report(c"MISMATCH (compile)", name, cb.stderr_text)
		else: skipped = skipped + 1
		return

	# The --no-regs-built compiler must emit the same bytes as bin/wv2
	# (same output path: the binary embeds its own name).
	shell_status(c"/bin/cp", regs, regs_keep)
	process_result* cc = compile_with(noregs_compiler(), arch64, 0, src, regs)
	if ((cc.status != 0) || (shell_status(c"/usr/bin/cmp", regs, regs_keep) != 0)):
		mismatches = mismatches + 1
		report(c"MISMATCH (compiler output differs from the --no-regs-built compiler)", name, 0)
		return

	process_result* ra = run_as(regs, name, stdin_text, timeout_ms)
	process_result* rb = run_as(noregs, name, stdin_text, timeout_ms)
	if (same_result(ra, rb) == 0):
		process_result* rb2 = run_as(noregs, name, stdin_text, timeout_ms)
		process_result* ra2 = run_as(regs, name, stdin_text, timeout_ms)
		if ((same_result(rb, rb2) == 0) || (same_result(ra, ra2) == 0)):
			report(c"nondeterministic (two runs of one build differ), not compared", name, 0)
			skipped = skipped + 1
		else:
			mismatches = mismatches + 1
			report(c"MISMATCH (behaviour)", name, 0)
			print(c"  status ")
			print(itoa(ra.status))
			print(c" vs ")
			println(itoa(rb.status))
			if (same_text(ra.stdout_text, rb.stdout_text) == 0): println(c"  stdout differs")
			if (same_text(ra.stderr_text, rb.stderr_text) == 0): println(c"  stderr differs")
	else: compared = compared + 1


# The sweep over the manifest; shard -1 means every target.
void run_shard(int shard):
	json_value* manifest = json_parse(wbg_generate(c"build.base.json", 1))
	asserts(c"manifest parses", manifest != 0)
	json_value* targets = json_object_get(manifest, c"targets")
	asserts(c"manifest has targets", targets != 0)
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
		int mine = (shard < 0) || ((selected % shard_count) == shard)
		selected = selected + 1
		if (mine == 0): continue
		char* stdin_text = json_text(json_object_get(run, c"stdin"))
		int timeout_ms = default_timeout_ms
		json_value* limit = json_object_get(run, c"timeout_ms")
		if (limit != 0): timeout_ms = limit.int_value
		sweep_target(json_text(json_object_get(t, c"name")), arch64, src, stdin_text, timeout_ms)
	print(c"regalloc_diff: shard ")
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

	shell_status(c"/bin/mkdir", c"-p", scratch_dir())
	process_result* build = compile_with(c"bin/wv2", 0, 1, c"w.w", noregs_compiler())
	asserts(c"building the --no-regs compiler", build.status == 0)

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
