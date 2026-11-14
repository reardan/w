# Unicode default casing, pinned to the runtime's Unicode 12.1 data version.
# ECMA-262 String.prototype.toLowerCase / toUpperCase, Unicode §3.13.
# No locale-sensitive tailoring or implicit Unicode normalization.
import libs.extras.javascript.runtime
import libs.extras.javascript.runtime_string_support
import libs.extras.javascript.unicode_case

int js_case_next(js_text* text, int* position):
	int code = text.units[position[0]]
	position[0] = position[0] + 1
	if (code >= 55296 && code <= 56319 && position[0] < text.units.length):
		int low = text.units[position[0]]
		if (low >= 56320 && low <= 57343):
			position[0] = position[0] + 1
			return 65536 + ((code - 55296) << 10) + low - 56320
	return code

int js_case_following_cased(js_runtime* rt, js_text* input, int position):
	while (position < input.units.length):
		if (js_runtime_compat_step(rt) == 0): return 0
		int code = js_case_next(input, &position)
		if (js_unicode_case_ignorable(code) == 0): return js_unicode_cased(code)
	return 0

int js_case_append(js_runtime* rt, js_text* output, int code):
	int width = 1
	if (code > 65535): width = 2
	if (output.units.length > rt.max_properties - width):
		js_runtime_fail(rt, 5, c"JavaScript casing output length limit")
		return 0
	if (width == 2):
		output.units.push(55296 + ((code - 65536) >> 10))
		output.units.push(56320 + ((code - 65536) & 1023))
	else: output.units.push(code)
	return 1

js_value* js_string_case(void* runtime, void* context, js_value* receiver, list[js_value*] args):
	js_runtime* rt = cast(js_runtime*, runtime)
	js_text* input = js_string_this_text(rt, receiver, args)
	if (input == 0): return rt.undefined_value
	js_text* output = js_text_new()
	int upper = cast(int, context)
	int position = 0
	int preceding_cased = 0
	while (position < input.units.length && rt.completion.status == 0):
		if (js_runtime_compat_step(rt) == 0): break
		int code = js_case_next(input, &position)
		# Final_Sigma is the sole language-neutral conditional rule in 12.1.
		# Both context directions inspect the original input, ignoring every
		# Case_Ignorable code point even when it also has the Cased property.
		if (upper == 0 && code == 931 && preceding_cased && js_case_following_cased(rt, input, position) == 0):
			if (rt.completion.status == 0): js_case_append(rt, output, 962)
		else:
			char* mapping = 0
			if (upper): mapping = js_unicode_upper_mapping(code)
			else: mapping = js_unicode_lower_mapping(code)
			if (mapping == 0): js_case_append(rt, output, code)
			else:
				int count = mapping[0] & 255
				for i in range(count):
					if (js_case_append(rt, output, js_unicode_u24(mapping, 1 + i * 3)) == 0): break
		if (js_unicode_case_ignorable(code) == 0): preceding_cased = js_unicode_cased(code)
	js_value* result = rt.undefined_value
	if (rt.completion.status == 0): result = js_runtime_string(rt, output)
	js_text_free(output)
	js_text_free(input)
	return result


void js_install_string_case(js_runtime* rt):
	js_string_define_method(rt, rt.string_prototype, c"toLowerCase", js_string_case, 0, 0)
	js_string_define_method(rt, rt.string_prototype, c"toUpperCase", js_string_case, 1, 0)
