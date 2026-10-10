# wbuild: target=javascript_parser dep=grammars_parser_generator
# wbuild: step="bin/parser_generator_grammars libs/extras/grammars/javascript.pg -o bin/generated_javascript_parser.w"
# Generate bin/generated_javascript_parser.w with ./wbuild javascript_parser.
import bin.generated_javascript_parser
import libs.extras.javascript.validation
import libs.extras.javascript.bindings
import libs.extras.javascript.restrictions


struct js_parse_limits:
	int tokens
	int ast_nodes
	int checkpoints


js_parse_limits* js_parse_limits_new():
	js_parse_limits* limits = new js_parse_limits()
	limits.tokens = 1000000
	limits.ast_nodes = 1000000
	limits.checkpoints = 4096
	return limits


# Owns all parser storage on both success and failure. Limits count speculative
# work too and retain the generic runtime's sticky resource failure semantics.
pg_parse_result* js_parse_with_limits(char* source, int length, char* filename, int module, js_parse_limits* limits):
	int invalid = length < 0 || (source == 0 && length > 0)
	if (source == 0 || length < 0):
		source = c""
		length = 0
	if (filename == 0): filename = c"<JavaScript>"
	int own_limits = limits == 0
	if (own_limits): limits = js_parse_limits_new()
	if (limits.tokens <= 0 || limits.ast_nodes <= 0 || limits.checkpoints <= 0): invalid = 1
	pg_diagnostics* diagnostics = pg_diagnostics_new()
	pg_token_stream* stream = pg_token_stream_from_provider(javascript_provider_new(source, length, filename), javascript_next, diagnostics)
	stream.token_limit = limits.tokens
	stream.ast_limit = limits.ast_nodes
	stream.checkpoint_limit = limits.checkpoints
	pg_token_stream_own_ast(stream)
	pg_parse_result* result = pg_parse_result_new(stream, diagnostics)
	if (own_limits): free(limits)
	if (invalid):
		pg_diagnostics_add(diagnostics, filename, 1, 1, c"invalid JavaScript parser input or limits", c"valid buffer and positive limits", c"")
		return result
	result.root = javascript_parse_program(stream, diagnostics)
	if (result.root == 0 || pg_token_stream_done(stream) == 0): pg_syntax_error(diagnostics, pg_token_stream_furthest(stream), c"program")
	pg_token_stream_report_resource(stream)
	result.success = result.root != 0 && diagnostics.items.length == 0 && stream.resource_failed == 0
	js_validate(result, module)
	js_validate_bindings(result, module)
	js_validate_restrictions(result, module)
	return result


pg_parse_result* js_parse(char* source, int length, char* filename, int module):
	js_parse_limits* limits = js_parse_limits_new()
	pg_parse_result* result = js_parse_with_limits(source, length, filename, module, limits)
	free(limits)
	return result


pg_parse_result* js_parse_script(char* source, char* filename):
	return js_parse(source, strlen(source), filename, 0)


pg_parse_result* js_parse_module(char* source, char* filename):
	return js_parse(source, strlen(source), filename, 1)
