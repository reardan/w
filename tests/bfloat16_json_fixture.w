# expect_fail
# expect_stderr: unsupported to_json/from_json field type: 'bfloat16'
import structures.json


struct BrainJson:
	bfloat16 value


void main():
	BrainJson value
	value.value = 1.5
	to_json(value)
