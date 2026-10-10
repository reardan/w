# --ast-emit-retained (S2.1) lowers every expression from its retained
# group instead of the temporary parse arena. This differential test
# compiles each source fixture of ast_expression_test in both modes and
# requires identical exit status, stdout, stderr and image bytes: every
# fixture for x86 on the 32-bit host and x64 on the 64-bit host, one more
# target per fixture rotated across arm64, arm64_darwin, win64 and wasm32
# on alternating hosts, and a `check --json --lint` leg for the lint
# warnings the AST replays (self-assignment, condition assignment). Since S2.5 made this mode the default, nothing lowers the temporary
# parse any more, so every baseline leg (the lint leg and the REPL sessions
# included) is the streaming front end, --streaming; it reports the same lint
# on these fixtures since #558's warnings were ported to the AST (#571). The
# fixture list is read from ast_expression_test's directive, so the two
# cannot drift; the data= list below must cover it (asserted).
# S2.2a adds the statement-walk sources (emit_walk_sources) on the same legs,
# S2.2d the declaration, goto/label, raw_asm and defer ones, S2.2c the
# for/switch header fixture and emit_header_walk_sources, and S2.2b
# blocks, if/elif/else and while;
# S2.2e adds the launch/gpu for walk sources (whose x64 legs compile them).
import lib.testing
import lib.file
import lib.process
import lib.str
import lib.container


struct emit_run:
	char* stem
	process* child
	int done


struct emit_pair:
	char* host
	char* arch
	char* source
	int check
	emit_run* runs


list[char*] emit_failures
int emit_serial


# The data= paths of the first line in path that starts with directive.
list[char*] emit_directive_data(char* path, char* directive):
	list[char*] found = new list[char*]
	list[char*] lines = file_read_lines(path)
	assert1(lines != 0)
	for line in lines:
		if (starts_with(line, directive)):
			char* at = line
			while (*at):
				if (starts_with(at, c" data=")):
					at = at + 6
					int length = 0
					while (at[length] && (at[length] != ' ')): length = length + 1
					found.push(substring(at, 0, length))
					at = at + length
				else: at = at + 1
			return found
	return found


int emit_contains(list[char*] items, char* wanted):
	for item in items:
		if (strcmp(item, wanted) == 0): return 1
	return 0


char* emit_path(char* stem, char* suffix):
	string_builder* path = string_new()
	string_append(path, stem)
	string_append(path, suffix)
	char* result = strclone(path.data)
	string_free(path)
	return result


# Compare two whole files; a file missing on both sides is equal.
int emit_same_file(char* first, char* second):
	int fd = open(first, 0, 0)
	int gd = open(second, 0, 0)
	if ((fd < 0) || (gd < 0)):
		if (fd >= 0): close(fd)
		if (gd >= 0): close(gd)
		return (fd < 0) && (gd < 0)
	int size = file_size(fd)
	int same = size == file_size(gd)
	close(fd)
	close(gd)
	if (same == 0): return 0
	char* a = file_read_text(first)
	char* b = file_read_text(second)
	assert1((a != 0) && (b != 0))
	for i in range(size):
		if (a[i] != b[i]): same = 0
	free(a)
	free(b)
	return same


void emit_shell_word(string_builder* script, char* word):
	string_append(script, c" ")
	string_append(script, word)


# One compile, run through sh only for its redirections; exec keeps the
# compiler's own exit status as the child's.
process* emit_spawn(emit_pair* pair, int retained, char* stem):
	string_builder* script = string_new()
	string_append(script, c"exec")
	emit_shell_word(script, pair.host)
	if (pair.check):
		emit_shell_word(script, c"check")
		emit_shell_word(script, c"--json")
		emit_shell_word(script, c"--lint")
	if (strcmp(pair.arch, c"x86") != 0): emit_shell_word(script, pair.arch)
	emit_shell_word(script, c"--quiet")
	if (retained): emit_shell_word(script, c"--ast-emit-retained")
	else: emit_shell_word(script, c"--streaming")
	emit_shell_word(script, pair.source)
	if (pair.check == 0):
		emit_shell_word(script, c"-o")
		string_append(script, c" ")
		string_append(script, stem)
		string_append(script, c".image")
	string_append(script, c" >")
	string_append(script, stem)
	string_append(script, c".stdout 2>")
	string_append(script, stem)
	string_append(script, c".stderr")
	char** args = strv_new(4)
	strv_set(args, 0, c"/bin/sh")
	strv_set(args, 1, c"-c")
	strv_set(args, 2, script.data)
	spawn_options* opts = spawn_options_new()
	opts.stdin_mode = process_null
	process* child = process_spawn(c"/bin/sh", args, opts)
	assert1(child != 0)
	free(cast(void*, args))
	free(opts)
	string_free(script)
	return child


void emit_fail(emit_pair* pair, char* what):
	string_builder* message = string_new()
	string_append(message, pair.host)
	string_append(message, c" ")
	string_append(message, pair.arch)
	if (pair.check): string_append(message, c" check")
	string_append(message, c" ")
	string_append(message, pair.source)
	string_append(message, c": ")
	string_append(message, what)
	emit_failures.push(strclone(message.data))
	string_free(message)


void emit_compare(emit_pair* pair):
	emit_run* a = &pair.runs[0]
	emit_run* b = &pair.runs[1]
	if (process_wait(a.child) != process_wait(b.child)): emit_fail(pair, c"exit status differs")
	char*[3] suffixes
	suffixes[0] = c".stdout"
	suffixes[1] = c".stderr"
	suffixes[2] = c".image"
	for i in range(3):
		char* first = emit_path(a.stem, suffixes[i])
		char* second = emit_path(b.stem, suffixes[i])
		if (emit_same_file(first, second) == 0): emit_fail(pair, suffixes[i] + 1)
		unlink(first)
		unlink(second)
		free(first)
		free(second)
	process_free(a.child)
	process_free(b.child)


emit_pair* emit_pair_new(char* host, char* arch, char* source, int check):
	emit_pair* pair = new emit_pair()
	pair.host = host
	pair.arch = arch
	pair.source = source
	pair.check = check
	pair.runs = new emit_run[2]
	for i in range(2):
		string_builder* stem = string_new()
		string_append(stem, c"bin/ast_retained_emit_")
		string_append_int(stem, getpid())
		string_append(stem, c"_")
		string_append_int(stem, emit_serial)
		emit_serial = emit_serial + 1
		pair.runs[i].stem = strclone(stem.data)
		pair.runs[i].done = 0
		string_free(stem)
	return pair


# Run every compile with a few in flight; compare each pair once both of
# its compiles have exited, so at most a few images exist at once.
void emit_run_pairs(list[emit_pair*] pairs, int width):
	list[process*] active = new list[process*]
	list[int] owners = new list[int]
	int next = 0
	int total = pairs.length * 2
	int finished = 0
	while (finished < total):
		while ((next < total) && (active.length < width)):
			emit_pair* pair = pairs[next / 2]
			emit_run* run = &pair.runs[next % 2]
			run.child = emit_spawn(pair, next % 2, run.stem)
			active.push(run.child)
			owners.push(next)
			next = next + 1
		int index = process_wait_any(active, 1)
		assert1(index >= 0)
		int owner = owners[index]
		emit_pair* done = pairs[owner / 2]
		done.runs[owner % 2].done = 1
		if (done.runs[0].done && done.runs[1].done): emit_compare(done)
		list_remove_at[process*](active, index)
		list_remove_at[int](owners, index)
		finished = finished + 1


# S2.2a: sources whose simple, expression and return/yield statements the
# walk emits after their parse. The tracked fixture is valid W; the
# generated ones are not (space indentation, a missing terminator or final
# newline, an unterminated literal), so they are written under bin/ instead
# of being tracked. Each pins one place where a diagnostic printed by the
# rest of the statement's parse must stay ordered after (or before) the
# ones the walk emits.
list[char*] emit_walk_sources():
	list[char*] sources = new list[char*]
	sources.push(c"tests/ast_statement_walk_fixture.w")
	sources.push(c"tests/ast_declaration_walk_fixture.w")
	sources.push(c"tests/ast_control_walk_fixture.w")
	sources.push(c"tests/ast_gpu_walk_fixture.w")
	list[char*] texts = new list[char*]
	# A value warning after an indentation warning on the next line.
	texts.push(c"char* f(int x):\n\tint y = x\n\treturn y\n    \tint z = 1\n\treturn 0\n\nint main():\n\tf(1)\n\treturn 0\n")
	# ';' lexes the next line: the value warning comes first.
	texts.push(c"char* f(int x):\n\treturn x;\n    \treturn 0\n\nint main():\n\tf(1)\n\treturn 0\n")
	texts.push(c"void f(int x):\n\treturn x;\n  \tf(1)\n\nint main():\n\treturn 0\n")
	# A missing terminator after a value warning, and after nothing.
	texts.push(c"void f(int x):\n\treturn x )\n\nint main():\n\treturn 0\n")
	texts.push(c"int g\nvoid f(int x):\n\tg = x )\n\nint main():\n\treturn 0\n")
	texts.push(c"int main():\n\tpass )\n\treturn 0\n")
	# The source ends without a newline after the statement.
	texts.push(c"int main():\n\treturn 0\n\nchar* f(int x):\n\treturn x\n   ")
	texts.push(c"int g\nint main():\n\treturn 0\n\nvoid f(int x):\n\tg = x")
	# Branch errors are reported at the token after the terminator.
	texts.push(c"int main():\n\tdebugger;\n\tpass ; pass\n\tbreak\n\treturn 0\n")
	texts.push(c"int main():\n\tint x = 0\n\tx = 1\n  \tcontinue\n\treturn 0\n")
	texts.push(c"char* f(int x):\n\treturn x\n\t\"abc\n")
	texts.push(c"int main():\n\tyield 1\n\treturn 0\n")
	# S2.2d: an initialization warning after an indentation warning, before
	# a missing terminator, after ';' and at the end of the source.
	texts.push(c"int main():\n\tint n = 1\n\tchar* p = n\n    \treturn 0\n")
	texts.push(c"int main():\n\tint n = 1\n\tchar* p = n )\n\treturn 0\n")
	texts.push(c"int main():\n\tint n = 1\n\tchar* p = n;\n    \treturn 0\n")
	texts.push(c"int main():\n\treturn 0\n\nvoid f(int x):\n\tchar* p = x")
	# Declaration errors: from the bind phase, and from the parse.
	texts.push(c"void f():\n\tpass\n\nint main():\n\tx := f()\n\treturn 0\n")
	texts.push(c"int main():\n\tx := main\n\treturn 0\n")
	texts.push(c"int main():\n\tint[3] a = 0\n\treturn 0\n")
	texts.push(c"int main():\n\tint n = 1\n\tn := 2\n\treturn 0\n")
	# Labels and gotos: a duplicate, an undefined label, a bad terminator,
	# a label after an indentation warning.
	texts.push(c"int main():\n\tl:\n\tl:\n\treturn 0\n")
	texts.push(c"int main():\n\tgoto nowhere\n\treturn 0\n")
	texts.push(c"int main():\n\tgoto x )\n\tx:\n\treturn 0\n")
	texts.push(c"int main():\n\tint n = 1\n\tint m = n\n  \tx:\n\tgoto x\n")
	# raw_asm without its ')', defers whose skipped line prints.
	texts.push(c"int main():\n\traw_asm(c\"\\x90\" ;\n\treturn 0\n")
	texts.push(c"void g(char* s):\n\tpass\n\nint main():\n\tdefer g(\"abc\n\treturn 0\n")
	texts.push(c"void g(int s):\n\tpass\n\nint main():\n\tdefer g(1)\n  \treturn 0\n")
	# S2.2b: a condition's warning before the lexer's warning or error on
	# the body's first token.
	texts.push(c"int main():\n\tbool a = true\n\tbool b = false\n\tif a | b:\n    \treturn 1\n\treturn 0\n")
	texts.push(c"int main():\n\tbool a = true\n\twhile a & a:\n  \tbreak\n\treturn 0\n")
	texts.push(c"int main():\n\tbool a = true\n\tif a | a: \"abc\n\treturn 0\n")
	# The then-arm's exit is pending while 'elif' is lexed.
	texts.push(c"int main():\n\tbool a = true\n\tint x = 0\n\tif x: pass\n  \telif a | a: x = 1\n\telse: x = 2\n\treturn x\n")
	# The source ends inside a block, or without a newline after one.
	texts.push(c"int main():\n\tbool a = true\n\tif a | a:\n\t\treturn 1\n\treturn 0")
	texts.push(c"int main():\n\tbool a = true\n\tif a | a {\n\t\treturn 1\n")
	# Conditions the AST probe leaves to the streaming grammar.
	texts.push(c"int main():\n\tif (1 + ): pass\n\treturn 0\n")
	texts.push(c"int main():\n\twhile (1 + ): pass\n\treturn 0\n")
	texts.push(c"int main():\n\tint x = 0\n\tif x: pass\n\telif (x + ): pass\n\treturn 0\n")
	texts.push(c"int main():\n\tint x = 0\n\tif x == 1: x = 1\n\telif x == 2: y = 3\n\telse: x = 4\n\treturn x\n")
	# A deferred statement's warnings come before the unused-local lint
	# that closes the function body.
	texts.push(c"struct pt:\n\tint x\n\nvoid g(pt* p):\n\tpass\n\nvoid f():\n\tint unused = 1\n\tint* q = 0\n\tdefer g(q)\n\tbool a = true\n\tif a | a: return\n\nint main():\n\tf()\n\treturn 0\n")
	# S2.2e: a launch argument's warning is emitted by the walk; the parse
	# of the rest of the statement may print around it (x64 legs).
	char* gpu = c"void __w_gpu_launch_raw(char* n, int g, int b, int* v, int c): pass\nvoid __w_gpu_launch(char* n, int c, int* v, int k): pass\nint f(int x): return x\nkernel K(int x, int y): pass\nint main():\n\tint n = 4\n"
	texts.push(emit_path(gpu, c"\tlaunch K[1, 1](c\"s\", 2)\n    \treturn 0\n"))
	texts.push(emit_path(gpu, c"\tlaunch K[1, 1](c\"s\",\n    2)\n\treturn 0\n"))
	texts.push(emit_path(gpu, c"\tlaunch K[1, 1](c\"s\", f(c\"t\"))\n\treturn 0\n"))
	texts.push(emit_path(gpu, c"\tlaunch K[1, 1](c\"s\")\n\treturn 0\n"))
	texts.push(emit_path(gpu, c"\tlaunch K[1, 1](2, c\"s\" ]\n\treturn 0\n"))
	texts.push(emit_path(gpu, c"\tlaunch K[1, 1](2, c\"s\")"))
	texts.push(emit_path(gpu, c"\tlaunch K[1, 1](2, c\"s\" # c\n\t)\n\treturn 0\n"))
	texts.push(emit_path(gpu, c"\tlaunch K[1, 1](2, c\"s\", \"abc)\n\treturn 0\n"))
	texts.push(emit_path(gpu, c"\tgpu for int i in range(f(c\"s\"), n, 2):\n\t\tpass\n\treturn 0\n"))
	texts.push(emit_path(gpu, c"\tgpu for int i in range(1,\n  n):\n\t\tpass\n\treturn 0\n"))
	texts.push(emit_path(gpu, c"\tgpu for int i in range(n):\n\t\tf(c\"x\")\n  \treturn 0\n"))
	for i in range(texts.length):
		string_builder* path = string_new()
		string_append(path, c"bin/ast_retained_emit_walk_")
		string_append_int(path, getpid())
		string_append(path, c"_")
		string_append_int(path, i)
		string_append(path, c".w")
		char* name = strclone(path.data)
		string_free(path)
		assert1(file_write_text(name, texts[i]) >= 0)
		sources.push(name)
	return sources


# S2.2c: sources whose for-loop and switch headers the walk emits after
# their parse, written under bin/ like emit_walk_sources' (none is valid
# W). Each pins a header phase that prints (a switch selector error, a
# duplicate case value, a case type mismatch) against a later parse step
# that prints too (an indentation or end-of-file warning from the next
# lex, a header error), so the walk must emit before that step.
void emit_header_walk_sources(list[char*] sources):
	list[char*] texts = new list[char*]
	texts.push(c"int main():\n\tswitch 1.5:\n    \tcase 1: pass\n\treturn 0\n")
	texts.push(c"int main():\n\tswitch 1.5:\n\t\tcase 1: pass\n\treturn 0\n")
	texts.push(c"int main():\n\tswitch 1.5: pass\n\treturn 0\n")
	texts.push(c"int main():\n\treturn 0\n\nvoid f():\n\tswitch 1.5:")
	texts.push(c"int main():\n\tint x = 1\n\tswitch x:\n\t\tcase 1, 1,\n  \t\t\t2: pass\n\treturn 0\n")
	texts.push(c"int main():\n\tint x = 1\n\tswitch x:\n\t\tcase \"a\",\n  \t\t\t2: pass\n\treturn 0\n")
	texts.push(c"int main():\n\tint x = 1\n\tswitch x:\n\t\tcase 2: pass\n\t\tcase 2: pass\n\t\tdefault: pass\n\t\tcase 3: pass\n")
	texts.push(c"int main():\n\tint x = 1\n\tswitch x:\n\t\tcase \"a\", 3\n  \tpass\n")
	texts.push(c"int main():\n\tfor i in range(1, 2, 3, 4): pass\n\treturn 0\n")
	texts.push(c"int main():\n\tfor i in range(1,\n  \t3): pass\n\treturn 0\n")
	for i in range(texts.length):
		string_builder* path = string_new()
		string_append(path, c"bin/ast_retained_emit_header_")
		string_append_int(path, getpid())
		string_append(path, c"_")
		string_append_int(path, i)
		string_append(path, c".w")
		char* name = strclone(path.data)
		string_free(path)
		assert1(file_write_text(name, texts[i]) >= 0)
		sources.push(name)


void test_retained_emission_matches_default():
	emit_failures = new list[char*]
	list[char*] fixtures = emit_directive_data(c"tests/ast_expression_test.w", c"# wbuild: binary=ast_expression_test_prepare ")
	char* own = c"# wbuild: binary=ast_retained_emit_test "
	list[char*] declared = emit_directive_data(c"tests/ast_retained_emit_test.w", own)
	assert1(fixtures.length > 100)
	list[char*] sources = new list[char*]
	for fixture in fixtures:
		if (emit_contains(declared, fixture) == 0):
			print(c"missing data= for ")
			println(fixture)
			assert1(0)
		if (ends_with(fixture, c".w")): sources.push(fixture)
	sources.push(c"tests/ast_loop_switch_walk_fixture.w")
	char*[4] rotated
	rotated[0] = c"arm64"
	rotated[1] = c"arm64_darwin"
	rotated[2] = c"win64"
	rotated[3] = c"wasm"
	list[emit_pair*] pairs = new list[emit_pair*]
	for i in range(sources.length):
		char* source = sources[i]
		pairs.push(emit_pair_new(c"bin/wv2", c"x86", source, 0))
		pairs.push(emit_pair_new(c"bin/wv2_64", c"x64", source, 0))
		char* host = c"bin/wv2"
		if ((i / 4) % 2): host = c"bin/wv2_64"
		pairs.push(emit_pair_new(host, rotated[i % 4], source, 0))
		pairs.push(emit_pair_new(c"bin/wv2", c"x86", source, 1))
	list[char*] walked = emit_walk_sources()
	emit_header_walk_sources(walked)
	for i in range(walked.length):
		char* source = walked[i]
		pairs.push(emit_pair_new(c"bin/wv2", c"x86", source, 0))
		pairs.push(emit_pair_new(c"bin/wv2_64", c"x64", source, 0))
		char* host = c"bin/wv2_64"
		if ((i / 4) % 2): host = c"bin/wv2"
		pairs.push(emit_pair_new(host, rotated[i % 4], source, 0))
		pairs.push(emit_pair_new(c"bin/wv2", c"x86", source, 1))
	emit_run_pairs(pairs, 4)
	# Only the generated sources live under bin/; the fixtures are tracked.
	for source in walked:
		if (starts_with(source, c"bin/")): unlink(source)
	for failure in emit_failures:
		print(c"retained emission differs: ")
		println(failure)
	assert_equal(0, emit_failures.length)


# The retained forest is the only expression source in this mode; --stats
# counts the groups it lowered (w.w has tens of thousands).
void test_retained_emission_counts_groups():
	char** args = strv_new(8)
	strv_set(args, 0, c"bin/wv2")
	strv_set(args, 1, c"check")
	strv_set(args, 2, c"--ast-emit-retained")
	strv_set(args, 3, c"--stats")
	strv_set(args, 4, c"tests/ast_expression_fixture.w")
	process_result* result = process_run(c"bin/wv2", args, 0, 0, 60000)
	free(cast(void*, args))
	assert1(result != 0)
	assert_equal(0, result.status)
	assert_contains(result.stderr_text, c"Retained-emitted expressions: ")
	assert_equal(-1, index_of(result.stderr_text, c"Retained-emitted expressions: 0\n"))
	process_result_free(result)


# S2.2a: --stats splits the dispatcher's statements into those the walk
# emitted after their parse and those still emitted during it.
void test_retained_emission_counts_statements():
	char** args = strv_new(8)
	strv_set(args, 0, c"bin/wv2")
	strv_set(args, 1, c"check")
	strv_set(args, 2, c"--ast-emit-retained")
	strv_set(args, 3, c"--stats")
	strv_set(args, 4, c"tests/ast_statement_walk_fixture.w")
	process_result* result = process_run(c"bin/wv2", args, 0, 0, 60000)
	free(cast(void*, args))
	assert1(result != 0)
	assert_equal(0, result.status)
	assert_contains(result.stderr_text, c"Retained-emitted statements: ")
	assert_contains(result.stderr_text, c"Immediate statements: ")
	assert_equal(-1, index_of(result.stderr_text, c"Retained-emitted statements: 0\n"))
	process_result_free(result)


# S2.2d: declarations, labels, gotos, raw_asm and defer statements are
# walked too. The counters of a source with one of each, against the same
# program without them, differ only in walked statements.
int emit_statement_counter(char* text, char* label):
	int at = index_of(text, label)
	assert1(at >= 0)
	return atoi(text + at + strlen(label))


process_result* emit_stats(char* name, char* text):
	assert1(file_write_text(name, text) >= 0)
	char** args = strv_new(8)
	strv_set(args, 0, c"bin/wv2")
	strv_set(args, 1, c"check")
	strv_set(args, 2, c"--ast-emit-retained")
	strv_set(args, 3, c"--stats")
	strv_set(args, 4, name)
	process_result* result = process_run(c"bin/wv2", args, 0, 0, 60000)
	free(cast(void*, args))
	unlink(name)
	assert1(result != 0)
	assert_equal(0, result.status)
	return result


void test_retained_emission_walks_declarations():
	string_builder* path = string_new()
	string_append(path, c"bin/ast_retained_emit_counts_")
	string_append_int(path, getpid())
	string_append(path, c".w")
	process_result* bare = emit_stats(path.data, c"int main():\n\treturn 0\n")
	process_result* walked = emit_stats(path.data, c"int main():\n\tint a = 1\n\tint b\n\tc := a; b = c\n\tgoto l\n\tl:\n\traw_asm(\"\")\n\tdefer main()\n\treturn b\n")
	char* emitted = c"Retained-emitted statements: "
	char* immediate = c"Immediate statements: "
	assert_equal(emit_statement_counter(bare.stderr_text, emitted) + 8, emit_statement_counter(walked.stderr_text, emitted))
	assert_equal(emit_statement_counter(bare.stderr_text, immediate), emit_statement_counter(walked.stderr_text, immediate))
	process_result_free(bare)
	process_result_free(walked)
	string_free(path)


# REPL entries roll the retained forest back on error and redefine
# functions; lowering from the forest must replay the same session.
process_result* emit_repl(char* repl, char* flag, char* script):
	char** args = strv_new(2)
	strv_set(args, 0, repl)
	strv_set(args, 1, flag)
	process_result* result = process_run(repl, args, 0, script, 60000)
	free(cast(void*, args))
	assert1(result != 0)
	return result


void test_retained_emission_repl_session():
	char* script = c"(6 * 7)\n(4294967296 + 1)\n(1 + )\nint keep = (5 * 9)\nkeep + (2 * 3)\n(keep) = 23\n(keep + 7)\nint keep = 60\n(keep + 3)\nint old(): return (keep + 4)\n(keep + missing)\n(old())\nint callee(int n): return n + 1\nint caller(int n): return (callee(n) * 2)\n(caller(20))\nint callee(int n): return n + 3\n(caller(20))\n(1.5 + 2.5)\n(1e+ + 2)\n(caller(20))\nint* nil = 0\n(nil && nil[0])\n(!nil || *nil)\n(2 < 3 && caller(20) == 46)\n(false && missing)\n(caller(20) >= 46)\nbool yes = true\n(yes)\n(!yes)\nstruct AstPointer: int x\n(cast(AstPointer**, 0) + missing)\n(cast(AstPointer**, 0) == 0)\n(cast(AstPointer***, 0) + )\n(cast(AstPointer***, 0) == 0)\n:reset\n(8 * 9)\n:quit\n"
	for host in range(2):
		char* repl = c"bin/ast_retained_emit_repl"
		if (host): repl = c"bin/ast_retained_emit_repl64"
		process_result* parsed = emit_repl(repl, c"--streaming", script)
		process_result* retained = emit_repl(repl, c"--ast-emit-retained", script)
		assert_equal(0, retained.status)
		assert_equal(parsed.status, retained.status)
		assert_strings_equal(parsed.stdout_text, retained.stdout_text)
		assert_contains(retained.stdout_text, c"72")
		process_result_free(parsed)
		process_result_free(retained)


# S2.2b: if/while entries and bodies, and conditions that fail to parse
# (the entry is rolled back with its walk still open).
void test_retained_emission_repl_control():
	char* script = c"int n = 3\nif (n > 2): n = n + 1\nn\nwhile (n < 10): n = n + 2\nn\nif (n + ): n = 0\nn\nwhile (n + ): n = 0\nn\nint f(int x):\n\tif x > 5:\n\t\treturn 1\n\telif x > 2: return 2\n\twhile x < 0: x = x + 1\n\treturn 3\n\n(f(9) * 100 + f(3) * 10 + f(-4))\nint g(int x):\n\tif (x +): return 1\n\treturn 0\n\n(f(1))\n:quit\n"
	for host in range(2):
		char* repl = c"bin/ast_retained_emit_repl"
		if (host): repl = c"bin/ast_retained_emit_repl64"
		process_result* parsed = emit_repl(repl, c"--streaming", script)
		process_result* retained = emit_repl(repl, c"--ast-emit-retained", script)
		assert_equal(0, retained.status)
		assert_equal(parsed.status, retained.status)
		assert_strings_equal(parsed.stdout_text, retained.stdout_text)
		assert_contains(retained.stdout_text, c"123")
		process_result_free(parsed)
		process_result_free(retained)


# wbuild: binary=ast_retained_emit_test tag=tests dep=build dep=build_x64 data=tests/ast_expression_test.w data=tests/extern_data_test.w data=tests/float_abi_test.w data=tests/extern_alias_test.w data=tests/wasm_extern_test.w data=tests/script_fixture.w data=tests/ast_global_fixture.w data=tests/ast_gpu_statement_fixture.w data=tests/ast_deferred_fixture.w data=tests/ast_scope_fixture.w data=tests/for_test.w data=tests/for_container_test.w data=tests/switch_test.w data=tests/ast_guard_fixture.w data=tests/ast_declaration_fixture.w data=tests/infer_test.w data=tests/const_initializer_test.w data=tests/ast_raw_statement_fixture.w data=tests/goto_test.w data=tests/ast_expression_statement_fixture.w data=tests/ast_value_statement_fixture.w data=tests/ast_simple_statement_fixture.w data=tests/ast_expression_fixture.w data=tests/ast_typed_expression_fixture.w data=tests/ast_scalar_expression_fixture.w data=tests/ast_logic_expression_fixture.w data=tests/ast_remaining_expression_fixture.w data=tests/ast_mutation_expression_fixture.w data=tests/ast_text_expression_fixture.w data=tests/ast_print_expression_fixture.w data=tests/ast_buffer_expression_fixture.w data=tests/ast_comment_expression_fixture.w data=tests/ast_list_expression_fixture.w data=tests/ast_pointer_type_expression_fixture.w data=tests/ast_callback_expression_fixture.w data=tests/ast_default_expression_fixture.w data=tests/ast_allocation_expression_fixture.w data=tests/ast_multiline_expression_fixture.w data=tests/ast_metadata_expression_fixture.w data=tests/ast_record_expression_fixture.w data=tests/ast_map_expression_fixture.w data=tests/ast_parallel_expression_fixture.w data=tests/ast_increment_expression_fixture.w data=tests/ast_wide_call_expression_fixture.w data=tests/ast_template_expression_fixture.w data=tests/ast_generic_expression_fixture.w data=tests/ast_buffer_value_expression_fixture.w data=tests/ast_slice_expression_fixture.w data=tests/ast_container_literal_expression_fixture.w data=tests/ast_constructor_expression_fixture.w data=tests/ast_new_array_expression_fixture.w data=tests/ast_list_slice_expression_fixture.w data=tests/ast_list_method_expression_fixture.w data=tests/ast_void_call_expression_fixture.w data=tests/ast_composite_type_expression_fixture.w data=tests/ast_integer_intrinsic_expression_fixture.w data=tests/ast_map_method_expression_fixture.w data=tests/ast_generator_call_expression_fixture.w data=tests/ast_list_callback_expression_fixture.w data=tests/ast_map_default_expression_fixture.w data=tests/ast_inferred_generic_expression_fixture.w data=tests/ast_variadic_expression_fixture.w data=tests/varargs_test.w data=tests/ast_atomic_expression_fixture.w data=tests/atomic_host_test.w data=tests/ast_generic_type_expression_fixture.w data=tests/ast_method_expression_fixture.w data=tests/ast_operator_expression_fixture.w data=tests/operator_overload_test.w data=tests/ast_var_expression_fixture.w data=tests/dynamic_var_test.w data=tests/c_import_bitfield_fixture.w data=tests/x64_c_import_bitfield_test.w data=tests/c_import_bitfield_fixture.h data=tests/ast_prelude_expression_fixture.w data=tests/ast_prelude_input_fixture.w data=tests/prelude_test.w data=tests/ast_json_expression_fixture.w data=tests/json_codec_test.w data=tests/ast_protobuf_expression_fixture.w data=tests/protobuf_message_test.w data=tests/ast_utf8_expression_fixture.w data=tests/utf8_identifier_test.w data=tests/ast_large_literal_expression_fixture.w data=graphics/ui/font_data.w data=tests/ast_ndarray_expression_fixture.w data=tests/ndarray_index_test.w data=tests/ast_buffer_flow_expression_fixture.w data=tests/array_decay_test.w data=tests/matrix_linalg_test.w data=tests/ast_template_format_expression_fixture.w data=tests/template_format_test.w data=tests/template_format_float64_test.w data=tests/ast_qualified_expression_fixture.w data=tests/import_alias_type_test.w data=tests/import_test.w data=tests/ast_device_expression_fixture.w data=tests/gpu_ptx_emit.w data=tests/cuda_gpu.w data=tests/ast_gpu_qualified_expression_fixture.w data=tests/gpu_qualifier_ptx.w data=tests/gpu_qualifier_gpu.w data=tests/expression_nesting_clean_fixture.w data=tests/ternary_nesting_clean_fixture.w data=tests/gpu_qualifier_ok_fixture.w data=tests/ast_list_it_expression_fixture.w data=tests/list_it_test.w data=tests/golf_it_ints_test.w data=tests/golf_transpose_test.w data=tests/ast_bare_callback_expression_fixture.w data=libs/standard/distributed/raft_sweep_test.w data=tests/generics_test.w data=tests/ast_propagation_expression_fixture.w data=tests/ast_continuation_expression_fixture.w data=tests/lint_warn_fixture.w data=tests/lint_clean_fixture.w data=tests/bool_bitwise_warning_fixture.w data=tests/bool_bitwise_chain_fixture.w data=tests/bool_ops_warn_fixture.w data=structures/hash_table_test.w data=tests/default_args_missing_warning_fixture.w data=tests/list_builtin_warning_fixture.w data=tests/map_default_warning_fixture.w data=tests/warning_fixture.w data=tests/type_system_warning_fixture.w data=tests/ndarray_index_warning_fixture.w data=tests/atomic_host_operand_error_fixture.w data=tests/limb_builtin_warning_fixture.w data=tests/array_cast_warning_fixture.w data=tests/cross_line_call_warning_fixture.w data=tests/shell_commands_test.w data=tests/warning_clean_fixture.w data=tests/result_propagate_test.w data=tests/generator_return_free_test.w data=tests/feature_combo_test.w data=tests/ast_first_use_container_fixture.w data=tests/ast_map_integration_expression_fixture.w data=tests/ast_collection_snapshot_fixture.w data=tests/ast_control_header_fixture.w data=tests/ast_collection_snapshot_x64_fixture.w data=tests/ast_statement_expression_fixture.w data=tests/ast_integration_expression_fixture.w data=tests/ast_scalar_map_expression_fixture.w data=tests/ast_array_allocation_fixture.w data=tests/ast_migration_constructor_fixture.w data=tests/ast_map_default_fixture.w data=tests/ast_map_get_fixture.w data=tests/ast_formatted_template_fixture.w data=tests/ast_migration_generic_fixture.w data=tests/ast_return_statement_fixture.w data=tests/unsigned_compare_test.w data=tests/x64_unsigned_compare_test.w data=tests/ast_statement_walk_fixture.w data=tests/ast_declaration_walk_fixture.w data=tests/ast_loop_switch_walk_fixture.w data=tests/ast_control_walk_fixture.w data=tests/ast_gpu_walk_fixture.w
# wbuild: step="bin/wv2 repl.w -o bin/ast_retained_emit_repl"
# wbuild: step="bin/wv2 x64 repl.w -o bin/ast_retained_emit_repl64"
# wbuild: step="bin/ast_retained_emit_test"
