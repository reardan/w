# wbuild: x64
import lib.testing
import lib.format

/*
Operator overloading v1 (docs/projects/operator_overloading.md, issue
#104): user definitions of the binary arithmetic operators + - * / %
for struct values. Covers every overloadable spelling on struct
operands, mixed struct-by-float operands (same spelling, distinct
operand types), struct-by-value results chained into further operator
uses, precedence against the built-in ladder, operator expressions in
call-argument / return / condition position, forward declarations, and
that struct POINTER operands keep today's raw byte-addressed pointer
arithmetic instead of consulting overloads.
*/


struct vec3:
	float x
	float y
	float z


struct vec4:
	float x
	float y
	float z
	float w


struct mat4:
	vec4 c0
	vec4 c1
	vec4 c2
	vec4 c3


struct ivec2:
	int x
	int y


float oo_abs(float f):
	if (f < 0.0):
		return 0.0 - f
	return f


# Same shape as graphics/math_test.w's assert_near: exact float bit
# patterns differ between the 32-bit (float32) and x64 (float64)
# builds, so compare within an epsilon instead.
void assert_near(float want, float got):
	if (oo_abs(want - got) > 0.0001):
		print2(c"Assertion failed. wanted float(")
		print2(ftoa(want))
		print2(c") got float(")
		print2(ftoa(got))
		println2(c")")
		exit(1)


# Forward declaration: the definition follows further down, after
# operator+ (prototypes follow the normal define-or-declare-before-use
# rules, docs/projects/operator_overloading.md).
vec3 operator-(vec3 a, vec3 b);


vec3 operator+(vec3 a, vec3 b):
	return vec3(a.x + b.x, a.y + b.y, a.z + b.z)


vec3 operator-(vec3 a, vec3 b):
	return vec3(a.x - b.x, a.y - b.y, a.z - b.z)


# Dot product: struct operands, scalar result.
float operator*(vec3 a, vec3 b):
	return a.x * b.x + a.y * b.y + a.z * b.z


# Scaling: the same '*' spelling as the dot product above, resolved by
# the distinct operand types (vec3, float).
vec3 operator*(vec3 a, float s):
	return vec3(a.x * s, a.y * s, a.z * s)


vec3 operator/(vec3 a, float s):
	return vec3(a.x / s, a.y / s, a.z / s)


vec4 operator*(vec4 v, float s):
	return vec4(v.x * s, v.y * s, v.z * s, v.w * s)


# Scales column-wise via the vec4 operator: a struct-value operator use
# nested inside another operator's body.
mat4 operator*(mat4 m, float s):
	mat4 r
	r.c0 = m.c0 * s
	r.c1 = m.c1 * s
	r.c2 = m.c2 * s
	r.c3 = m.c3 * s
	return r


# '%' is not float-legal, so the modulo overload gets int fields.
ivec2 operator%(ivec2 a, ivec2 b):
	return ivec2(a.x % b.x, a.y % b.y)


# Operator use in return position (struct-by-value result).
vec3 oo_sum(vec3 a, vec3 b):
	return a + b


# Operator use in return position (scalar result).
float oo_dot(vec3 a, vec3 b):
	return a * b


void test_vec3_add():
	vec3 a = vec3(1.0, 2.0, 3.0)
	vec3 b = vec3(4.0, 5.0, 6.0)
	vec3 sum = a + b
	assert_near(5.0, sum.x)
	assert_near(7.0, sum.y)
	assert_near(9.0, sum.z)


# operator- is forward-declared near the top and defined later; this
# use comes after the definition.
void test_vec3_sub():
	vec3 a = vec3(4.0, 6.0, 8.0)
	vec3 b = vec3(1.0, 2.0, 3.0)
	vec3 diff = a - b
	assert_near(3.0, diff.x)
	assert_near(4.0, diff.y)
	assert_near(5.0, diff.z)


void test_vec3_dot():
	vec3 a = vec3(1.0, 2.0, 3.0)
	vec3 b = vec3(4.0, 5.0, 6.0)
	float dot = a * b
	assert_near(32.0, dot)


void test_ivec2_mod():
	ivec2 a = ivec2(7, 9)
	ivec2 b = ivec2(4, 5)
	ivec2 r = a % b
	assert_equal(3, r.x)
	assert_equal(4, r.y)


# Mixed struct-by-float-literal operands: exercises the float64
# fallback on the x64 twin, where 'float' and the literals are 64-bit.
void test_vec3_scale_by_float_literal():
	vec3 v = vec3(2.0, 4.0, 6.0)
	vec3 half = v * 0.5
	assert_near(1.0, half.x)
	assert_near(2.0, half.y)
	assert_near(3.0, half.z)


void test_vec3_divide_by_float_literal():
	vec3 v = vec3(2.0, 4.0, 6.0)
	vec3 halved = v / 2.0
	assert_near(1.0, halved.x)
	assert_near(2.0, halved.y)
	assert_near(3.0, halved.z)


void test_vec4_scale():
	vec4 v = vec4(1.0, 2.0, 3.0, 4.0)
	vec4 s = v * 0.5
	assert_near(0.5, s.x)
	assert_near(1.0, s.y)
	assert_near(1.5, s.z)
	assert_near(2.0, s.w)


void test_mat4_scale():
	mat4 m
	m.c0 = vec4(1.0, 2.0, 3.0, 4.0)
	m.c1 = vec4(5.0, 6.0, 7.0, 8.0)
	m.c2 = vec4(9.0, 10.0, 11.0, 12.0)
	m.c3 = vec4(13.0, 14.0, 15.0, 16.0)
	mat4 h = m * 0.5
	assert_near(0.5, h.c0.x)
	assert_near(2.0, h.c0.w)
	assert_near(3.0, h.c1.y)
	assert_near(5.5, h.c2.z)
	assert_near(6.5, h.c3.x)
	assert_near(8.0, h.c3.w)


# '*' keeps binding tighter than '+': a + b * 0.5 == a + (b * 0.5).
void test_precedence_mul_binds_tighter():
	vec3 a = vec3(1.0, 2.0, 3.0)
	vec3 b = vec3(4.0, 6.0, 8.0)
	vec3 n = a + b * 0.5
	assert_near(3.0, n.x)
	assert_near(5.0, n.y)
	assert_near(7.0, n.z)
	vec3 explicit = a + (b * 0.5)
	assert_near(explicit.x, n.x)
	assert_near(explicit.y, n.y)
	assert_near(explicit.z, n.z)


void test_chained_struct_results():
	vec3 a = vec3(1.0, 2.0, 3.0)
	vec3 b = vec3(4.0, 5.0, 6.0)
	vec3 c = vec3(0.5, 0.25, 0.125)
	vec3 doubled = (a + b) * 2.0
	assert_near(10.0, doubled.x)
	assert_near(14.0, doubled.y)
	assert_near(18.0, doubled.z)
	vec3 triple = a + b + c
	assert_near(5.5, triple.x)
	assert_near(7.25, triple.y)
	assert_near(9.125, triple.z)


# Dot of sums: two struct-by-value operator results feeding the
# scalar-result overload. (5, 7, 9) . (1, 0.5, 0.25) = 10.75.
void test_dot_of_sums():
	vec3 a = vec3(1.0, 2.0, 3.0)
	vec3 b = vec3(4.0, 5.0, 6.0)
	vec3 c = vec3(0.5, 0.25, 0.125)
	float dot = (a + b) * (c + c)
	assert_near(10.75, dot)


# Operator expressions in call-argument position and helper functions
# returning operator results. (5, 7, 9) . (0.5, 0.25, 0.125) = 5.375.
void test_operator_in_call_and_return_position():
	vec3 a = vec3(1.0, 2.0, 3.0)
	vec3 b = vec3(4.0, 5.0, 6.0)
	vec3 c = vec3(0.5, 0.25, 0.125)
	assert_near(5.375, oo_dot(a + b, c))
	vec3 s = oo_sum(a, b)
	assert_near(5.0, s.x)
	assert_near(7.0, s.y)
	assert_near(9.0, s.z)
	assert_near(32.0, oo_dot(a, b))


void test_operator_in_condition():
	vec3 a = vec3(1.0, 0.0, 0.0)
	vec3 b = vec3(2.0, 0.0, 0.0)
	int hit = 0
	if ((a * b) > 1.0):
		hit = 1
	assert_equal(1, hit)
	if ((a * a) > 1.5):
		hit = 2
	assert_equal(1, hit)


# Struct POINTER operands never consult overloads: pointer + int stays
# today's raw byte-addressed arithmetic (no element scaling in W, see
# tests/pointer_test.w), so the address moves by exactly 1 byte.
void test_struct_pointer_arithmetic_unchanged():
	vec3 v = vec3(1.0, 2.0, 3.0)
	vec3* p = &v
	int before = cast(int, p)
	vec3* q = p + 1
	int after = cast(int, q)
	assert_equal(1, after - before)
	assert_near(1.0, p.x)


void test_assign_operator_result():
	vec3 a = vec3(1.0, 2.0, 3.0)
	vec3 b = vec3(4.0, 5.0, 6.0)
	vec3 r = a + b
	assert_near(5.0, r.x)
	assert_near(7.0, r.y)
	assert_near(9.0, r.z)
	r = r - a
	assert_near(4.0, r.x)
	assert_near(5.0, r.y)
	assert_near(6.0, r.z)
