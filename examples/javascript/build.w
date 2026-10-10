# Construct a semantic JavaScript AST, print it, and validate the emitted
# module with the generated parser before writing it to stdout.
# wbuild: target=javascript_build_example tag=tests dep=javascript_parser
# wbuild: step="bin/wv2 examples/javascript/build.w -o bin/javascript_build_example"
# wbuild: step="bin/javascript_build_example" expect_stdout="export function greet(name)"
import libs.extras.javascript.ast
import libs.extras.javascript.printer
import libs.extras.javascript.parser
import libs.extras.javascript.lower


int main():
	js_node* program = js_node_new(c"program", c"")
	js_node* exported = js_node_new(c"export", c"")
	js_node* function = js_node_new(c"function", c"greet")
	js_node* parameters = js_node_new(c"parameters", c"")
	js_node_add(parameters, js_identifier(c"name"))
	js_node* body = js_node_new(c"block", c"")
	js_node* returned = js_node_new(c"return", c"")
	js_node_add(returned, js_binary(c"+", js_string(c"Hello, "), js_identifier(c"name")))
	js_node_add(body, returned)
	js_node_add(function, parameters)
	js_node_add(function, body)
	js_node_add(exported, function)
	js_node_add(program, exported)
	pg_diagnostics* diagnostics = pg_diagnostics_new()
	char* source = js_print(program, diagnostics)
	int status = 0
	if (source == 0):
		pg_diagnostics_print(diagnostics)
		status = 1
	else:
		pg_parse_result* parsed = js_parse_module(source, c"built.js")
		js_node* roundtrip = js_lower(parsed)
		if (roundtrip == 0 || js_node_equal(program, roundtrip) == 0):
			pg_diagnostics_print(parsed.diagnostics)
			println2(c"constructed AST did not round-trip")
			status = 1
		else: print(source)
		js_node_free(roundtrip)
		pg_parse_result_free(parsed)
		free(source)
	pg_diagnostics_free(diagnostics)
	js_node_free(program)
	return status
