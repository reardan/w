/*
Umbrella import for generated parser runtimes, plus the helpers generated
parsers call to keep one grammar term to one line.
*/
import libs.extras.parser_generator.token
import libs.extras.parser_generator.diagnostics
import libs.extras.parser_generator.token_stream
import libs.extras.parser_generator.lexer
import libs.extras.parser_generator.ast_node


# Attach a mandatory child; returns the new `failed` flag: 1 when the
# child did not parse (child == 0), else 0.
int pg_ast_add_required(pg_ast_node* node, pg_ast_node* child):
	if (child == 0): return 1
	pg_ast_add(node, child)
	return 0


# Attach an optional or repeated child, or rewind the stream to mark when
# it did not parse; returns whether the child was attached.
int pg_ast_add_or_rewind(pg_ast_node* node, pg_token_stream* stream, int mark, pg_ast_node* child):
	if (child == 0):
		pg_token_stream_rewind(stream, mark)
		return 0
	pg_ast_add(node, child)
	return 1


# Record a "syntax error" diagnostic at token (expected names what the
# parser wanted there); returns 0 so a streaming rule can return it.
int pg_syntax_error(pg_diagnostics* diagnostics, pg_token* token, char* expected):
	pg_diagnostics_add(diagnostics, token.filename, token.line, token.column, c"syntax error", expected, token.text)
	return 0


# Owns the stream, diagnostics, copied source and every AST allocation. A
# non-null root alone does not mean success: generated wrappers set success
# only after complete-input and diagnostic checks.
struct pg_parse_result:
	pg_ast_node* root
	pg_token_stream* stream
	pg_diagnostics* diagnostics
	char* source
	int length
	int success


pg_parse_result* pg_parse_result_new(pg_token_stream* stream, pg_diagnostics* diagnostics):
	pg_parse_result* result = new pg_parse_result()
	result.root = 0
	result.stream = stream
	result.diagnostics = diagnostics
	result.success = 0
	pg_token_stream_own_ast(stream)
	if (stream.provider != 0):
		result.length = stream.provider.length
		result.source = pg_substr(stream.provider.input, 0, result.length)
	else:
		result.source = pg_token_stream_source(stream)
		result.length = strlen(result.source)
	return result


void pg_parse_result_free(pg_parse_result* result):
	if (result == 0): return
	pg_diagnostics_free(result.diagnostics)
	pg_token_stream_free(result.stream)
	free(result.source)
	free(result)


int pg_token_stream_goal(pg_token_stream* stream):
	if (stream.provider == 0): return 0
	return stream.provider.goal
