/*
Small JSON parser/serializer for the current W runtime.

Supported JSON subset:
- objects with string keys
- arrays
- string, integer, boolean, and null values
- string escapes: \" \\ \/ \b \f \n \r \t and ASCII \uXXXX

Numbers are signed base-10 integers only: floating point, exponents, and
values outside the 32-bit signed positive range are rejected. Parsed trees own
their children; call json_free() on the root. Object serialization walks the
backing hash map, so member order is deterministic but is not insertion order.
*/
import lib.lib
import lib.assert
import structures.string
import structures.hash_map
import structures.array_list


struct json_value:
	int type
	int int_value
	char* string_value
	hash_map* object_values
	array_list* array_values


struct json_parser:
	char* input
	int index
	int ok


void json_free(json_value* value);
json_value* json_parse_value(json_parser* p, int depth);
json_value* json_parse_object(json_parser* p, int depth);
json_value* json_parse_array(json_parser* p, int depth);
void json_append_value(string_builder* out, json_value* value);
void json_append_object(string_builder* out, json_value* value);
void json_append_array(string_builder* out, json_value* value);


int json_type_null():
	return 0


int json_type_int():
	return 1


int json_type_string():
	return 2


int json_type_bool():
	return 3


int json_type_object():
	return 4


int json_type_array():
	return 5


json_value* json_new(int type):
	json_value* value = new json_value()
	value.type = type
	value.int_value = 0
	value.string_value = 0
	value.object_values = 0
	value.array_values = 0
	return value


json_value* json_null():
	return json_new(json_type_null())


json_value* json_int(int n):
	json_value* value = json_new(json_type_int())
	value.int_value = n
	return value


json_value* json_bool(int n):
	json_value* value = json_new(json_type_bool())
	if (n == 0):
		value.int_value = 0
	else:
		value.int_value = 1
	return value


json_value* json_string_take(char* text):
	json_value* value = json_new(json_type_string())
	value.string_value = text
	return value


json_value* json_string(char* text):
	return json_string_take(strclone(text))


json_value* json_object():
	json_value* value = json_new(json_type_object())
	value.object_values = hash_map_new()
	return value


json_value* json_array():
	json_value* value = json_new(json_type_array())
	value.array_values = array_list_new()
	return value


void json_object_set(json_value* object, char* key, json_value* value):
	assert1(object.type == json_type_object())
	if (hash_map_contains(object.object_values, key)):
		json_value* old_value = cast(json_value*, hash_map_get(object.object_values, key))
		if (old_value != value):
			json_free(old_value)
	hash_map_set(object.object_values, key, cast(int, value))


json_value* json_object_get(json_value* object, char* key):
	assert1(object.type == json_type_object())
	return cast(json_value*, hash_map_get_default(object.object_values, key, 0))


int json_object_has(json_value* object, char* key):
	assert1(object.type == json_type_object())
	return hash_map_contains(object.object_values, key)


void json_array_push(json_value* array, json_value* value):
	assert1(array.type == json_type_array())
	array_list_push(array.array_values, cast(int, value))


json_value* json_array_get(json_value* array, int index):
	assert1(array.type == json_type_array())
	return cast(json_value*, array_list_get(array.array_values, index))


int json_array_length(json_value* array):
	assert1(array.type == json_type_array())
	return array.array_values.length


void json_free(json_value* value):
	if (value == 0):
		return
	if (value.type == json_type_string()):
		free(value.string_value)
	else if (value.type == json_type_object()):
		hash_map* map = value.object_values
		int i = 0
		while (i < map.capacity):
			if (map.keys[i] != 0):
				json_free(cast(json_value*, map.values[i]))
			i = i + 1
		hash_map_free(map)
	else if (value.type == json_type_array()):
		array_list* list = value.array_values
		int i = 0
		while (i < list.length):
			json_free(cast(json_value*, list.items[i]))
			i = i + 1
		array_list_free(list)
	free(value)


json_parser* json_parser_new(char* input):
	json_parser* p = new json_parser()
	p.input = input
	p.index = 0
	p.ok = 1
	return p


void json_fail(json_parser* p):
	p.ok = 0


int json_is_space(int c):
	return (c == ' ') | (c == '\n') | (c == '\r') | (c == '\t')


int json_is_digit(int c):
	return (c >= '0') & (c <= '9')


int json_max_depth():
	return 128


int json_hex_value(int c):
	if ((c >= '0') & (c <= '9')):
		return c - '0'
	if ((c >= 'a') & (c <= 'f')):
		return c - 'a' + 10
	if ((c >= 'A') & (c <= 'F')):
		return c - 'A' + 10
	return -1


void json_append_hex_digit(string_builder* out, int value):
	if (value < 10):
		string_append_char(out, '0' + value)
	else:
		string_append_char(out, 'a' + value - 10)


void json_skip_ws(json_parser* p):
	while (json_is_space(p.input[p.index])):
		p.index = p.index + 1


int json_take(json_parser* p, int c):
	json_skip_ws(p)
	if (p.input[p.index] != c):
		json_fail(p)
		return 0
	p.index = p.index + 1
	return 1


int json_match(json_parser* p, char* word):
	int start = p.index
	int i = 0
	while (word[i] != 0):
		if (p.input[p.index] != word[i]):
			p.index = start
			json_fail(p)
			return 0
		p.index = p.index + 1
		i = i + 1
	return 1


char* json_take_string_data(string_builder* s):
	char* data = s.data
	free(s)
	return data


char* json_parse_string_raw(json_parser* p):
	json_skip_ws(p)
	if (p.input[p.index] != '"'):
		json_fail(p)
		return 0
	p.index = p.index + 1

	string_builder* out = string_new()
	while (p.input[p.index] != 0):
		int c = p.input[p.index]
		if (c == '"'):
			p.index = p.index + 1
			return json_take_string_data(out)
		if (c == '\\'):
			p.index = p.index + 1
			c = p.input[p.index]
			if (c == 0):
				json_fail(p)
				string_free(out)
				return 0
			if (c == '"'):
				string_append_char(out, '"')
			else if (c == '\\'):
				string_append_char(out, '\\')
			else if (c == '/'):
				string_append_char(out, '/')
			else if (c == 'b'):
				string_append_char(out, 8)
			else if (c == 'f'):
				string_append_char(out, 12)
			else if (c == 'n'):
				string_append_char(out, '\n')
			else if (c == 'r'):
				string_append_char(out, '\r')
			else if (c == 't'):
				string_append_char(out, '\t')
			else if (c == 'u'):
				int value = 0
				int i = 1
				while (i <= 4):
					int digit = json_hex_value(p.input[p.index + i])
					if (digit < 0):
						json_fail(p)
						string_free(out)
						return 0
					value = value * 16 + digit
					i = i + 1
				if (value > 127):
					json_fail(p)
					string_free(out)
					return 0
				string_append_char(out, value)
				p.index = p.index + 4
			else:
				json_fail(p)
				string_free(out)
				return 0
		else:
			string_append_char(out, c)
		p.index = p.index + 1

	json_fail(p)
	string_free(out)
	return 0


json_value* json_parse_string_value(json_parser* p):
	char* text = json_parse_string_raw(p)
	if (p.ok == 0):
		return 0
	return json_string_take(text)


json_value* json_parse_number(json_parser* p):
	int negative = 0
	int value = 0
	if (p.input[p.index] == '-'):
		negative = 1
		p.index = p.index + 1

	if (json_is_digit(p.input[p.index]) == 0):
		json_fail(p)
		return 0

	if (p.input[p.index] == '0'):
		p.index = p.index + 1
		if (json_is_digit(p.input[p.index])):
			json_fail(p)
			return 0
	else:
		while (json_is_digit(p.input[p.index])):
			int digit = p.input[p.index] - '0'
			if ((value > 214748364) | ((value == 214748364) & (digit > 7))):
				json_fail(p)
				return 0
			value = value * 10 + digit
			p.index = p.index + 1

	if (negative):
		value = 0 - value
	return json_int(value)


json_value* json_parse_object(json_parser* p, int depth):
	json_value* object = json_object()
	p.index = p.index + 1
	json_skip_ws(p)
	if (p.input[p.index] == '}'):
		p.index = p.index + 1
		return object

	while (p.ok):
		char* key = json_parse_string_raw(p)
		if (p.ok == 0):
			return object
		if (json_take(p, ':') == 0):
			free(key)
			return object
		json_value* child = json_parse_value(p, depth)
		if (p.ok == 0):
			json_free(child)
			free(key)
			return object
		json_object_set(object, key, child)
		free(key)

		json_skip_ws(p)
		if (p.input[p.index] == '}'):
			p.index = p.index + 1
			return object
		if (p.input[p.index] != ','):
			json_fail(p)
			return object
		p.index = p.index + 1

	return object


json_value* json_parse_array(json_parser* p, int depth):
	json_value* array = json_array()
	p.index = p.index + 1
	json_skip_ws(p)
	if (p.input[p.index] == ']'):
		p.index = p.index + 1
		return array

	while (p.ok):
		json_value* child = json_parse_value(p, depth)
		if (p.ok == 0):
			json_free(child)
			return array
		json_array_push(array, child)

		json_skip_ws(p)
		if (p.input[p.index] == ']'):
			p.index = p.index + 1
			return array
		if (p.input[p.index] != ','):
			json_fail(p)
			return array
		p.index = p.index + 1

	return array


json_value* json_parse_value(json_parser* p, int depth):
	json_skip_ws(p)
	int c = p.input[p.index]
	if (c == '{'):
		if (depth >= json_max_depth()):
			json_fail(p)
			return 0
		return json_parse_object(p, depth + 1)
	if (c == '['):
		if (depth >= json_max_depth()):
			json_fail(p)
			return 0
		return json_parse_array(p, depth + 1)
	if (c == '"'):
		return json_parse_string_value(p)
	if (c == 't'):
		if (json_match(p, c"true")):
			return json_bool(1)
		return 0
	if (c == 'f'):
		if (json_match(p, c"false")):
			return json_bool(0)
		return 0
	if (c == 'n'):
		if (json_match(p, c"null")):
			return json_null()
		return 0
	if ((c == '-') | json_is_digit(c)):
		return json_parse_number(p)
	json_fail(p)
	return 0


json_value* json_parse(char* input):
	json_parser* p = json_parser_new(input)
	json_value* value = json_parse_value(p, 0)
	json_skip_ws(p)
	if (p.input[p.index] != 0):
		json_fail(p)
	if (p.ok == 0):
		json_free(value)
		free(p)
		return 0
	free(p)
	return value


void json_append_escaped_string(string_builder* out, char* text):
	string_append_char(out, '"')
	int i = 0
	while (text[i] != 0):
		int c = text[i]
		if (c == '"'):
			string_append_char(out, '\\')
			string_append_char(out, '"')
		else if (c == '\\'):
			string_append_char(out, '\\')
			string_append_char(out, '\\')
		else if (c == 8):
			string_append_char(out, '\\')
			string_append_char(out, 'b')
		else if (c == 12):
			string_append_char(out, '\\')
			string_append_char(out, 'f')
		else if (c == '\n'):
			string_append_char(out, '\\')
			string_append_char(out, 'n')
		else if (c == '\r'):
			string_append_char(out, '\\')
			string_append_char(out, 'r')
		else if (c == '\t'):
			string_append_char(out, '\\')
			string_append_char(out, 't')
		else if ((c > 0) & (c < 32)):
			string_append_char(out, '\\')
			string_append_char(out, 'u')
			string_append_char(out, '0')
			string_append_char(out, '0')
			json_append_hex_digit(out, c / 16)
			json_append_hex_digit(out, c & 15)
		else:
			string_append_char(out, c)
		i = i + 1
	string_append_char(out, '"')


void json_append_object(string_builder* out, json_value* value):
	string_append_char(out, '{')
	int first = 1
	hash_map* map = value.object_values
	int i = 0
	while (i < map.capacity):
		if (map.keys[i] != 0):
			if (first == 0):
				string_append_char(out, ',')
			first = 0
			json_append_escaped_string(out, map.keys[i])
			string_append_char(out, ':')
			json_append_value(out, cast(json_value*, map.values[i]))
		i = i + 1
	string_append_char(out, '}')


void json_append_array(string_builder* out, json_value* value):
	string_append_char(out, '[')
	int i = 0
	while (i < value.array_values.length):
		if (i > 0):
			string_append_char(out, ',')
		json_append_value(out, cast(json_value*, value.array_values.items[i]))
		i = i + 1
	string_append_char(out, ']')


void json_append_value(string_builder* out, json_value* value):
	if (value == 0):
		string_append(out, c"null")
	else if (value.type == json_type_null()):
		string_append(out, c"null")
	else if (value.type == json_type_int()):
		string_append_int(out, value.int_value)
	else if (value.type == json_type_string()):
		json_append_escaped_string(out, value.string_value)
	else if (value.type == json_type_bool()):
		if (value.int_value):
			string_append(out, c"true")
		else:
			string_append(out, c"false")
	else if (value.type == json_type_object()):
		json_append_object(out, value)
	else if (value.type == json_type_array()):
		json_append_array(out, value)


char* json_stringify(json_value* value):
	string_builder* out = string_new()
	json_append_value(out, value)
	return json_take_string_data(out)
