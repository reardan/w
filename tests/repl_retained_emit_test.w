# S2.4: the in-process compilers on the retained path. The REPL (repl.w)
# and wdbg take --ast-emit-retained like a compile does (repl_ast_options in
# repl/core.w), so every entry, persistent definition, function body and
# debugger evaluation is lowered from the retained forest, statement by
# statement, and rolled back with it on an error or a runtime fault.
#
# This differential test replays every stdin script of the REPL's and the
# debugger's own suites (repl_test's tests/repl_fixture.w.wbuild and
# debug_test's tests/debug_fixture.w.wbuild, so the scripts cannot drift)
# through the streaming front end (--streaming, the baseline since the AST
# front end became the default in P1.4) and through --ast-emit-retained, on
# the 32-bit and the 64-bit binaries, and requires the same exit status,
# stdout and stderr. Output that differs between two baseline runs of the same script
# (register dumps, stack addresses) is normalized first: staging directory
# pids and hexadecimal numbers; a script whose baseline output still differs
# between two runs is not compared, and the test asserts how few those are.
# A difference from the retained run is retried twice before it fails.
# test_repl_retained_recovery adds the REPL recovery legs of
# ast_expression_test and ast_retained_emit_test on all three front ends.
import lib.testing
import lib.file
import lib.process
import lib.str


struct retained_script:
	char* command
	char* stdin_text


int retained_compared
int retained_skipped


# A '# wbuild:' value at text[j]: a bare word, or a double-quoted string
# with the manifest's \n \t \" \\ escapes (tools/wbuildgen_lib.w,
# wbg_parse_value). Returns the decoded value, or 0 when malformed.
char* retained_value(char* text, int j):
	string_builder* out = string_new()
	if (text[j] != '"'):
		while ((text[j] != 0) && (text[j] != ' ') && (text[j] != 9)):
			string_append_char(out, text[j])
			j = j + 1
	else:
		j = j + 1
		while (text[j] != '"'):
			if (text[j] == 0):
				string_free(out)
				return 0
			if (text[j] == 92):
				j = j + 1
				if (text[j] == 'n'): string_append_char(out, 10)
				else if (text[j] == 't'): string_append_char(out, 9)
				else: string_append_char(out, text[j])
			else: string_append_char(out, text[j])
			j = j + 1
	char* value = strclone(out.data)
	string_free(out)
	return value


# Index just past the first occurrence of key in line, or -1.
int retained_find(char* line, char* key):
	int i = 0
	while (line[i]):
		if (starts_with(line + i, key)): return i + strlen(key)
		i = i + 1
	return -1


# The steps of a fixture file whose command starts with program, with their
# piped stdin. Steps that redirect output to a file keep their stdin.
list[retained_script*] retained_scripts(char* path, char* program):
	list[retained_script*] scripts = new list[retained_script*]
	list[char*] lines = file_read_lines(path)
	assert1(lines != 0)
	for line in lines:
		int step = retained_find(line, c" step=")
		int input = retained_find(line, c" stdin=")
		if ((step < 0) || (input < 0)): continue
		char* command = retained_value(line, step)
		if ((command == 0) || (starts_with(command, program) == 0)):
			if (command != 0): free(command)
			continue
		char* after = command + strlen(program)
		if ((after[0] != 0) && (after[0] != ' ')):
			free(command)
			continue
		retained_script* script = new retained_script
		script.command = command
		script.stdin_text = retained_value(line, input)
		assert1(script.stdin_text != 0)
		scripts.push(script)
	return scripts


# 1 when text starts with a decimal number followed by " (0x".
int retained_decimal_address(char* text):
	int i = 0
	while ((text[i] >= '0') && (text[i] <= '9')): i = i + 1
	return starts_with(text + i, c" (0x")


# Staging directories are pid-tagged and registers, stack and code
# addresses vary from run to run. The ":symbols" dump's "pointer (n)" column
# is the symbol table's declaration-time pointer_indirection, a field that
# nothing reads back: for an identifier first referenced before its
# declaration (a placeholder entry such as lib.lib's SYS_CREAT or the
# runtime's __w_list), it records whatever level the parse or emission last
# left in that global, which differs between the two modes. ":time" prints
# a wall-clock duration. A runtime fault's stack trace scans the raw stack
# for return addresses (repl_fault_trace), so below the real frames it
# lists stale ones the in-process compile left there; its "  at" lines are
# dropped.
char* retained_normalize(char* text):
	string_builder* out = string_new()
	int i = 0
	while (text[i]):
		if (((i == 0) || (text[i - 1] == 10)) && starts_with(text + i, c"  at ")):
			while (text[i] && (text[i] != 10)): i = i + 1
			if (text[i]): i = i + 1
		else if (starts_with(text + i, c"elapsed: ")):
			string_append(out, c"elapsed: <ms>")
			i = i + strlen(c"elapsed: ")
			while ((text[i] >= '0') && (text[i] <= '9')): i = i + 1
		else if (starts_with(text + i, c") pointer (")):
			string_append(out, c") pointer (n)")
			i = i + strlen(c") pointer (")
			while ((text[i] >= '0') && (text[i] <= '9')): i = i + 1
			if (text[i] == ')'): i = i + 1
		else if (starts_with(text + i, c"/tmp/w_repl_")):
			string_append(out, c"/tmp/w_repl_<pid>")
			i = i + strlen(c"/tmp/w_repl_")
			while ((text[i] >= '0') && (text[i] <= '9')): i = i + 1
		else if ((text[i] >= '0') && (text[i] <= '9') && ((i == 0) || (text[i - 1] == ' ')) && retained_decimal_address(text + i)):
			# A pointer printed as "value (0x...)": the decimal half varies too.
			string_append(out, c"<n>")
			while ((text[i] >= '0') && (text[i] <= '9')): i = i + 1
		else if ((text[i] == '0') && (text[i + 1] == 'x')):
			string_append(out, c"0x<hex>")
			i = i + 2
			while (((text[i] >= '0') && (text[i] <= '9')) || ((text[i] >= 'a') && (text[i] <= 'f')) || ((text[i] >= 'A') && (text[i] <= 'F'))): i = i + 1
		else:
			string_append_char(out, text[i])
			i = i + 1
	char* result = strclone(out.data)
	string_free(out)
	return result


struct retained_run:
	int status
	char* stdout_text
	char* stderr_text


void retained_run_free(retained_run* run):
	free(run.stdout_text)
	free(run.stderr_text)
	free(cast(char*, run))


# Run binary with the command's arguments (after its program word), an
# optional extra flag and the script's stdin.
retained_run* retained_execute(char* binary, retained_script* script, char* flag):
	list[char*] words = new list[char*]
	char* rest = script.command
	while (rest[0] && (rest[0] != ' ')): rest = rest + 1
	while (rest[0]):
		while (rest[0] == ' '): rest = rest + 1
		int length = 0
		while (rest[length] && (rest[length] != ' ')): length = length + 1
		if (length > 0): words.push(substring(rest, 0, length))
		rest = rest + length
	char** args = strv_new(words.length + 2)
	strv_set(args, 0, binary)
	int at = 1
	for word in words:
		strv_set(args, at, word)
		at = at + 1
	if (flag != 0): strv_set(args, at, flag)
	process_result* result = process_run(binary, args, 0, script.stdin_text, 60000)
	free(cast(void*, args))
	for word in words: free(word)
	words.free()
	assert1(result != 0)
	retained_run* run = new retained_run
	run.status = result.status
	run.stdout_text = retained_normalize(result.stdout_text)
	run.stderr_text = retained_normalize(result.stderr_text)
	process_result_free(result)
	return run


int retained_same(retained_run* a, retained_run* b):
	return (a.status == b.status) && (strcmp(a.stdout_text, b.stdout_text) == 0) && (strcmp(a.stderr_text, b.stderr_text) == 0)


# The first line where two outputs differ, with its line number.
void retained_first_difference(char* label, char* a, char* b):
	if (strcmp(a, b) == 0): return
	int line = 1
	int i = 0
	while (a[i] && (a[i] == b[i])):
		if (a[i] == 10): line = line + 1
		i = i + 1
	while ((i > 0) && (a[i - 1] != 10)): i = i - 1
	int end_a = i
	while (a[end_a] && (a[end_a] != 10)): end_a = end_a + 1
	int end_b = i
	while (b[end_b] && (b[end_b] != 10)): end_b = end_b + 1
	char* left = substring(a, i, end_a - i)
	char* right = substring(b, i, end_b - i)
	println(f"{label} line {line}:")
	println(f"  baseline: {left}")
	println(f"  retained: {right}")
	free(left)
	free(right)


void retained_report(char* binary, retained_script* script, retained_run* plain, retained_run* retained):
	println(f"--ast-emit-retained differs: {binary} {script.command}")
	println(f"status {plain.status} vs {retained.status}; stdin:")
	println(script.stdin_text)
	retained_first_difference(c"stdout", plain.stdout_text, retained.stdout_text)
	retained_first_difference(c"stderr", plain.stderr_text, retained.stderr_text)


# Every script of the fixture through binary, --streaming vs --ast-emit-retained.
# A difference is retried twice: output that depends on the machine's state
# (a shell command's, say) can change between two runs.
void retained_differential(char* binary, list[retained_script*] scripts):
	for script in scripts:
		int attempts = 0
		int varies = 0
		int same = 0
		while ((attempts < 3) && (same == 0) && (varies == 0)):
			retained_run* plain = retained_execute(binary, script, c"--streaming")
			retained_run* again = retained_execute(binary, script, c"--streaming")
			if (retained_same(plain, again) == 0): varies = 1
			else:
				retained_run* retained = retained_execute(binary, script, c"--ast-emit-retained")
				same = retained_same(plain, retained)
				if ((same == 0) && (attempts == 2)): retained_report(binary, script, plain, retained)
				retained_run_free(retained)
			retained_run_free(again)
			retained_run_free(plain)
			attempts = attempts + 1
		if (varies): retained_skipped = retained_skipped + 1
		else:
			assert1(same)
			retained_compared = retained_compared + 1


void test_repl_fixture_scripts_retained():
	list[retained_script*] scripts = retained_scripts(c"tests/repl_fixture.w.wbuild", c"bin/repl")
	assert1(scripts.length >= 40)
	retained_compared = 0
	retained_skipped = 0
	retained_differential(c"bin/repl_retained_emit_repl", scripts)
	retained_differential(c"bin/repl_retained_emit_repl64", scripts)
	println(f"repl scripts compared {retained_compared}, nondeterministic {retained_skipped}")
	assert1(retained_skipped * 10 <= retained_compared)


void test_wdbg_fixture_scripts_retained():
	list[retained_script*] scripts = retained_scripts(c"tests/debug_fixture.w.wbuild", c"bin/wdbg")
	list[retained_script*] scripts64 = retained_scripts(c"tests/debug_fixture.w.wbuild", c"bin/wdbg64")
	assert1(scripts.length >= 40)
	assert1(scripts64.length >= 40)
	retained_compared = 0
	retained_skipped = 0
	retained_differential(c"bin/wdbg", scripts)
	retained_differential(c"bin/wdbg64", scripts64)
	println(f"wdbg scripts compared {retained_compared}, nondeterministic {retained_skipped}")
	assert1(retained_skipped * 10 <= retained_compared)


# The REPL recovery legs: errors inside expressions, statements and
# function bodies roll back mid-walk; redefinitions repatch callers; :reset.
# --streaming, the default AST front end and --ast-emit-retained agree.
void retained_recovery(char* text):
	retained_script script
	script.command = c"repl"
	script.stdin_text = text
	for host in range(2):
		char* binary = c"bin/repl_retained_emit_repl"
		if (host): binary = c"bin/repl_retained_emit_repl64"
		retained_run* plain = retained_execute(binary, &script, c"--streaming")
		retained_run* full = retained_execute(binary, &script, 0)
		retained_run* retained = retained_execute(binary, &script, c"--ast-emit-retained")
		assert_equal(0, retained.status)
		if (retained_same(plain, retained) == 0): retained_report(binary, &script, plain, retained)
		assert1(retained_same(plain, retained))
		assert1(retained_same(full, retained))
		retained_run_free(plain)
		retained_run_free(full)
		retained_run_free(retained)


void test_repl_retained_recovery():
	retained_recovery(c"(6 * 7)\n(4294967296 + 1)\n(1 + )\nint keep = (5 * 9)\nkeep + (2 * 3)\n(keep) = 23\n(keep + 7)\nint keep = 60\n(keep + 3)\nint old(): return (keep + 4)\n(keep + missing)\n(old())\nint callee(int n): return n + 1\nint caller(int n): return (callee(n) * 2)\n(caller(20))\nint callee(int n): return n + 3\n(caller(20))\n(1.5 + 2.5)\n(1e+ + 2)\n(caller(20))\nint* nil = 0\n(nil && nil[0])\n(!nil || *nil)\n(2 < 3 && caller(20) == 46)\n(false && missing)\n(caller(20) >= 46)\nbool yes = true\n(yes)\n(!yes)\nstruct AstPointer: int x\n(cast(AstPointer**, 0) + missing)\n(cast(AstPointer**, 0) == 0)\n(cast(AstPointer***, 0) + )\n(cast(AstPointer***, 0) == 0)\n:reset\n(8 * 9)\n:quit\n")
	retained_recovery(c"int header(int n) { if (n < 0) { return -1; } while (n > 2) { n -= 1; } return n; }\nheader(9)\nheader(-2)\nint header(int n): if (n + ): return n\nheader(9)\nint header(int n) { while (n > 0) { n -= 1; } return n; }\nheader(9)\n7427\n:quit\n")
	retained_recovery(c"struct AstFresh:\n\tint value\n\n(list[AstFresh]{AstFresh(21)}.length + missing)\nitems := list[AstFresh]{AstFresh(42)}\nitems[0].value\n(list[list[AstFresh]]{list[AstFresh]{AstFresh(18446744073709551616)}}.length)\nnested := list[list[AstFresh]]{items}\nnested[0][0].value\nsizeof(list[AstFresh]**)\n7427\n:quit\n")
	retained_recovery(c"int n = 3\nif (n > 2): n = n + 1\nn\nwhile (n < 10): n = n + 2\nn\nif (n + ): n = 0\nn\nwhile (n + ): n = 0\nn\nint f(int x):\n\tif x > 5:\n\t\treturn 1\n\telif x > 2: return 2\n\twhile x < 0: x = x + 1\n\treturn 3\n\n(f(9) * 100 + f(3) * 10 + f(-4))\nint g(int x):\n\tif (x +): return 1\n\treturn 0\n\n(f(1))\n:quit\n")
	# A body that fails after walked statements, a fault inside a walked
	# loop, defer and for loops in an entry, and a redefinition after both.
	retained_recovery(c"int total(int n):\n\tint sum = 0\n\tfor i in range(n):\n\t\tsum = sum + i\n\tdefer sum = 0\n\treturn sum\n\ntotal(5)\nint total(int n):\n\tint sum = 0\n\twhile (sum < n):\n\t\tsum = sum + 1\n\treturn sum + missing\n\ntotal(5)\nint* hole = 0\nint k = 0\nwhile (k < 3):\n\tk = k + 1\n\tif (k == 2): hole[0] = k\n\nk\nfor j in range(3): k = k + j\nk\nswitch k:\n\tcase 3: k = 30\n\tdefault: k = 40\n\nk\nint total(int n): return n * 100\ntotal(5)\n:quit\n")



# P1.4: --streaming is the opt-out from the default AST front end, and the
# in-process compilers reject it next to an AST-only flag with the driver's
# own error (repl_ast_options), before any session starts.
void retained_streaming_conflict(char* binary, char* path, char* flag):
	char** args = strv_new(4)
	strv_set(args, 0, binary)
	int at = 1
	if (path != 0):
		strv_set(args, at, path)
		at = at + 1
	strv_set(args, at, c"--streaming")
	strv_set(args, at + 1, flag)
	process_result* result = process_run(binary, args, 0, c":quit\n", 60000)
	free(cast(void*, args))
	assert1(result != 0)
	assert_equal(1, result.status)
	assert_contains(result.stderr_text, c"error: '--streaming' cannot be combined with '")
	assert_contains(result.stderr_text, flag)
	process_result_free(result)


void test_streaming_conflicts_with_ast_only_flags():
	retained_streaming_conflict(c"bin/repl_retained_emit_repl", 0, c"--ast-emit-retained")
	retained_streaming_conflict(c"bin/repl_retained_emit_repl64", 0, c"--ast-retain")
	retained_streaming_conflict(c"bin/repl_retained_emit_repl", 0, c"--ast-required")
	retained_streaming_conflict(c"bin/wdbg", c"tests/debug_fixture.w", c"--ast-full-expressions")
	retained_streaming_conflict(c"bin/wdbg64", c"tests/debug_fixture.w", c"--ast-emit-retained")

# wbuild: binary=repl_retained_emit_test tag=tests dep=wv2 dep=wdbg dep=wdbg_x64 data=tests/repl_fixture.w.wbuild data=tests/debug_fixture.w.wbuild data=tests/debug_fixture.w data=tests/debug_fixture2.w data=tests/debug_fixture3.w data=tests/debug_fixture4.w data=tests/debug_fixture5.w data=tests/segv_fixture.w
# wbuild: step="bin/wv2 repl.w -o bin/repl_retained_emit_repl"
# wbuild: step="bin/wv2 x64 repl.w -o bin/repl_retained_emit_repl64"
# wbuild: step="bin/repl_retained_emit_test" timeout=1800000
