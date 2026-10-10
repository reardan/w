# wbuild: target=javascript_inspect dep=javascript_parser
# wbuild: step="bin/wv2 examples/javascript/inspect.w -o bin/javascript_inspect"
# wbuild: target=javascript_compatibility dep=javascript_inspect dep=javascript_build_example dep=javascript_transform
# wbuild: step="python3 tools/javascript_compatibility.py"
# Inspect declarations or validate a JavaScript file with --check.
import lib.args
import lib.stream
import libs.extras.javascript.parser


void js_inspect_declarations(pg_ast_node* node):
	if (node == 0): return
	if (js_cst_is(node, c"function_decl") || js_cst_is(node, c"class_decl")):
		pg_ast_node* name = js_cst_child(node, c"binding_identifier")
		if (name != 0):
			print(node.name)
			print(c" ")
			print(name.first_token.text)
			print(c" at ")
			print(itoa(name.first_token.line))
			print(c":")
			println(itoa(name.first_token.column))
	if (js_cst_is(node, c"import_statement") || js_cst_is(node, c"export_from") || js_cst_is(node, c"export_all")):
		pg_ast_node* source = js_cst_child(node, c"STRING")
		if (source != 0):
			print(node.name)
			print(c" ")
			println(source.text)
	for i in range(node.children.length): js_inspect_declarations(node.children[i])


int main(int argc, int argv):
	args_init(argc, argv)
	args_declare_bool(c"module")
	args_declare_bool(c"check")
	if (args_positional_count() != 1):
		println2(c"usage: javascript_inspect [--module] [--check] file.js")
		return 2
	char* path = args_positional(0)
	wstream* input = stream_open_read(path)
	if (input == 0):
		println2(c"javascript_inspect: cannot open input")
		return 2
	string_builder* source = string_new()
	io_result read_result
	int status = stream_read_all_checked(input, source, &read_result)
	stream_close(input)
	if (status != IO_OK):
		string_free(source)
		println2(c"javascript_inspect: cannot read input")
		return 2
	pg_parse_result* result = js_parse(source.data, source.length, path, args_has_flag(c"module"))
	string_free(source)
	int failed = result.success == 0
	if (failed): pg_diagnostics_print(result.diagnostics)
	else if (args_has_flag(c"check") == 0): js_inspect_declarations(result.root)
	pg_parse_result_free(result)
	return failed
