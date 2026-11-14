# Shared helpers for the String.prototype ports (code units, substring, trim,
# case conversion). Methods use origin's coercion (js_runtime_to_text and
# js_runtime_to_integer), so object conversion order and abrupt completions
# follow the specification; native work is charged to the active budget.
import libs.extras.javascript.runtime


# Define name and length on a host function, as for any built-in function.
void js_string_function_shape(js_runtime* rt, js_value* function, char* name, int length):
	js_text* key = js_runtime_key(c"name")
	js_text* label = js_runtime_key(name)
	js_runtime_define_data(rt, function, key, js_runtime_string(rt, label), 0, 0, 1)
	js_text_free(label)
	js_text_free(key)
	key = js_runtime_key(c"length")
	js_runtime_define_data(rt, function, key, js_runtime_number(rt, cast(float64, length)), 0, 0, 1)
	js_text_free(key)


# A writable, configurable, non-enumerable method; returns the function.
js_value* js_string_define_method(js_runtime* rt, js_value* object, char* name, js_host_receiver_function* callback, int code, int length):
	js_value* method = js_runtime_host_callable(rt, cast(void*, code), callback)
	if (method == rt.undefined_value): return method
	js_string_function_shape(rt, method, name, length)
	js_text* key = js_runtime_key(name)
	js_runtime_define_data(rt, object, key, method, 1, 0, 1)
	js_text_free(key)
	return method


# The index-th argument, undefined when absent. A value from another runtime
# is a TypeError rather than being read.
js_value* js_string_argument(js_runtime* rt, list[js_value*] args, int index):
	if (index >= args.length): return rt.undefined_value
	js_value* value = args[index]
	if (value == 0 || value.owner != rt):
		js_runtime_fail(rt, 2, c"argument belongs to another runtime")
		return rt.undefined_value
	return value


# RequireObjectCoercible(this) then ToString(this): owned text, or 0 with an
# abrupt completion. Argument-count and receiver checks come before any
# coercion, so a null receiver never runs user code.
js_text* js_string_this_text(js_runtime* rt, js_value* receiver, list[js_value*] args):
	if (js_builtin_arguments(rt, args) == 0): return 0
	for i in range(args.length):
		js_string_argument(rt, args, i)
	if (rt.completion.status != 0): return 0
	if (receiver == 0 || receiver.owner != rt || receiver.kind == 0 || receiver.kind == 1):
		js_runtime_fail(rt, 2, c"String.prototype method called on null, undefined or a foreign value")
		return 0
	return js_runtime_to_text(rt, receiver)


# ToIntegerOrInfinity of argument index (absent or undefined gives 0).
float64 js_string_integer(js_runtime* rt, list[js_value*] args, int index):
	js_value* value = js_string_argument(rt, args, index)
	if (rt.completion.status != 0): return 0.0
	return js_runtime_to_integer(rt, value)


# Charge count native steps to the active budget (js_rx_charge semantics: an
# unaffordable batch exhausts the budget and reports status 5). A batch larger
# than the string length limit is refused outright.
int js_string_charge(js_runtime* rt, int count):
	if (rt.completion.status != 0): return 0
	if (count > rt.max_properties):
		js_runtime_fail(rt, 5, c"JavaScript string length limit")
		return 0
	return js_rx_charge(rt, count)


# Copy units[start:end] into a new string value, charging the copy.
js_value* js_string_slice_value(js_runtime* rt, js_text* text, int start, int end):
	if (js_string_charge(rt, end - start) == 0): return rt.undefined_value
	js_text* output = js_text_new()
	for i in range(start, end): output.units.push(text.units[i])
	js_value* result = js_runtime_string(rt, output)
	js_text_free(output)
	return result
