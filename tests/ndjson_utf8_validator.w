/*
Validates a `w check --json` NDJSON capture: every line must be valid
UTF-8 and parse as a JSON object carrying the documented diagnostic
fields (docs/projects/ai_tooling.md), and the capture must not be
empty. Regression guard for compiler/diagnostics.w's
diag_write_json_string byte-escaping (#287): invalid source bytes
reflected into a diagnostic's message/token/file must be \u00XX-escaped,
never copied through raw, so the emitted stream stays valid JSON for
strict consumers. Driven by the check_json_utf8_test and utf8_bom_test
targets in build.base.json.

Reads bytes with getchar() rather than lib.file's line helpers:
lib.stream's stream_peek_byte sign-extends the byte 0xFF into the -1
EOF sentinel and would truncate exactly the raw-invalid-byte captures
this validator exists to inspect (logged in
docs/projects/ai_tooling_next_steps.md).

Usage: ndjson_utf8_validator file.ndjson
*/
import lib.lib
import lib.utf8
import structures.json


int fail(char* reason, int line_index):
	print(c"ndjson_utf8_validator: line ")
	print(itoa(line_index))
	print(c": ")
	println(reason)
	return 1


char* required_field(int index):
	if (index == 0):
		return c"file"
	if (index == 1):
		return c"line"
	if (index == 2):
		return c"column"
	if (index == 3):
		return c"severity"
	if (index == 4):
		return c"message"
	if (index == 5):
		return c"token"
	return c"arch"


int validate_line(char* line, int length, int line_index):
	if (utf8_validate_bytes(line, length) == 0):
		return fail(c"is not valid UTF-8", line_index)
	json_value* value = json_parse(line)
	if (value == 0):
		return fail(c"does not parse as JSON", line_index)
	if (value.type != json_type_object()):
		return fail(c"is not a JSON object", line_index)
	int i = 0
	while (i < 7):
		if (json_object_has(value, required_field(i)) == 0):
			print(c"ndjson_utf8_validator: missing field '")
			print(required_field(i))
			println(c"'")
			return fail(c"is missing a diagnostic field", line_index)
		i = i + 1
	json_free(value)
	return 0


int main(int argc, int argv):
	if (argc != 2):
		println(c"usage: ndjson_utf8_validator file.ndjson")
		return 2
	char** path = argv + __word_size__
	int f = open(*path, 0, 511)
	if (f < 0):
		print(c"ndjson_utf8_validator: cannot read ")
		println(*path)
		return 1
	getchar_reset(f)
	int capacity = 4096
	char* line = malloc(capacity)
	int length = 0
	int validated = 0
	int c = getchar(f)
	while (c != -1):
		if (c == 10):
			line[length] = 0
			if (validate_line(line, length, validated + 1)):
				return 1
			validated = validated + 1
			length = 0
		else:
			if (length + 2 >= capacity):
				line = realloc(line, capacity, capacity << 1)
				capacity = capacity << 1
			line[length] = c
			length = length + 1
		c = getchar(f)
	if (length > 0):
		line[length] = 0
		if (validate_line(line, length, validated + 1)):
			return 1
		validated = validated + 1
	close(f)
	free(line)
	if (validated == 0):
		println(c"ndjson_utf8_validator: no diagnostics in capture")
		return 1
	print(c"ndjson utf8 validator OK: ")
	print(itoa(validated))
	println(c" line(s)")
	return 0
