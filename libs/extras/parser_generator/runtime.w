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
	if (child == 0):
		return 1
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
