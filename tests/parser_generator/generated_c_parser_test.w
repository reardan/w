import lib.testing
import libs.extras.parser_generator.runtime
import bin.generated_c_parser


void assert_c_parse_has_errors(char* source, char* filename):
	pg_diagnostics* diagnostics = pg_diagnostics_new()
	pg_ast_node* root = clang_parse(source, filename, diagnostics)
	assert1((root == 0) | (pg_diagnostics_count(diagnostics) > 0))
	assert1(pg_diagnostics_count(diagnostics) > 0)


pg_ast_node* assert_c_parse_text(char* source, char* filename):
	pg_diagnostics* diagnostics = pg_diagnostics_new()
	pg_ast_node* root = clang_parse(source, filename, diagnostics)
	if ((root == 0) | (pg_diagnostics_count(diagnostics) != 0)):
		pg_diagnostics_print(diagnostics)
	assert1(root != 0)
	assert_equal(0, pg_diagnostics_count(diagnostics))
	assert_equal(clang_ast_translation_unit(), root.kind)
	return root


void test_c_lexer_skips_comments_preprocessor_and_whitespace():
	pg_diagnostics* diagnostics = pg_diagnostics_new()
	pg_token_stream* stream = clang_lex("#define COUNT 4\x0aextern int puts(const char *s); // skip\x0a", "header.h", diagnostics)
	assert_equal(0, pg_diagnostics_count(diagnostics))
	assert_equal(clang_token_KW_EXTERN(), pg_token_stream_la(stream, 1).kind)
	assert_equal(clang_token_KW_INT(), pg_token_stream_la(stream, 2).kind)
	assert_equal(clang_token_IDENT(), pg_token_stream_la(stream, 3).kind)
	assert_strings_equal("puts", pg_token_stream_la(stream, 3).text)
	assert_equal(clang_token_LPAREN(), pg_token_stream_la(stream, 4).kind)
	assert_equal(clang_token_KW_CONST(), pg_token_stream_la(stream, 5).kind)
	assert_equal(clang_token_KW_CHAR(), pg_token_stream_la(stream, 6).kind)
	assert_equal(clang_token_STAR(), pg_token_stream_la(stream, 7).kind)
	assert_equal(clang_token_IDENT(), pg_token_stream_la(stream, 8).kind)
	assert_equal(clang_token_RPAREN(), pg_token_stream_la(stream, 9).kind)
	assert_equal(clang_token_SEMI(), pg_token_stream_la(stream, 10).kind)
	assert_equal(clang_token_EOF(), pg_token_stream_la(stream, 11).kind)


void test_c_lexer_literals_and_multi_char_operators():
	pg_diagnostics* diagnostics = pg_diagnostics_new()
	pg_token_stream* stream = clang_lex("u8\x22ok\x22 L'\\x41' 0x10UL ... -> ++ += <<= && ||", "tokens.h", diagnostics)
	assert_equal(0, pg_diagnostics_count(diagnostics))
	assert_equal(clang_token_STRING(), pg_token_stream_la(stream, 1).kind)
	assert_equal(clang_token_CHAR_LITERAL(), pg_token_stream_la(stream, 2).kind)
	assert_equal(clang_token_NUMBER(), pg_token_stream_la(stream, 3).kind)
	assert_equal(clang_token_ELLIPSIS(), pg_token_stream_la(stream, 4).kind)
	assert_equal(clang_token_ARROW(), pg_token_stream_la(stream, 5).kind)
	assert_equal(clang_token_PLUS_PLUS(), pg_token_stream_la(stream, 6).kind)
	assert_equal(clang_token_PLUS_ASSIGN(), pg_token_stream_la(stream, 7).kind)
	assert_equal(clang_token_SHIFT_LEFT_ASSIGN(), pg_token_stream_la(stream, 8).kind)
	assert_equal(clang_token_AND_AND(), pg_token_stream_la(stream, 9).kind)
	assert_equal(clang_token_OR_OR(), pg_token_stream_la(stream, 10).kind)


void test_parse_c_function_prototypes_and_typedefs():
	assert_c_parse_text("extern int puts(const char *s);\x0atypedef unsigned long size_t;\x0astatic inline int add(int a, int b) { return a + b; }\x0a", "ffi.h")


void test_parse_c_typedef_names_markers_and_annotations():
	assert_c_parse_text("__BEGIN_DECLS\x0atypedef unsigned long size_t;\x0aextern int remove(const char *__filename) __THROW __nonnull ((1));\x0aextern void *malloc(size_t size) __attribute__ ((__malloc__)) __wur;\x0a__END_DECLS\x0a", "libc_annotations.h")


void test_parse_c_skips_odd_control_characters():
	assert_c_parse_text("extern int close(int fd);\x01\x0a", "control.h")


void test_parse_c_struct_union_and_enum_declarations():
	assert_c_parse_text("typedef struct point { int x; int y; } point;\x0aunion value { int i; char *s; };\x0aenum color { red, green = 4, blue };\x0a", "aggregates.h")


void test_parse_c_arrays_function_pointers_and_variadic_params():
	assert_c_parse_text("typedef int (*callback)(int code, const char *message);\x0aextern int printf(const char *fmt, ...);\x0aextern char names[4][8];\x0a", "declarators.h")


void test_parse_c_initializers_and_designators():
	assert_c_parse_text("static int values[3] = { 1, 2, 3 };\x0astruct point origin = { .x = 0, .y = 0 };\x0a", "initializers.h")


void test_parse_c_reports_syntax_and_lexer_errors():
	assert_c_parse_has_errors("extern int puts(const char *s)\x0a", "missing_semi.h")
	assert_c_parse_has_errors("extern int @bad;\x0a", "bad_token.h")
