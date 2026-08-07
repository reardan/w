# wfixture: x64
# expect_fail
# expect_stderr: unsupported to_json/from_json field type: 'float16'
# The x64 twin of tests/json_codec_float16_error_fixture.w: now that
# float64 fields are accepted on 8-byte-word targets, this pins that
# the float-kind gate in grammar/json_builtin.w still rejects float16
# there (storage-only, docs/projects/float.md) instead of letting it
# slip through beside float64.
import structures.json


struct jc_err_half_64:
	float16 h


int main():
	jc_err_half_64 s
	json_value* v = to_json(s)
	return 0
