# Shared bounded JSON control helpers; independent of host VM backend.
import lib.json_rpc
import lib.process


json_value* vms_field(json_value* object, char* key):
	if (object == 0 || object.type != json_type_object()): return 0
	return json_object_get(object, key)


int vms_number(json_value* object, char* key, int fallback):
	json_value* value = vms_field(object, key)
	if (value == 0): return fallback
	if (value.type != json_type_int()): return -1
	return value.int_value


char* vms_text(json_value* object, char* key):
	json_value* value = vms_field(object, key)
	if (value == 0 || value.type != json_type_string()): return 0
	return value.string_value


json_value* vms_error(char* message):
	json_value* value = json_object()
	json_object_set(value, c"error", json_string(message))
	return value


# Prevent integer overflow in the generic framing parser. The canonical
# Content-Length header emitted by lib.framing is the wire format here.
char* vms_take_frame(frame_reader* reader, int maximum):
	int end = frame_find_header_end(reader)
	if (end < 0):
		if (reader.length - reader.offset > 64): reader.error = 1
		return 0
	int at = reader.offset
	char* prefix = c"Content-Length: "
	for i in range(16):
		if (at + i >= end || reader.buffer[at + i] != prefix[i]):
			reader.error = 1
			return 0
	at = at + 16
	int length = 0
	int digits = 0
	while (at < end && reader.buffer[at] >= '0' && reader.buffer[at] <= '9'):
		length = length * 10 + reader.buffer[at] - '0'
		digits = digits + 1
		at = at + 1
		if (digits > 8 || length > maximum):
			reader.error = 1
			return 0
	if (digits == 0 || at + 4 != end):
		reader.error = 1
		return 0
	int ignored = 0
	return frame_take_buffered_message(reader, &ignored)


# Bound parser recursion and reject NUL escapes, since downstream argv and
# path APIs use C strings and cannot represent an embedded NUL.
int vms_json_safe(char* body):
	int depth = 0
	int quoted = 0
	int at = 0
	while (body[at] != 0):
		int ch = cast(int, body[at])
		if (quoted):
			if (ch == 92):
				at = at + 1
				if (body[at] == 0): return 0
				if (body[at] == 'u'):
					int zeros = 0
					for i in range(4):
						if (body[at + 1 + i] == 0): return 0
						if (body[at + 1 + i] == '0'): zeros = zeros + 1
					if (zeros == 4): return 0
			else if (ch == 34): quoted = 0
		else:
			if (ch == 34): quoted = 1
			else if (ch == '{' || ch == '['): depth = depth + 1
			else if (ch == '}' || ch == ']'): depth = depth - 1
			if (depth < 0 || depth > 32): return 0
		at = at + 1
	return quoted == 0 && depth == 0
