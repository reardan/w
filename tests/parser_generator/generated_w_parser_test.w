import lib.testing
import libs.extras.parser_generator.runtime
import libs.extras.parser_generator.source_writer
import bin.generated_w_parser


int parsed_manifest_count


void assert_w_parse_has_errors(char* source, char* filename):
	pg_diagnostics* diagnostics = pg_diagnostics_new()
	pg_ast_node* root = wlang_parse(source, filename, diagnostics)
	assert1((root == 0) | (pg_diagnostics_count(diagnostics) > 0))
	assert1(pg_diagnostics_count(diagnostics) > 0)


void assert_w_parse_text(char* source, char* filename):
	pg_diagnostics* diagnostics = pg_diagnostics_new()
	pg_ast_node* root = wlang_parse(source, filename, diagnostics)
	if ((root == 0) | (pg_diagnostics_count(diagnostics) != 0)):
		pg_diagnostics_print(diagnostics)
	assert1(root != 0)
	assert_equal(0, pg_diagnostics_count(diagnostics))
	assert_equal(wlang_ast_program(), root.kind)


void assert_w_parse_file(char* path):
	char* source = pg_read_file_text(path)
	assert1(source != 0)
	assert_w_parse_text(source, path)
	parsed_manifest_count = parsed_manifest_count + 1


void parse_manifest_path(string_builder* path):
	if (path.length == 0):
		return
	assert_w_parse_file(path.data)


void assert_w_parse_manifest(char* manifest_path):
	int file = open(manifest_path, 0, 0)
	asserts(c"could not open W parser manifest", file >= 0)
	string_builder* path = string_new()
	int c = getchar(file)
	while (c != -1):
		if (c == 10):
			parse_manifest_path(path)
			string_clear(path)
		else:
			string_append_char(path, c)
		c = getchar(file)
	parse_manifest_path(path)
	close(file)


void test_w_lexer_keywords_identifiers_comments_and_tabs():
	pg_diagnostics* diagnostics = pg_diagnostics_new()
	pg_token_stream* stream = wlang_lex(c"# skip\x0aimport integer int inline asm\x0a\x09/* block */return\x0a", c"lexer.w", diagnostics)
	assert_equal(0, pg_diagnostics_count(diagnostics))
	assert_equal(wlang_token_NEWLINE(), pg_token_stream_la(stream, 1).kind)
	assert_equal(wlang_token_KW_IMPORT(), pg_token_stream_la(stream, 2).kind)
	assert_equal(wlang_token_IDENT(), pg_token_stream_la(stream, 3).kind)
	assert_strings_equal(c"integer", pg_token_stream_la(stream, 3).text)
	assert_equal(wlang_token_KW_INT(), pg_token_stream_la(stream, 4).kind)
	assert_equal(wlang_token_KW_INLINE(), pg_token_stream_la(stream, 5).kind)
	assert_equal(wlang_token_KW_ASM(), pg_token_stream_la(stream, 6).kind)
	assert_equal(wlang_token_NEWLINE(), pg_token_stream_la(stream, 7).kind)
	assert_equal(wlang_token_TAB(), pg_token_stream_la(stream, 8).kind)
	assert_equal(wlang_token_KW_RETURN(), pg_token_stream_la(stream, 9).kind)
	assert_equal(wlang_token_NEWLINE(), pg_token_stream_la(stream, 10).kind)
	assert_equal(wlang_token_EOF(), pg_token_stream_la(stream, 11).kind)


void test_w_lexer_literals_and_multi_char_operators():
	pg_diagnostics* diagnostics = pg_diagnostics_new()
	pg_token_stream* stream = wlang_lex(c"s\x22hi\\x0a\x22 c\x22bytes\x22 '\x5cn' 0x1f 3.25 <= >= == != << >> -> && ||", c"lexer.w", diagnostics)
	assert_equal(0, pg_diagnostics_count(diagnostics))
	assert_equal(wlang_token_STRING(), pg_token_stream_la(stream, 1).kind)
	assert_equal(wlang_token_STRING(), pg_token_stream_la(stream, 2).kind)
	assert_equal(wlang_token_CHAR_LITERAL(), pg_token_stream_la(stream, 3).kind)
	assert_equal(wlang_token_NUMBER(), pg_token_stream_la(stream, 4).kind)
	assert_equal(wlang_token_NUMBER(), pg_token_stream_la(stream, 5).kind)
	assert_equal(wlang_token_LT_EQ(), pg_token_stream_la(stream, 6).kind)
	assert_equal(wlang_token_GT_EQ(), pg_token_stream_la(stream, 7).kind)
	assert_equal(wlang_token_EQ_EQ(), pg_token_stream_la(stream, 8).kind)
	assert_equal(wlang_token_BANG_EQ(), pg_token_stream_la(stream, 9).kind)
	assert_equal(wlang_token_SHIFT_LEFT(), pg_token_stream_la(stream, 10).kind)
	assert_equal(wlang_token_SHIFT_RIGHT(), pg_token_stream_la(stream, 11).kind)
	assert_equal(wlang_token_ARROW(), pg_token_stream_la(stream, 12).kind)
	assert_equal(wlang_token_AND_AND(), pg_token_stream_la(stream, 13).kind)
	assert_equal(wlang_token_OR_OR(), pg_token_stream_la(stream, 14).kind)


void test_parse_w_import_struct_and_function():
	assert_w_parse_text(c"import lib.testing\x0a\x0astruct point:\x0a\x09int x\x0a\x09int y\x0a\x0aint add(int a, int b):\x0a\x09return a + b\x0a", c"inline.w")


void test_parse_w_control_flow_and_calls():
	assert_w_parse_text(c"int main(int argc, int argv):\x0a\x09if (argc >= 2):\x0a\x09\x09return syscall(1, 0, 0)\x0a\x09else:\x0a\x09\x09pass\x0a\x09for int i in range(0, 3):\x0a\x09\x09debugger\x0a\x09return 0\x0a", c"control.w")


void test_parse_w_literals_arrays_and_new():
	assert_w_parse_text(c"struct point:\x0a\x09int x\x0a\x0avoid test_values():\x0a\x09int values[4]\x0a\x09values[0] = 42\x0a\x09char* s = \x22hello\\x0a\x22\x0a\x09point* p = new point(1)\x0a\x09p.x = values[0]\x0a", c"values.w")


void test_parse_w_map_and_set_forms():
	assert_w_parse_text(c"void test_maps():\x0a\x09map[char*, int] m = map[char*, int]{\x22red\x22: 3, \x22blue\x22: 4}\x0a\x09m[\x22red\x22] = m[\x22red\x22] + 1\x0a\x09if (\x22red\x22 in m):\x0a\x09\x09pass\x0a\x09set[int] s = set[int]{1, 2, 3}\x0a\x09for int x in s:\x0a\x09\x09pass\x0a", c"maps_sets.w")


void test_parse_w_type_aliases_function_types_and_casts():
	assert_w_parse_text(c"type size_t = uint\x0atype binary_op = fn(int, int) -> int\x0a\x0abool is_ready():\x0a\x09return true\x0a\x0avoid test_casts():\x0a\x09size_t n = 42\x0a\x09int* p = cast(int*, malloc(4))\x0a\x09*p = cast(int, n)\x0a", c"types.w")


void test_parse_w_aggregate_extern_and_c_lib_forms():
	assert_w_parse_text(c"c_lib \x22libc.so.6\x22\x0aextern int puts(char* s)\x0a\x0aunion value:\x0a\x09int i\x0a\x09char* s\x0a\x0aenum color:\x0a\x09red\x0a\x09green = 4\x0a\x09blue\x0a\x0astruct holder:\x0a\x09value v\x0a\x09color c\x0a", c"aggregates.w")


void test_parse_w_inline_asm_and_raw_asm_forms():
	assert_w_parse_text(c"inline asm int \x22this + integer\x22(int right):\x0a\x09mov eax, [this]\x0a\x09add eax, [right]\x0a\x0aasm push(this):\x0a\x09mov eax, esp\x0a\x09ret\x0a\x0avoid test_raw():\x0a\x09raw_asm(\x22\\x90\\x90\x22)\x0a", c"asm.w")


void test_parse_w_multiline_expressions_braces_and_inline_blocks():
	assert_w_parse_text(c"int sample(int a, int b) {\x0a\x09if (a == b) {\x0a\x09}\x0a\x09else if ((a > 0) &&\x0a\x09\x09\x09(b > 0)): a = b\x0a\x09return a\x0a}\x0a", c"braces.w")


void test_parse_w_legacy_range_forms():
	assert_w_parse_text(c"void ranges():\x0a\x09for int i in range 10:\x0a\x09\x09pass\x0a\x09for int j in range 1, 10:\x0a\x09\x09continue\x0a\x09for int k in range(0, 10, 2):\x0a\x09\x09break\x0a", c"ranges.w")


void test_parse_w_reports_syntax_and_lexer_errors():
	assert_w_parse_has_errors(c"int main(:\x0a", c"bad_syntax.w")
	assert_w_parse_has_errors(c"int main():\x0a\x09@\x0a", c"bad_lexer.w")


void test_parse_real_w_entrypoint():
	assert_w_parse_file(c"w.w")


void test_parse_real_hello_fixture():
	assert_w_parse_file(c"tests/hello.w")


void test_parse_all_tracked_w_files():
	parsed_manifest_count = 0
	assert_w_parse_manifest(c"bin/parser_generator_w_files.txt")
	assert1(parsed_manifest_count > 100)
