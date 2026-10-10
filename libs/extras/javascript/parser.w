# wbuild: target=javascript_parser dep=grammars_parser_generator
# wbuild: step="bin/parser_generator_grammars libs/extras/grammars/javascript.pg -o bin/generated_javascript_parser.w"
# Generate bin/generated_javascript_parser.w with ./wbuild javascript_parser.
import bin.generated_javascript_parser
import libs.extras.javascript.validation
import libs.extras.javascript.bindings
import libs.extras.javascript.restrictions


pg_parse_result* js_parse(char* source, int length, char* filename, int module):
	pg_parse_result* result = javascript_parse_owned(source, length, filename)
	js_validate(result, module)
	js_validate_bindings(result, module)
	js_validate_restrictions(result, module)
	return result


pg_parse_result* js_parse_script(char* source, char* filename):
	return js_parse(source, strlen(source), filename, 0)


pg_parse_result* js_parse_module(char* source, char* filename):
	return js_parse(source, strlen(source), filename, 1)
