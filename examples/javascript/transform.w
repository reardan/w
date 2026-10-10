# wbuild: target=javascript_transform dep=javascript_parser
# wbuild: step="bin/wv2 examples/javascript/transform.w -o bin/javascript_transform"
# Rewrite static module specifiers, preserving all other source bytes.
import lib.args
import lib.stream
import libs.extras.javascript.transform


int main(int argc, int argv):
	args_init(argc, argv)
	if (args_positional_count() != 3):
		println2(c"usage: javascript_transform file.js old-specifier new-specifier")
		return 2
	char* path = args_positional(0)
	wstream* input = stream_open_read(path)
	if (input == 0):
		println2(c"javascript_transform: cannot read input")
		return 2
	string_builder* source = string_new()
	io_result read_result
	int status = stream_read_all_checked(input, source, &read_result)
	stream_close(input)
	if (status != IO_OK):
		string_free(source)
		println2(c"javascript_transform: cannot read input")
		return 2
	pg_parse_result* result = js_parse(source.data, source.length, path, 1)
	string_free(source)
	int length = 0
	char* output = js_rewrite_module_specifiers(result, args_positional(1), args_positional(2), &length)
	int failed = output == 0
	if (failed): pg_diagnostics_print(result.diagnostics)
	else:
		io_result write_result
		if (io_write_all(1, output, length, &write_result) != IO_OK): failed = 1
		free(output)
	pg_parse_result_free(result)
	return failed
