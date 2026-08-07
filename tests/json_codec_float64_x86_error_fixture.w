# expect_fail
# expect_stderr: float64 requires the x64 target
# Codec float64 fields are 8-byte-word-only: on the default 32-bit
# target the field's type is itself a compile error, so a float64
# codec struct never reaches the json_builtin descriptor walk there —
# the type gate is the 32-bit rejection this fixture pins (the x64
# acceptance side lives in tests/x64_json_float64_test.w).
import structures.json


struct jc_err_wide:
	float64 x


int main():
	jc_err_wide s
	json_value* v = to_json(s)
	return 0
