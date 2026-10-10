# External-consumer host callback and retained JS closure, independent of a DOM or UI.
# wbuild: target=javascript_embed_example tag=tests dep=javascript_parser
# wbuild: step="bin/wv2 x64 examples/javascript/embed.w -o bin/javascript_embed_example"
# wbuild: step="bin/javascript_embed_example" expect_stdout="42"
import libs.extras.javascript.runtime


js_value* double_number(void* context, list[js_value*] arguments):
	js_runtime* runtime = cast(js_runtime*, context)
	if (arguments.length != 1 || arguments[0].kind != 3):
		js_runtime_throw(runtime, runtime.undefined_value)
		return runtime.undefined_value
	return js_runtime_number(runtime, arguments[0].number * 2.0)


int main():
	js_runtime* runtime = js_runtime_new()
	js_runtime_bind(runtime, c"doubleNumber", double_number)
	char* source = c"(function(value) { return doubleNumber(value); });"
	js_completion* result = js_runtime_eval(runtime, source, strlen(source), 1000)
	if (result.status != 0):
		println2(result.message)
		js_runtime_free(runtime)
		return 1
	# A host event loop can retain the closure and invoke it in a later turn.
	js_value* callback = result.value
	js_runtime_root(runtime, callback)
	js_runtime_eval(runtime, c"0;", 2, 100)
	js_runtime_collect(runtime)
	list[js_value*] arguments = new list[js_value*]
	arguments.push(js_runtime_number(runtime, 21.0))
	result = js_runtime_invoke(runtime, callback, arguments, 1000)
	__w_list_free(cast(__w_list*, arguments))
	js_runtime_unroot(runtime, callback)
	if (result.status != 0):
		println2(result.message)
		js_runtime_free(runtime)
		return 1
	char* number = f64toa(result.value.number)
	println(number)
	free(number)
	js_runtime_free(runtime)
	return 0
