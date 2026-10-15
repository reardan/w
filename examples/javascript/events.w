# A future browser host can retain a handler, collect, then dispatch native data.
# wbuild: target=javascript_events_example tag=tests dep=javascript_parser
# wbuild: step="bin/wv2 x64 examples/javascript/events.w -o bin/javascript_events_example"
# wbuild: step="bin/javascript_events_example" expect_stdout="input: 42"
import libs.extras.javascript.runtime


int main():
	js_runtime* runtime = js_runtime_new()
	char* source = c"let total = 0; event => { total += event.amount; return `${event.type}: ${total}`; };"
	js_completion* result = js_runtime_eval(runtime, source, strlen(source), 1000)
	if (result.status != 0):
		println2(result.message)
		js_runtime_free(runtime)
		return 1
	js_value* handler = result.value
	js_runtime_root(runtime, handler)
	js_runtime_collect(runtime)
	js_value* event = js_runtime_alloc(runtime, 5)
	js_text* type_name = js_runtime_key(c"input")
	js_runtime_set(runtime, event, c"type", js_runtime_string(runtime, type_name))
	js_text_free(type_name)
	js_runtime_set(runtime, event, c"amount", js_runtime_number(runtime, 42.0))
	list[js_value*] arguments = new list[js_value*]
	arguments.push(event)
	result = js_runtime_invoke(runtime, handler, arguments, 1000)
	int status = result.status
	if (status != 0): println2(result.message)
	else:
		int length = 0
		char* text = js_text_to_utf8(result.value.text, &length)
		if (text == 0): status = 1
		else:
			write(1, text, length)
			println(c"")
			free(text)
	__w_list_free(cast(__w_list*, arguments))
	js_runtime_unroot(runtime, handler)
	js_runtime_free(runtime)
	return status
