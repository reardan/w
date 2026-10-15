# wbuild: binary=ast_source_window_tail_test tag=tests dep=build
# wbuild: step="bin/ast_source_window_tail_test"
# Regression: a retained source version must not keep a hole where a
# diagnostic's context line re-aligned getchar's window.
#
# The retained version records the source window by window (P1.2b,
# compiler/retained_ast.w). An expression preflight that runs into the
# window's end (grammar/ast_expression.w, ast_expression_refill) keeps the
# expression's prefix and reads more behind it, so afterwards the window
# ends k bytes short of the next GETCHAR_BUF_CAPACITY multiple, and so does
# the recorded copy. A warning's context line (compiler/tokenizer.w,
# diag_context_collect) then re-reads the file from offset 0 through
# getchar, which leaves the window aligned again and ending k bytes past
# what was recorded. When the next expression preflight reached that
# window's end before the lexer reached the recorded end, its read was
# recorded at the window's end and the k bytes between were zero-filled.
# A rotated while loop whose body held that expression then seeked back to
# its condition, re-read the hole from the file and stopped the compile
# with "source changed during retained AST traversal" although nothing
# had changed (wtools/index/w_index_core.w in w-private hit exactly this).
import lib.testing
import lib.file
import lib.process


const int tail_short = 20


char* tail_path(char* suffix):
	string_builder* name = string_from(c"bin/ast_source_window_tail_")
	string_append_int(name, getpid())
	string_append(name, suffix)
	char* path = strclone(name.data)
	string_free(name)
	return path


# Comment lines (and blank lines for a remainder too short for one) up to
# exactly offset target.
void tail_pad(string_builder* source, int target, char* indent):
	int minimum = strlen(indent) + 2
	while (source.length < target):
		int rest = target - source.length
		int line = 64
		if (rest < line + minimum): line = rest
		if (line < minimum):
			string_append_char(source, 10)
		else:
			string_append(source, indent)
			string_append_char(source, '#')
			for i in range(line - minimum): string_append_char(source, 'x')
			string_append_char(source, 10)
	assert_equal(target, source.length)


# terms copies of term joined by " + ".
void tail_sum(string_builder* source, char* term, int terms):
	for i in range(terms):
		if (i > 0): string_append(source, c" + ")
		string_append(source, term)


char* tail_source():
	int window = GETCHAR_BUF_CAPACITY
	string_builder* source = string_from(c"int f(int n):\n\treturn n\n\n\n")
	# 1. An expression that straddles the first window's end: its preflight
	# keeps tail_short bytes and refills, so the window and the recorded
	# copy now end tail_short bytes before 2 * window.
	char* head = c"int g(int a):\n\tint x = "
	tail_pad(source, window - tail_short - strlen(head), c"")
	string_append(source, head)
	assert_equal(window - tail_short, source.length)
	tail_sum(source, c"a", 60)
	string_append(source, c"\n\treturn x\n\n\n")
	# 2. A warning inside the second window: printing its context line
	# re-reads the file from 0 and leaves the window [window, 2 * window).
	string_append(source, c"int h(int a, int b):\n\tif ((a == 1) | (b == 2)):\n\t\treturn 1\n\treturn 0\n\n\n")
	string_append(source, c"int loop(int n):\n\tint i = 0\n\tint total = 0\n\twhile (i < f(n)):\n")
	int condition = source.length
	assert1(condition > window)
	# 3. A rotated loop's body holding an expression that starts before the
	# recorded end and straddles the realigned window's end.
	char* body = c"\t\ttotal = total + "
	int start = 2 * window - tail_short - 40
	tail_pad(source, start - strlen(body), c"\t\t")
	string_append(source, body)
	assert1(source.length < 2 * window - tail_short)
	tail_sum(source, c"i", 60)
	assert1(source.length > 2 * window)
	string_append(source, c"\n\t\ti = i + 1\n\treturn total\n\n\n")
	string_append(source, c"int main():\n\tif (h(1, 0) != 1): return 1\n\tif (loop(3) != 180): return 2\n\treturn g(1) - 60\n")
	char* text = strclone(source.data)
	string_free(source)
	return text


void tail_compile_and_run(char* path, char* arch):
	char* output = tail_path(c".out")
	char** args = strv_new(6)
	strv_set(args, 0, c"bin/wv2")
	int n = 1
	if (arch != 0):
		strv_set(args, n, arch)
		n = n + 1
	strv_set(args, n, path)
	strv_set(args, n + 1, c"-o")
	strv_set(args, n + 2, output)
	process_result* result = process_run(c"bin/wv2", args, 0, 0, 60000)
	free(cast(void*, args))
	assert1(result != 0)
	if (result.status != 0): print_error(result.stderr_text)
	assert_equal(0, result.status)
	assert_lacks(result.stderr_text, c"source changed")
	# The warning (and so its context line) is what realigns the window.
	assert_contains(result.stderr_text, c"does not short-circuit")
	process_result_free(result)
	char** run_args = strv_new(1)
	strv_set(run_args, 0, output)
	process_result* run = process_run(output, run_args, 0, 0, 30000)
	free(cast(void*, run_args))
	assert1(run != 0)
	assert_equal(0, run.status)
	process_result_free(run)
	unlink(output)
	free(output)


void test_context_line_realigned_window_is_recorded_before_refill():
	char* path = tail_path(c".w")
	char* text = tail_source()
	assert1(file_write_text(path, text))
	tail_compile_and_run(path, 0)
	tail_compile_and_run(path, c"x64")
	unlink(path)
	free(path)
	free(text)
