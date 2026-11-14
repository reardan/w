import libs.extras.javascript.runtime
import lib.assert

void case_number(int value):
	char* text = itoa(value)
	print(text)
	free(text)

void output_units(js_value* value):
	print(c"[")
	for i in range(value.text.units.length):
		if (i): print(c",")
		case_number(value.text.units[i])
	print(c"]")

int main():
	js_runtime* rt = js_runtime_new()
	list[js_value*] args = new list[js_value*]
	for cp in range(1114112):
		if (js_unicode_lower_mapping(cp) == 0 && js_unicode_upper_mapping(cp) == 0): continue
		js_runtime_collect(rt)
		js_runtime_begin(rt, 10000)
		rt.running = 1
		js_text* input = js_text_new()
		js_case_append(rt, input, cp)
		js_value* receiver = js_runtime_string(rt, input)
		js_text_free(input)
		js_value* lower = js_string_case(rt, 0, receiver, args)
		js_value* upper = js_string_case(rt, cast(void*, 1), receiver, args)
		assert_equal(0, rt.completion.status)
		print(c"[")
		case_number(cp)
		print(c",")
		output_units(lower)
		print(c",")
		output_units(upper)
		println(c"]")
		rt.running = 0
	__w_list_free(cast(__w_list*, args))
	js_runtime_free(rt)
	return 0
