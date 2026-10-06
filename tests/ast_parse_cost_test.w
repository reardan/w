# P1.1 (AST parse cost): the AST probe binds node slabs instead of stack
# arenas, records each token's lexer state while it parses, and replays
# literal/diagnostic events from those records instead of lexing every
# accepted root twice. These cases stress the shapes that changed: deep
# root nesting (slab reuse), wide roots (node column growth), events on
# a root's final token (decoded in place before the next real token),
# template roots (still replayed by lexing) and the --stats counters.
# Images and diagnostics must match the streaming compiler on both hosts.
import lib.testing
import lib.file
import lib.process


char* parse_cost_path(char* suffix):
	string_builder* path = string_new()
	string_append(path, c"bin/ast_parse_cost_")
	string_append_int(path, getpid())
	string_append(path, suffix)
	char* result = strclone(path.data)
	string_free(path)
	return result


process_result* parse_cost_compile(char* compiler, char* arch, char* input, char* output, int required, int checking, int stats):
	char** args = strv_new(16)
	int i = 0
	strv_set(args, i, compiler)
	i = i + 1
	if (checking):
		strv_set(args, i, c"check")
		strv_set(args, i + 1, c"--json")
		strv_set(args, i + 2, c"--lint")
		i = i + 3
	if (arch != 0):
		strv_set(args, i, arch)
		i = i + 1
	strv_set(args, i, c"--quiet")
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
	process_result* result = process_run(compiler, args, 0, 0, 120000)
	free(cast(void*, args))
	assert1(result != 0)
	return result


void parse_cost_same_file(char* first, char* second):
	char* a = file_read_text(first)
	char* b = file_read_text(second)
	assert1((a != 0) && (b != 0))
	assert_strings_equal(a, b)
	free(a)
	free(b)


# Streaming and required-AST compiles agree on status, diagnostics and,
# when they link, the image, on both hosts and both target widths.
void parse_cost_same(char* source, int checking):
	char* path = parse_cost_path(c".w")
	char* streaming = parse_cost_path(c".streaming")
	char* required = parse_cost_path(c".required")
	assert1(file_write_text(path, source))
	for host in range(2):
		char* compiler = c"bin/wv2"
		if (host): compiler = c"bin/wv2_64"
		for width in range(2):
			char* arch = 0
			if (width): arch = c"x64"
			char* out_a = streaming
			char* out_b = required
			if (checking):
				out_a = 0
				out_b = 0
			process_result* old = parse_cost_compile(compiler, arch, path, out_a, 0, checking, 0)
			process_result* ast = parse_cost_compile(compiler, arch, path, out_b, 1, checking, 0)
			assert_equal(old.status, ast.status)
			assert_strings_equal(old.stdout_text, ast.stdout_text)
			assert_strings_equal(old.stderr_text, ast.stderr_text)
			if ((checking == 0) && (old.status == 0)): parse_cost_same_file(streaming, required)
			process_result_free(old)
			process_result_free(ast)
			unlink(streaming)
			unlink(required)
	unlink(path)
	free(path)
	free(streaming)
	free(required)


char* parse_cost_stats(char* source):
	char* path = parse_cost_path(c"_stats.w")
	assert1(file_write_text(path, source))
	process_result* result = parse_cost_compile(c"bin/wv2", 0, path, 0, 1, 1, 1)
	assert_equal(0, result.status)
	char* text = strclone(result.stderr_text)
	process_result_free(result)
	unlink(path)
	free(path)
	return text


int parse_cost_counter(char* stats, char* name):
	int at = 0
	while (stats[at]):
		if ((at == 0) || (stats[at - 1] == 10)):
			int j = 0
			while (name[j] && (stats[at + j] == name[j])): j = j + 1
			if (name[j] == 0): return atoi(stats + at + j)
		at = at + 1
	return -1


# 300 nested else-if roots: every level binds a slab while the enclosing
# conditions' frames are still live, then the chain unwinds.
void test_deep_root_nesting_matches_streaming():
	string_builder* source = string_new()
	string_append(source, c"int pick(int x):\n")
	for i in range(300):
		if (i): string_append(source, c"\telse if (x == ")
		else: string_append(source, c"\tif (x == ")
		string_append_int(source, i)
		string_append(source, c"): return ")
		string_append_int(source, i * 3 + 1)
		string_append(source, c"\n")
	string_append(source, c"\treturn -1\n\n\nint main():\n\tint total = 0\n\tfor i in range(310): total = total + pick(i)\n\treturn total & 127\n")
	parse_cost_same(source.data, 0)
	string_free(source)


# Roots far beyond the slab's initial 64 nodes grow its columns in place.
void test_wide_roots_grow_node_columns():
	string_builder* source = string_new()
	string_append(source, c"int f(int a, int b): return a - b\n\n\nint main():\n\tint x = 3\n\tint total = 0")
	for i in range(400):
		string_append(source, c" + f(x, ")
		string_append_int(source, i)
		string_append(source, c") * (x ^ ")
		string_append_int(source, i & 7)
		string_append(source, c")")
	string_append(source, c"\n\tchar* text = c\"a\" ")
	string_append(source, c"\n\treturn (total + text[0]) & 127\n")
	parse_cost_same(source.data, 0)
	string_free(source)


# Events on a root's last token decode that token in place; the next real
# token's whitespace diagnostic still reports the decoded spelling, as
# lexing the root again did. Bit-31 casts and template roots also keep
# their notes and order.
void test_final_token_events_keep_diagnostics():
	parse_cost_same(c"int main():\n\tchar* text = c\"decoded\\n\"\n    return 0\n", 1)
	parse_cost_same(c"int main():\n\tint x = 'q'\n    return x\n", 1)
	parse_cost_same(c"int main():\n\tint x = 0xffffffff\n\tint y = cast(int, 0x80000000) + x\n\treturn y\n", 1)
	parse_cost_same(c"import lib.lib\nint main():\n\tint n = 4\n\tchar* t = f\"n={n}\"\n\tprintln(t)\n\treturn 0\n", 1)
	parse_cost_same(c"int main():\n\tchar* a = c\"x\"\n\tchar* b = c\"\\q\"\n\treturn a[0] + b[0]\n", 1)


void test_stats_report_parse_cost_counters():
	char* stats = parse_cost_stats(c"import lib.lib\nint main():\n\tint n = 4\n\tchar* t = f\"n={n}\"\n\tprintln(t)\n\treturn n + 1\n")
	assert1(parse_cost_counter(stats, c"AST preflight bytes: ") > 0)
	assert1(parse_cost_counter(stats, c"AST tokenizer snapshots: ") > 0)
	assert1(parse_cost_counter(stats, c"AST tokens replayed: ") > 0)
	assert1(parse_cost_counter(stats, c"AST relexed roots: ") >= 1)
	assert1(parse_cost_counter(stats, c"AST node slabs: ") >= 1)
	assert_equal(0, parse_cost_counter(stats, c"Streaming expression roots: "))
	free(stats)

# wbuild: binary=ast_parse_cost_test tag=tests dep=build_x64
# wbuild: step="bin/ast_parse_cost_test"
