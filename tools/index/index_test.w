# Smoke-tests bin/windex end to end: spawn it once per subcommand against
# tests/index_fixture.w (and the existing alias-import fixture), parse the
# NDJSON it prints, and assert on the records.
import lib.lib
import lib.assert
import lib.process
import structures.string
import structures.json


int index_test_timeout_ms():
	return 30000


list[json_value*] index_test_parse_ndjson(char* text):
	list[json_value*] records = new list[json_value*]
	string_builder* line = string_new()
	int i = 0
	while (1):
		int c = text[i]
		if ((c == '\n') | (c == 0)):
			if (line.length > 0):
				json_value* record = json_parse(line.data)
				asserts(c"windex output line is valid json", record != 0)
				records.push(record)
			string_clear(line)
			if (c == 0):
				string_free(line)
				return records
		else if (c != '\r'):
			string_append_char(line, c)
		i = i + 1
	return records


list[json_value*] index_test_run(list[char*] args):
	char** argv = strv_new(args.length + 1)
	strv_set(argv, 0, c"./bin/windex")
	int i = 0
	while (i < args.length):
		strv_set(argv, i + 1, args[i])
		i = i + 1
	process_result* result = process_run(c"./bin/windex", argv, 0, 0, index_test_timeout_ms())
	free(cast(void*, argv))
	asserts(c"windex spawned", result != 0)
	asserts(c"windex exited cleanly", result.status == 0)
	list[json_value*] records = index_test_parse_ndjson(result.stdout_text)
	process_result_free(result)
	return records


list[char*] index_test_args(char* a, char* b, char* extra):
	list[char*] args = new list[char*]
	args.push(a)
	args.push(b)
	if (extra != 0):
		args.push(extra)
	return args


char* index_test_string(json_value* record, char* key):
	json_value* value = json_object_get(record, key)
	asserts(c"expected string field present", value != 0)
	return value.string_value


int index_test_int(json_value* record, char* key):
	json_value* value = json_object_get(record, key)
	asserts(c"expected int field present", value != 0)
	return value.int_value


int main(int argc, int argv):
	# symbol: find_symbol on a plain helper function
	list[json_value*] symbol_records = index_test_run(index_test_args(c"symbol", c"index_fixture_helper", c"tests/index_fixture.w"))
	assert_equal(1, symbol_records.length)
	assert_strings_equal(c"function", index_test_string(symbol_records[0], c"kind"))
	assert_strings_equal(c"int", index_test_string(symbol_records[0], c"type"))
	assert_equal(7, index_test_int(symbol_records[0], c"line"))
	assert_equal(5, index_test_int(symbol_records[0], c"column"))

	# struct: get_struct_fields
	list[json_value*] struct_records = index_test_run(index_test_args(c"struct", c"index_fixture_point", c"tests/index_fixture.w"))
	assert_equal(2, struct_records.length)
	assert_strings_equal(c"x", index_test_string(struct_records[0], c"field"))
	assert_equal(0, index_test_int(struct_records[0], c"offset"))
	assert_strings_equal(c"y", index_test_string(struct_records[1], c"field"))
	assert_equal(4, index_test_int(struct_records[1], c"offset"))

	# references: one declaration plus two call sites
	list[json_value*] reference_records = index_test_run(index_test_args(c"references", c"index_fixture_helper", c"tests/index_fixture.w"))
	assert_equal(3, reference_records.length)
	int declarations = 0
	int i = 0
	while (i < reference_records.length):
		if (index_test_int(reference_records[i], c"is_declaration")):
			declarations = declarations + 1
		i = i + 1
	assert_equal(1, declarations)

	# callers / callees agree on the same two call sites
	list[json_value*] caller_records = index_test_run(index_test_args(c"callers", c"index_fixture_helper", c"tests/index_fixture.w"))
	assert_equal(2, caller_records.length)
	assert_strings_equal(c"index_fixture_caller", index_test_string(caller_records[0], c"caller"))
	assert_strings_equal(c"index_fixture_caller", index_test_string(caller_records[1], c"caller"))

	list[json_value*] callee_records = index_test_run(index_test_args(c"callees", c"index_fixture_caller", c"tests/index_fixture.w"))
	assert_equal(2, callee_records.length)
	assert_strings_equal(c"index_fixture_helper", index_test_string(callee_records[0], c"callee"))
	assert_strings_equal(c"index_fixture_helper", index_test_string(callee_records[1], c"callee"))

	# imports: a plain import ...
	list[json_value*] import_records = index_test_run(index_test_args(c"imports", c"tests/index_fixture.w", 0))
	assert_equal(1, import_records.length)
	assert_strings_equal(c"lib.lib", index_test_string(import_records[0], c"module"))
	json_value* alias_value = json_object_get(import_records[0], c"alias")
	assert_equal(json_type_null(), alias_value.type)

	# ... and an aliased one
	list[json_value*] alias_import_records = index_test_run(index_test_args(c"imports", c"tests/import_alias_warning_fixture.w", 0))
	assert_equal(1, alias_import_records.length)
	assert_strings_equal(c"tests.subfolder", index_test_string(alias_import_records[0], c"module"))
	assert_strings_equal(c"sub", index_test_string(alias_import_records[0], c"alias"))
	assert_equal(4, index_test_int(alias_import_records[0], c"line"))

	println2(c"index test OK")
	return 0
