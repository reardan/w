# UTF-8 one-shot Encoding API for browser host adapters. Streaming and non-UTF8
# labels explicitly fail; UTF-16 unpaired surrogates encode as U+FFFD.
import libs.extras.javascript.runtime


js_value* js_text_codec_encode(void* runtime, void* context, js_value* receiver, list[js_value*] args):
	js_runtime* rt = cast(js_runtime*, runtime)
	if (receiver.text_codec != 1):
		js_runtime_fail(rt, 2, c"invalid TextEncoder receiver")
		return rt.undefined_value
	js_text* text = js_text_new()
	if (args.length > 0 && args[0].kind != 0):
		if (args[0].kind != 4):
			js_text_free(text)
			js_runtime_fail(rt, 6, c"TextEncoder string coercion outside subset")
			return rt.undefined_value
		js_text* source = args[0].text
		for i in range(source.units.length):
			int cp = source.units[i]
			if (cp >= 55296 && cp <= 56319 && i + 1 < source.units.length):
				int low = source.units[i + 1]
				if (low >= 56320 && low <= 57343):
					text.units.push(cp)
					text.units.push(low)
					i = i + 1
					continue
			if (cp >= 55296 && cp <= 57343): cp = 65533
			text.units.push(cp)
	int length = 0
	char* encoded = js_text_to_utf8(text, &length)
	js_text_free(text)
	js_value* buffer = js_runtime_array_buffer_copy(rt, cast(byte*, encoded), length)
	free(encoded)
	if (buffer == rt.undefined_value): return buffer
	return js_runtime_binary_view(rt, 2, buffer, 0, length)


js_value* js_text_codec_decode(void* runtime, void* context, js_value* receiver, list[js_value*] args):
	js_runtime* rt = cast(js_runtime*, runtime)
	if (receiver.text_codec < 2):
		js_runtime_fail(rt, 2, c"invalid TextDecoder receiver")
		return rt.undefined_value
	if (args.length > 1 && js_runtime_object(args[1])):
		if (js_runtime_truth(js_runtime_get(rt, args[1], c"stream"))):
			js_runtime_fail(rt, 6, c"streaming TextDecoder outside subset")
			return rt.undefined_value
	byte* data = 0
	int length = 0
	if (args.length > 0 && args[0].kind != 0):
		if (args[0].binary_kind == 0):
			js_runtime_fail(rt, 2, c"TextDecoder requires buffer source")
			return rt.undefined_value
		data = js_runtime_binary_data(rt, args[0])
		length = js_runtime_binary_byte_length(rt, args[0])
	js_text* text = js_text_new()
	int i = 0
	while (i < length):
		int cp = 0
		int width = utf8_scan(cast(char*, data + i), length - i, &cp)
		if (width == 0):
			if (receiver.text_codec & 4):
				js_text_free(text)
				js_runtime_fail(rt, 2, c"invalid UTF-8")
				return rt.undefined_value
			cp = 65533
			width = 1
			# Consume a valid incomplete prefix as one replacement character.
			int lead = cast(int, data[i]) & 255
			int need = 0
			if (lead >= 194 && lead <= 223): need = 2
			if (lead >= 224 && lead <= 239): need = 3
			if (lead >= 240 && lead <= 244): need = 4
			while (width < need && i + width < length):
				int next = cast(int, data[i + width]) & 255
				if (next < 128 || next > 191): break
				if (width == 1):
					if ((lead == 224 && next < 160) || (lead == 237 && next > 159) || (lead == 240 && next < 144) || (lead == 244 && next > 143)): break
				width = width + 1
		if (i != 0 || cp != 65279 || (receiver.text_codec & 8)): js_text_append_scalar(text, cp)
		i = i + width
		if (text.units.length > rt.max_properties):
			js_text_free(text)
			js_runtime_fail(rt, 5, c"JavaScript string length limit")
			return rt.undefined_value
	js_value* value = js_runtime_string(rt, text)
	js_text_free(text)
	return value


js_value* js_text_codec_construct(void* runtime, void* context, js_value* receiver, list[js_value*] args):
	js_runtime* rt = cast(js_runtime*, runtime)
	int kind = cast(int, context)
	if (kind == 2 && args.length > 0 && args[0].kind != 0):
		if (args[0].kind != 4 || (js_runtime_key_is(args[0].text, c"utf-8") == 0 && js_runtime_key_is(args[0].text, c"utf8") == 0)):
			js_runtime_fail(rt, 6, c"TextDecoder supports utf-8 only")
			return rt.undefined_value
	js_value* value = js_runtime_alloc(rt, 5)
	if (value == rt.undefined_value): return value
	value.text_codec = kind
	if (kind == 2 && args.length > 1 && js_runtime_object(args[1])):
		if (js_runtime_truth(js_runtime_get(rt, args[1], c"fatal"))): value.text_codec = value.text_codec | 4
		if (js_runtime_truth(js_runtime_get(rt, args[1], c"ignoreBOM"))): value.text_codec = value.text_codec | 8
	if (kind == 1): js_runtime_set(rt, value, c"encode", js_runtime_host_callable(rt, 0, js_text_codec_encode))
	else: js_runtime_set(rt, value, c"decode", js_runtime_host_callable(rt, 0, js_text_codec_decode))
	return value


void js_runtime_install_text_codecs(js_runtime* rt):
	js_value* encoder = js_runtime_host_callable(rt, cast(void*, 1), js_text_codec_construct)
	js_value* decoder = js_runtime_host_callable(rt, cast(void*, 2), js_text_codec_construct)
	if (encoder == rt.undefined_value || decoder == rt.undefined_value): return
	encoder.host_construct = 1
	decoder.host_construct = 1
	js_runtime_set(rt, rt.global, c"TextEncoder", encoder)
	js_runtime_set(rt, rt.global, c"TextDecoder", decoder)
