# expect_fail
# expect_stderr: unsupported to_json/from_json field type: 'set[int]'
# JSON has no set shape, so set fields stay rejected at compile time
# even now that map fields encode (docs/projects/protocol_ergonomics.md).
import structures.json


struct jc_err_set:
	set[int] seen


int main():
	jc_err_set s
	json_value* v = to_json(s)
	return 0
