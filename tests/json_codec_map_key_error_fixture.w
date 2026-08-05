# expect_fail
# expect_stderr: to_json/from_json map fields need char* or string keys: 'map[int, int]'
# JSON object keys are strings, so a map field's key type must be char*
# or string; any other key type is rejected at compile time
# (docs/projects/protocol_ergonomics.md).
import structures.json


struct jc_err_int_keys:
	map[int, int] counts


int main():
	jc_err_int_keys s
	json_value* v = to_json(s)
	return 0
