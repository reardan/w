# Small differential-test consumer; compiled by javascript_compatibility.py.
import lib.args
import lib.stream
import libs.extras.javascript.runtime


int main(int argc, int argv):
	args_init(argc, argv)
	if (args_positional_count() != 1): return 2
	wstream* input = stream_open_read(args_positional(0))
	if (input == 0): return 2
	string_builder* source = string_new()
	io_result read_result
	int status = stream_read_all_checked(input, source, &read_result)
	stream_close(input)
	if (status != IO_OK):
		string_free(source)
		return 2
	js_runtime* runtime = js_runtime_new()
	js_completion* result = js_runtime_eval(runtime, source.data, source.length, 100000)
	string_free(source)
	status = result.status
	if (status == 0):
		js_text* value = js_runtime_primitive_text(runtime, result.value)
		int length = 0
		char* text = 0
		if (value != 0): text = js_text_to_utf8(value, &length)
		if (text == 0): status = 2
		else:
			write(1, text, length)
			println(c"")
		free(text)
		js_text_free(value)
	else: println2(result.message)
	js_runtime_free(runtime)
	return status
