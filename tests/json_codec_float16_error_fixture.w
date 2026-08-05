# expect_fail
# expect_stderr: unsupported to_json/from_json field type: 'float16'
# Codec float fields are float32 only: structures/json.w numbers are
# float32, and float16 is a storage-only type (docs/projects/float.md).
# float64 fields are rejected the same way, but that type is x64-only so
# the fixture pins the message with float16, which both targets accept
# in a struct declaration.
import structures.json


struct jc_err_half:
	float16 h


int main():
	jc_err_half s
	json_value* v = to_json(s)
	return 0
