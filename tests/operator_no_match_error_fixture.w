# expect_fail
# expect_stderr: no operator '+' for operands 'vec3', 'int'
# Arithmetic on a struct-value operand with no matching overload must
# be a compile error instead of the old silent word-sized address math
# (docs/projects/operator_overloading.md): resolution is an exact match
# on (spelling, left type, right type), only operator+(vec3, vec3) is
# defined, so 'v + 1' has no match.


struct vec3:
	float x
	float y
	float z


vec3 operator+(vec3 a, vec3 b):
	return vec3(a.x + b.x, a.y + b.y, a.z + b.z)


int main():
	vec3 v
	v.x = 1.0
	v.y = 2.0
	v.z = 3.0
	vec3 r = v + 1
	return 0
