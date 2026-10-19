# Bounded JSON over UTF-16, independent of source evaluation. Preserves NUL,
# lone surrogate code units, duplicate-key semantics, and ordinary own data keys.
# https://tc39.es/ecma262/#sec-json-object
import libs.extras.javascript.runtime

struct js_json_reader:
	js_runtime* runtime
	js_text* text
	int position

void js_json_error(js_runtime* rt, char* name, char* message):
	if (rt.completion.status != 0): return
	if (rt.max_values - rt.heap.length < 5):
		js_runtime_fail(rt, 5, c"JSON error allocation limit")
		return
	js_value* error = js_runtime_error_value(rt, message)
	error.intrinsic_error_name = name
	if (strcmp(name, c"SyntaxError") == 0): error.prototype = rt.syntax_error_prototype
	js_text* text = js_runtime_key(name)
	js_runtime_set(rt, error, c"name", js_runtime_string(rt, text))
	js_text_free(text)
	js_runtime_throw(rt, error)

int js_json_peek(js_json_reader* reader):
	if (reader.position >= reader.text.units.length): return -1
	return reader.text.units[reader.position]

void js_json_space(js_json_reader* reader):
	int unit = js_json_peek(reader)
	while (unit == 32 || unit == 9 || unit == 10 || unit == 13):
		reader.position = reader.position + 1
		unit = js_json_peek(reader)

js_value* js_json_syntax(js_json_reader* reader):
	js_json_error(reader.runtime, c"SyntaxError", c"Invalid JSON text")
	return reader.runtime.undefined_value

int js_json_hex(int unit):
	if (unit >= '0' && unit <= '9'): return unit - '0'
	if (unit >= 'a' && unit <= 'f'): return unit - 'a' + 10
	if (unit >= 'A' && unit <= 'F'): return unit - 'A' + 10
	return -1

js_value* js_json_string(js_json_reader* reader):
	js_runtime* rt = reader.runtime
	reader.position = reader.position + 1
	js_text* text = js_text_new()
	int closed = 0
	while (reader.position < reader.text.units.length):
		int unit = reader.text.units[reader.position]
		reader.position = reader.position + 1
		if (unit == '"'):
			closed = 1
			break
		if (unit < 32): break
		if (unit == '\\'):
			unit = js_json_peek(reader)
			reader.position = reader.position + 1
			if (unit == 'u'):
				int cp = 0
				int valid = 1
				for i in range(4):
					int digit = js_json_hex(js_json_peek(reader))
					if (digit < 0):
						valid = 0
						break
					reader.position = reader.position + 1
					cp = cp * 16 + digit
				if (valid == 0): break
				unit = cp
			else if (unit == 'b'): unit = 8
			else if (unit == 'f'): unit = 12
			else if (unit == 'n'): unit = 10
			else if (unit == 'r'): unit = 13
			else if (unit == 't'): unit = 9
			else if (unit != '"' && unit != '\\' && unit != '/'): break
		text.units.push(unit)
	js_value* result = rt.undefined_value
	if (closed): result = js_runtime_string(rt, text)
	else: js_json_syntax(reader)
	js_text_free(text)
	return result

int js_json_digit(int unit):
	return unit >= '0' && unit <= '9'

js_value* js_json_number(js_json_reader* reader):
	int first = reader.position
	if (js_json_peek(reader) == '-'): reader.position = reader.position + 1
	if (js_json_peek(reader) == '0'): reader.position = reader.position + 1
	else:
		if (js_json_peek(reader) < '1' || js_json_peek(reader) > '9'): return js_json_syntax(reader)
		while (js_json_digit(js_json_peek(reader))): reader.position = reader.position + 1
	if (js_json_peek(reader) == '.'):
		reader.position = reader.position + 1
		if (js_json_digit(js_json_peek(reader)) == 0): return js_json_syntax(reader)
		while (js_json_digit(js_json_peek(reader))): reader.position = reader.position + 1
	if (js_json_peek(reader) == 'e' || js_json_peek(reader) == 'E'):
		reader.position = reader.position + 1
		if (js_json_peek(reader) == '+' || js_json_peek(reader) == '-'): reader.position = reader.position + 1
		if (js_json_digit(js_json_peek(reader)) == 0): return js_json_syntax(reader)
		while (js_json_digit(js_json_peek(reader))): reader.position = reader.position + 1
	string_builder* text = string_new()
	for i in range(first, reader.position): string_append_char(text, reader.text.units[i])
	int consumed = 0
	float64 number = parse_float64(text.data, &consumed)
	int valid = consumed == text.length
	string_free(text)
	if (valid == 0): return js_json_syntax(reader)
	return js_runtime_number(reader.runtime, number)

js_value* js_json_value(js_json_reader* reader, int depth):
	js_runtime* rt = reader.runtime
	if (rt.completion.status != 0): return rt.undefined_value
	if (depth >= 128 || depth >= rt.max_depth || js_runtime_compat_step(rt) == 0):
		js_runtime_fail(rt, 5, c"JSON nesting or execution limit")
		return rt.undefined_value
	js_json_space(reader)
	int unit = js_json_peek(reader)
	if (unit == '"'): return js_json_string(reader)
	if (unit == '-' || js_json_digit(unit)): return js_json_number(reader)
	if (unit == 't' || unit == 'f' || unit == 'n'):
		char* word = c"null"
		if (unit == 't'): word = c"true"
		if (unit == 'f'): word = c"false"
		for i in range(strlen(word)):
			if (js_json_peek(reader) != word[i]): return js_json_syntax(reader)
			reader.position = reader.position + 1
		if (unit == 'n'): return js_runtime_alloc(rt, 1)
		return js_runtime_boolean(rt, unit == 't')
	if (unit != '[' && unit != '{'): return js_json_syntax(reader)
	int array = unit == '['
	int close = '}'
	if (array): close = ']'
	js_value* value = js_runtime_alloc(rt, 5 + array)
	reader.position = reader.position + 1
	js_json_space(reader)
	if (js_json_peek(reader) == close):
		reader.position = reader.position + 1
		return value
	while (rt.completion.status == 0):
		js_value* key = 0
		if (array == 0):
			if (js_json_peek(reader) != '"'): return js_json_syntax(reader)
			key = js_json_string(reader)
			if (rt.completion.status != 0): break
			js_json_space(reader)
			if (js_json_peek(reader) != ':'): return js_json_syntax(reader)
			reader.position = reader.position + 1
		js_value* child = js_json_value(reader, depth + 1)
		if (rt.completion.status != 0): break
		if (array): js_runtime_array_append(rt, value, child)
		else: js_runtime_put(rt, value, key.text, child)
		js_json_space(reader)
		if (js_json_peek(reader) == close):
			reader.position = reader.position + 1
			return value
		if (js_json_peek(reader) != ','): return js_json_syntax(reader)
		reader.position = reader.position + 1
		js_json_space(reader)
	return rt.undefined_value

js_value* js_runtime_json_parse(js_runtime* rt, js_text* text):
	if (rt.completion.status != 0): return rt.undefined_value
	if (text == 0 || text.units.length > rt.max_source_bytes || text.units.length > rt.remaining):
		js_runtime_fail(rt, 5, c"JSON input or execution limit")
		return rt.undefined_value
	rt.remaining = rt.remaining - text.units.length
	js_json_reader reader
	reader.runtime = rt
	reader.text = text
	reader.position = 0
	js_value* result = js_json_value(&reader, 0)
	js_json_space(&reader)
	if (rt.completion.status == 0 && reader.position != text.units.length): return js_json_syntax(&reader)
	return result

js_value* js_json_parse_host(void* runtime, void* context, js_value* receiver, list[js_value*] args):
	js_runtime* rt = cast(js_runtime*, runtime)
	if (args.length > 1 && (args[1].kind == 7 || args[1].kind == 9)):
		js_runtime_fail(rt, 6, c"JSON.parse reviver is unsupported")
		return rt.undefined_value
	js_value* text = js_builtin_string(rt, 0, rt.undefined_value, args)
	if (rt.completion.status != 0): return rt.undefined_value
	# String() without arguments is empty, but JSON.parse() converts undefined.
	# Both are invalid JSON and produce the same required SyntaxError.
	return js_runtime_json_parse(rt, text.text)

struct js_json_writer:
	js_runtime* runtime
	js_text* text
	list[js_value*] path

void js_json_emit(js_json_writer* writer, int unit):
	js_runtime* rt = writer.runtime
	if (rt.completion.status != 0): return
	if (writer.text.units.length >= rt.max_properties || js_runtime_compat_step(rt) == 0):
		js_runtime_fail(rt, 5, c"JSON output or execution limit")
		return
	writer.text.units.push(unit)

void js_json_word(js_json_writer* writer, char* word):
	for i in range(strlen(word)): js_json_emit(writer, word[i])

void js_json_quote(js_json_writer* writer, js_text* text):
	js_json_emit(writer, '"')
	for i in range(text.units.length):
		if (writer.runtime.completion.status != 0): break
		int unit = text.units[i]
		if (unit == '"' || unit == '\\'):
			js_json_emit(writer, '\\')
			js_json_emit(writer, unit)
		else if (unit < 32 || (unit >= 55296 && unit <= 57343)):
			if (unit >= 55296 && unit <= 56319 && i + 1 < text.units.length && text.units[i + 1] >= 56320 && text.units[i + 1] <= 57343):
				js_json_emit(writer, unit)
				i = i + 1
				js_json_emit(writer, text.units[i])
			else:
				int escape = 0
				if (unit == 8): escape = 'b'
				if (unit == 9): escape = 't'
				if (unit == 10): escape = 'n'
				if (unit == 12): escape = 'f'
				if (unit == 13): escape = 'r'
				js_json_emit(writer, '\\')
				if (escape): js_json_emit(writer, escape)
				else:
					js_json_emit(writer, 'u')
					char* hex = c"0123456789abcdef"
					for j in range(4): js_json_emit(writer, hex[(unit >> ((3 - j) * 4)) & 15])
		else: js_json_emit(writer, unit)
	js_json_emit(writer, '"')

# Transform toJSON before deciding whether an object property should be omitted.
js_value* js_json_transform(js_runtime* rt, js_value* value, js_text* key):
	if (js_runtime_object(value) || value.kind == 10):
		js_value* method = js_runtime_get(rt, value, c"toJSON")
		if (method.kind == 7 || method.kind == 9):
			list[js_value*] args = new list[js_value*]
			args.push(js_runtime_string(rt, key))
			value = js_runtime_call_receiver(rt, method, value, args)
			__w_list_free(cast(__w_list*, args))
	return value

void js_json_serialize(js_json_writer* writer, js_value* value):
	js_runtime* rt = writer.runtime
	if (rt.completion.status != 0): return
	if (js_runtime_compat_step(rt) == 0): return
	if (value.kind == 1):
		js_json_word(writer, c"null")
		return
	if (value.kind == 2):
		if (value.number == 0.0): js_json_word(writer, c"false")
		else: js_json_word(writer, c"true")
		return
	if (value.kind == 3):
		if (js_builtin_finite(value.number) == 0): js_json_word(writer, c"null")
		else:
			char* number = js_runtime_number_text(value.number)
			js_json_word(writer, number)
			free(number)
		return
	if (value.kind == 4):
		js_json_quote(writer, value.text)
		return
	if (value.kind == 10):
		js_json_error(rt, c"TypeError", c"BigInt cannot be serialized as JSON")
		return
	if (writer.path.length >= 128 || writer.path.length >= rt.max_depth):
		js_runtime_fail(rt, 5, c"JSON serialization nesting limit")
		return
	for i in range(writer.path.length):
		if (writer.path[i] == value):
			js_json_error(rt, c"TypeError", c"Cyclic JSON value")
			return
	writer.path.push(value)
	int array = value.kind == 6
	int close = '}'
	if (array): close = ']'
	if (array): js_json_emit(writer, '[')
	else: js_json_emit(writer, '{')
	list[js_text*] keys = new list[js_text*]
	if (array):
		for i in range(value.array_length):
			if (js_runtime_compat_step(rt) == 0): break
			char* key = itoa(i)
			keys.push(js_runtime_key(key))
			free(key)
	else:
		# Snapshot enumerable own keys; integer indices precede other strings.
		for i in range(value.properties.length):
			js_value* property = value.properties[i]
			if (property.enumerable):
				if (property.key.units.length > rt.remaining || js_runtime_compat_step(rt) == 0):
					js_runtime_fail(rt, 5, c"JSON key traversal limit")
					break
				rt.remaining = rt.remaining - property.key.units.length
				js_text* key = js_text_clone(property.key)
				int index = js_runtime_array_index(key)
				int position = keys.length
				keys.push(key)
				while (index >= 0 && position > 0):
					if (js_runtime_compat_step(rt) == 0): break
					int previous = js_runtime_array_index(keys[position - 1])
					if (previous >= 0 && previous < index): break
					keys[position] = keys[position - 1]
					position = position - 1
				keys[position] = key
	int count = 0
	for i in range(keys.length):
		if (rt.completion.status != 0): break
		js_value* child = js_runtime_member_read(rt, value, keys[i])
		child = js_json_transform(rt, child, keys[i])
		if (rt.completion.status != 0): break
		int omitted = child.kind == 0 || child.kind == 7 || child.kind == 9
		if (omitted && array == 0): continue
		if (count > 0): js_json_emit(writer, ',')
		if (array == 0):
			js_json_quote(writer, keys[i])
			js_json_emit(writer, ':')
		if (omitted): js_json_word(writer, c"null")
		else: js_json_serialize(writer, child)
		count = count + 1
	for i in range(keys.length): js_text_free(keys[i])
	__w_list_free(cast(__w_list*, keys))
	writer.path.pop()
	js_json_emit(writer, close)

js_value* js_json_stringify_host(void* runtime, void* context, js_value* receiver, list[js_value*] args):
	js_runtime* rt = cast(js_runtime*, runtime)
	if (args.length == 0): return rt.undefined_value
	if ((args.length > 1 && args[1].kind != 0 && args[1].kind != 1) || (args.length > 2 && args[2].kind != 0)):
		js_runtime_fail(rt, 6, c"JSON.stringify replacer and indentation are unsupported")
		return rt.undefined_value
	js_text* key = js_runtime_key(c"")
	js_value* value = js_json_transform(rt, args[0], key)
	js_text_free(key)
	if (rt.completion.status != 0 || value.kind == 0 || value.kind == 7 || value.kind == 9): return rt.undefined_value
	js_json_writer writer
	writer.runtime = rt
	writer.text = js_text_new()
	writer.path = new list[js_value*]
	js_json_serialize(&writer, value)
	js_value* result = rt.undefined_value
	if (rt.completion.status == 0): result = js_runtime_string(rt, writer.text)
	js_text_free(writer.text)
	__w_list_free(cast(__w_list*, writer.path))
	return result

void js_runtime_install_json(js_runtime* rt):
	js_value* json = js_runtime_alloc(rt, 5)
	js_object_method(rt, json, c"parse", js_json_parse_host, 0, 2)
	js_object_method(rt, json, c"stringify", js_json_stringify_host, 0, 3)
	js_runtime_set(rt, rt.global, c"JSON", json)
