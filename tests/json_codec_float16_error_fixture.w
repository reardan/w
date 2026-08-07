# expect_fail
# expect_stderr: unsupported to_json/from_json field type: 'float16'
# Codec float fields are float32 (everywhere) or float64 (8-byte-word
# targets): float16 stays rejected as a storage-only type
# (docs/projects/float.md). This fixture pins the message on the
# default 32-bit target; tests/json_codec_float16_x64_error_fixture.w
# pins the same rejection under x64, and
# tests/json_codec_float64_x86_error_fixture.w the 32-bit float64
# type-gate error.
import structures.json


struct jc_err_half:
	float16 h


int main():
	jc_err_half s
	json_value* v = to_json(s)
	return 0
