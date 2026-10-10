# S2.3: generic instantiation and deferred statements from the retained
# forest. Under --ast-emit-retained, generic struct types, instantiation
# signatures and inference shapes are built by walking retained type trees
# under the substitution, and function bodies and deferred statements are
# re-lexed from the retained source bytes instead of reopening and seeking
# the file (grammar/generic.w, grammar/defer.w, code_generator/
# retained_emit.w). Every source below must compile to the same exit
# status, stdout, stderr and image as the streaming compile (--streaming,
# the baseline since the AST front end became the default in P1.4), on the x86
# target on the 32-bit host and the x64 target on the 64-bit host; the
# fixture's binaries must pass, and --stats must show no instantiation
# source seek except for the documented fallback (a body or deferred
# statement that ends its file).
import lib.testing
import lib.file
import lib.process
import lib.str


char* generic_retained_path(char* suffix):
	string_builder* path = string_new()
	string_append(path, c"bin/ast_generic_retained_")
	string_append_int(path, getpid())
	string_append(path, suffix)
	char* result = strclone(path.data)
	string_free(path)
	return result


process_result* generic_retained_compile(char* compiler, char* arch, char* input, char* output, int retained, int required, int stats):
	char** args = strv_new(16)
	int i = 0
	strv_set(args, i, compiler)
	i = i + 1
	if (output == 0):
		strv_set(args, i, c"check")
		i = i + 1
	if (arch != 0):
		strv_set(args, i, arch)
		i = i + 1
	if (retained):
		strv_set(args, i, c"--ast-emit-retained")
		i = i + 1
	else if (required == 0):
		# The baseline is the streaming front end, which seeks the source.
		strv_set(args, i, c"--streaming")
		i = i + 1
	if (required):
		strv_set(args, i, c"--ast-required")
		i = i + 1
	if (stats):
		strv_set(args, i, c"--stats")
		i = i + 1
	strv_set(args, i, input)
	i = i + 1
	if (output != 0):
		strv_set(args, i, c"-o")
		strv_set(args, i + 1, output)
	process_result* result = process_run(compiler, args, 0, 0, 300000)
	free(cast(void*, args))
	assert1(result != 0)
	return result


# Whole-file comparison; a file missing on both sides is equal.
int generic_retained_same_file(char* first, char* second):
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


void generic_retained_run_passes(char* binary, int banner):
	char** args = strv_new(2)
	strv_set(args, 0, binary)
	process_result* run = process_run(binary, args, 0, 0, 120000)
	free(cast(void*, args))
	assert1(run != 0)
	assert_equal(0, run.status)
	if (banner): assert_contains(run.stdout_text, c"All tests passed!")
	else:
		assert_strings_equal(c"", run.stdout_text)
		assert_strings_equal(c"", run.stderr_text)
	process_result_free(run)


# --streaming and --ast-emit-retained agree on status, output and image, on
# both hosts; run_binary also runs both images (1: test-runner banner,
# 2: a silent fixture whose exit status asserts its runtime behavior).
void generic_retained_same(char* source, int run_binary):
	char* plain = generic_retained_path(c".plain")
	char* retained = generic_retained_path(c".retained")
	for host in range(2):
		char* compiler = c"bin/wv2"
		char* arch = 0
		if (host):
			compiler = c"bin/wv2_64"
			arch = c"x64"
		process_result* a = generic_retained_compile(compiler, arch, source, plain, 0, 0, 0)
		process_result* b = generic_retained_compile(compiler, arch, source, retained, 1, 0, 0)
		assert_equal(a.status, b.status)
		assert_strings_equal(a.stdout_text, b.stdout_text)
		assert_strings_equal(a.stderr_text, b.stderr_text)
		assert1(generic_retained_same_file(plain, retained))
		if (run_binary):
			assert_equal(0, a.status)
			generic_retained_run_passes(plain, run_binary == 1)
			generic_retained_run_passes(retained, run_binary == 1)
		process_result_free(a)
		process_result_free(b)
		unlink(plain)
		unlink(retained)
	free(plain)
	free(retained)


void generic_retained_same_text(char* text):
	char* path = generic_retained_path(c".w")
	assert1(file_write_text(path, text))
	generic_retained_same(path, 0)
	unlink(path)
	free(path)


int generic_retained_counter(char* stats, char* name):
	int at = 0
	while (stats[at]):
		if ((at == 0) || (stats[at - 1] == 10)):
			int j = 0
			while (name[j] && (stats[at + j] == name[j])): j = j + 1
			if (name[j] == 0): return atoi(stats + at + j)
		at = at + 1
	return -1


char* generic_retained_stats(char* compiler, char* source, int retained, int required):
	process_result* result = generic_retained_compile(compiler, 0, source, 0, retained, required, 1)
	assert_equal(0, result.status)
	char* text = strclone(result.stderr_text)
	process_result_free(result)
	return text


void test_fixture_matches_default_and_runs():
	generic_retained_same(c"tests/ast_generic_retained_fixture.w", 1)


void test_fixture_instantiates_without_source_seeks():
	for host in range(2):
		char* compiler = c"bin/wv2"
		if (host): compiler = c"bin/wv2_64"
		char* plain = generic_retained_stats(compiler, c"tests/ast_generic_retained_fixture.w", 0, 0)
		assert1(generic_retained_counter(plain, c"Generic instantiation source seeks: ") > 0)
		assert1(generic_retained_counter(plain, c"Deferred statement source seeks: ") > 0)
		free(plain)
		char* stats = generic_retained_stats(compiler, c"tests/ast_generic_retained_fixture.w", 1, 0)
		assert_equal(0, generic_retained_counter(stats, c"Generic instantiation source seeks: "))
		assert_equal(0, generic_retained_counter(stats, c"Deferred statement source seeks: "))
		assert1(generic_retained_counter(stats, c"Generic types from retained trees: ") > 0)
		assert1(generic_retained_counter(stats, c"Retained-source reparses: ") > 0)
		free(stats)


# The plan's gate: the compiler's own instantiations seek no source, in a
# check (which also instantiates every unused generic once) as in a compile.
void test_compiler_instantiates_without_source_seeks():
	char* stats = generic_retained_stats(c"bin/wv2", c"w.w", 1, 1)
	assert_equal(0, generic_retained_counter(stats, c"Generic instantiation source seeks: "))
	assert_equal(0, generic_retained_counter(stats, c"Deferred statement source seeks: "))
	assert1(generic_retained_counter(stats, c"Generic types from retained trees: ") > 0)
	assert_equal(0, generic_retained_counter(stats, c"Immediate statements: "))
	free(stats)
	char* output = generic_retained_path(c".wv3")
	process_result* result = generic_retained_compile(c"bin/wv2", 0, c"w.w", output, 1, 1, 1)
	assert_equal(0, result.status)
	assert_equal(0, generic_retained_counter(result.stderr_text, c"Generic instantiation source seeks: "))
	assert_equal(0, generic_retained_counter(result.stderr_text, c"Deferred statement source seeks: "))
	process_result_free(result)
	unlink(output)
	free(output)


# Shapes the walk declines are re-parsed, and their diagnostics are the
# re-parse's: unknown names, storage rules, arity, 64-bit types on x86,
# a slice of a generic struct's bare name, lexer warnings in a field list.
void test_declined_shapes_keep_their_diagnostics():
	generic_retained_same_text(c"struct box[T]:\n\tT value\n\tmissing other\n\nint main():\n\tbox[int] b\n\tb.value = 1\n\treturn 0\n")
	generic_retained_same_text(c"struct box[T]:\n\tT value\n        int spaced\n\nint main():\n\tbox[int] b\n\tbox[char] c\n\tb.value = 1\n\treturn 0\n")
	generic_retained_same_text(c"T pick[T](T a, missing b):\n\treturn a\n\nint main():\n\treturn pick[int](1, 2)\n")
	generic_retained_same_text(c"struct bag[T]:\n\tlist[T] items\n\nint main():\n\tbag[int[4]] b\n\treturn 0\n")
	generic_retained_same_text(c"struct m[T]:\n\tmap[T, int[4]] cells\n\nint main():\n\tm[int] v\n\treturn 0\n")
	generic_retained_same_text(c"struct pair[A, B]:\n\tA a\n\tB b\n\nstruct outer[T]:\n\tpair[T] p\n\nint main():\n\touter[int] o\n\treturn 0\n")
	generic_retained_same_text(c"struct wide[T]:\n\tT a\n\tfloat64 b\n\nint main():\n\twide[int] w\n\treturn 0\n")
	generic_retained_same_text(c"struct box[T]:\n\tT value\n\tbox[T][] kids\n\tbox[] bad\n\nint main():\n\tbox[int] b\n\treturn 0\n")
	generic_retained_same_text(c"struct p[T]:\n\tT\n\tx\n\nint main():\n\tp[int] v\n\tv.x = 1\n\treturn 0\n")
	generic_retained_same_text(c"struct box[T]:\n\tT value\n\nT get[T](box[T]* b):\n\treturn b.value\n\nint main():\n\tbox[int] b\n\tb.value = 4\n\treturn get(&b)\n")


# Diagnostics printed while a body or deferred statement is re-lexed from
# retained bytes keep their source context lines; definitions and defers
# that end their file are re-parsed from the file.
void test_relexed_bodies_and_defers_keep_their_diagnostics():
	generic_retained_same_text(c"T twice[T](T a):\n\tT b = a + undefined_name\n\treturn b\n\nint main():\n\treturn twice[int](2)\n")
	generic_retained_same_text(c"char narrow[T](T a):\n\tchar c = 300\n\treturn c\n\nint main():\n\treturn narrow[int](2) + narrow[char](1)\n")
	generic_retained_same_text(c"int hits\n\nvoid bump(char c):\n\thits = hits + 1\n\nint f(int x):\n\tdefer bump(300)\n\tif (x): return 1\n\treturn 0\n\nint main():\n\treturn f(0)\n")
	generic_retained_same_text(c"int hits\n\nvoid bump(char c):\n\thits = hits + 1\n\nint main():\n\tdefer bump(300)\n\treturn 0\n\n# trailing comment\n/* block\n   comment */\n")
	generic_retained_same_text(c"int main():\n\treturn narrow[int](2)\n\nchar narrow[T](T a):\n\tchar c = 300\n\treturn c\n")
	generic_retained_same_text(c"int hits\n\nvoid bump(char c):\n\thits = hits + 1\n\nint main():\n\tdefer bump(300)\n")
	generic_retained_same_text(c"int main():\n\treturn f[int](1)\n\nstruct box[T]:\n\tT value\n\nT f[T](T a):\n\tbox[T] b\n\tb.value = a\n\treturn b.value")
	generic_retained_same_text(c"T f[T](T a):\n\tbox[T] b\n\tb.value = a\n\treturn b.value\n\nint main():\n\treturn f[int](1)\n\nstruct box[T]:\n\tT value")


# A body or deferred statement that ends its file is still re-lexed from
# retained bytes, but over the file's own descriptor positioned at its end
# (its last expression's preflight may move getchar's window past what
# memory holds, and getchar then re-reads the prefix from the file).
void test_file_ending_spans_position_the_file_at_its_end():
	char* path = generic_retained_path(c"_last.w")
	assert1(file_write_text(path, c"int hits\n\nvoid bump():\n\thits = hits + 1\n\nint main():\n\treturn narrow[int](2)\n\nchar narrow[T](T a):\n\tdefer bump()\n\tchar c = 3\n\treturn c\n"))
	char* stats = generic_retained_stats(c"bin/wv2", path, 1, 0)
	assert_equal(0, generic_retained_counter(stats, c"Generic instantiation source seeks: "))
	assert_equal(0, generic_retained_counter(stats, c"Deferred statement source seeks: "))
	assert_equal(1, generic_retained_counter(stats, c"Retained-source reparses: "))
	assert_equal(1, generic_retained_counter(stats, c"Retained-source reparses positioned at the file's end: "))
	free(stats)
	unlink(path)
	free(path)

# wbuild: binary=ast_generic_retained_test tag=tests dep=build dep=build_x64 data=tests/ast_generic_retained_fixture.w data=tests/ast_generic_retained_helper.w data=tests/ast_deferred_fixture.w
# wbuild: step="bin/ast_generic_retained_test"


# A deferred call's names are rebound at each exit, including a name
# declared after registration and a later declaration that shadows it.
# The fixture contains only reusable calls: no source is parsed again.
void test_deferred_call_trees_bind_at_exits_without_reparsing():
	generic_retained_same(c"tests/ast_deferred_fixture.w", 2)
	for host in range(2):
		char* compiler = c"bin/wv2"
		if (host): compiler = c"bin/wv2_64"
		char* stats = generic_retained_stats(compiler, c"tests/ast_deferred_fixture.w", 1, 1)
		assert1(generic_retained_counter(stats, c"Deferred syntax trees captured: ") > 0)
		assert1(generic_retained_counter(stats, c"Deferred syntax tree emissions: ") > generic_retained_counter(stats, c"Deferred syntax trees captured: "))
		assert_equal(0, generic_retained_counter(stats, c"Deferred expression reparses: "))
		assert_equal(0, generic_retained_counter(stats, c"Retained-source reparses: "))
		free(stats)


void test_deferred_tree_fallback_is_decided_at_each_exit():
	# The first exit has an int local (eligible); the second shadows it
	# with a char (falls back). Binding cannot be cached across exits.
	generic_retained_same_text(c"int total\n\nvoid mark(int value):\n\ttotal = value\n\nvoid run(int early):\n\tint value = 2\n\tdefer mark(value)\n\tif (early): return\n\tchar value = 3\n\treturn\n\nint main():\n\trun(1)\n\tif (total != 2): return 1\n\trun(0)\n\treturn total - 3\n")
	# Failed eligibility after a valid argument must not commit its use
	# tracking or suppress the ordinary unknown-name diagnostic.
	generic_retained_same_text(c"void mark(int first, int second):\n\tpass\n\nint main():\n\tint value = 2\n\tdefer mark(value, missing)\n\treturn 0\n")
	generic_retained_same_text(c"void mark(int value):\n\tpass\n\nint main():\n\tdefer mark(2147483648)\n\treturn 0\n")
