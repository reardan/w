# wbuild: x64
import lib.testing
import lib.format
import lib.generator

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

The second half hardens the emission's stack discipline: operator uses
in while conditions (millions of iterations without drift), on the
short-circuit and ternary skip paths, as compound-assignment right
sides and W-variadic call elements, scalar-left dispatch (float and
int left operands), map / fixed-array / pointer element positions,
defer bodies, generator yields, switch scrutinees, call results as
left operands, method suffixes on operator results, and 'operator'
staying an ordinary identifier outside definition position.
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


# Scalar-left dispatch: the same '*' spelling with the struct on the
# RIGHT. On the x64 twin '0.5 * v' exercises the left-side
# float64->float mangling fold (x64 float literals are float64).
vec3 operator*(float s, vec3 a):
	return vec3(s * a.x, s * a.y, s * a.z)


vec3 operator*(int s, vec3 a):
	return vec3(s * a.x, s * a.y, s * a.z)


# Dot product with an int result, for element positions that want int
# expressions (W-variadic arguments, switch scrutinees).
int operator*(ivec2 a, ivec2 b):
	return a.x * b.x + a.y * b.y


int oo_total(int... xs):
	int total = 0
	for int x in xs:
		total = total + x
	return total


vec3 oo_make_v():
	return vec3(10.0, 20.0, 30.0)


# Method-call sugar target: '(a + b).len2()' lowers to
# vec3_len2(&buffer) (docs/projects/struct_methods.md).
float vec3_len2(vec3* self):
	return self.x * self.x + self.y * self.y + self.z * self.z


int oo_defer_x


# Deferred statements re-parse and re-emit at every exit
# (tests/defer_test.w), so the operator use in the defer body runs
# through the same lowering as straight-line code.
void oo_defer_capture():
	vec3 a = vec3(1.0, 2.0, 3.0)
	vec3 b = vec3(4.0, 5.0, 6.0)
	defer oo_defer_x = cast(int, (a + b).x)
	oo_defer_x = 0


# Generator whose yields run an operator use on dereferenced struct
# POINTER parameters: (*pa) * (*pb) is the vec3 dot product.
generator int oo_dots(vec3* pa, vec3* pb, int n):
	int i = 0
	while (i < n):
		yield cast(int, (*pa) * (*pb))
		i = i + 1


# 'operator' is a keyword only in definition-name position: this
# declares an ordinary global named operator.
int operator


void oo_set_operator_global():
	operator = 41
	operator = operator + 1


# 3,000,000 iterations of a scalar-result operator use in a while
# condition: any per-iteration stack drift from the operator's call
# emission would blow the stack long before the counter reaches the
# bound. dot(a, a) = 1.0, so the condition never flips on its own.
void test_while_condition_scalar():
	vec3 a = vec3(1.0, 0.0, 0.0)
	int i = 0
	while ((a * a) < 2.0):
		i = i + 1
		if (i >= 3000000):
			break
	assert_equal(3000000, i)
	# Terminating twin: the loop must also EXIT through the operator
	# condition at a known count. g grows by (1,0,0) per pass, so
	# dot(g, g) walks 0, 1, 4, 9 and crosses 6.5 after 3 passes.
	vec3 g = vec3(0.0, 0.0, 0.0)
	vec3 step = vec3(1.0, 0.0, 0.0)
	int n = 0
	while ((g * g) < 6.5):
		g = g + step
		n = n + 1
	assert_equal(3, n)


# Struct-valued operator result consumed by a field read in the while
# condition. b.x walks 0.5, 1.5, 2.5, 3.5, 4.5; (a + b).x crosses 5.0
# after 4 passes.
void test_while_condition_struct():
	vec3 a = vec3(1.0, 0.0, 0.0)
	vec3 b = vec3(0.5, 0.0, 0.0)
	vec3 step = vec3(1.0, 0.0, 0.0)
	int n = 0
	while ((a + b).x < 5.0):
		b = b + step
		n = n + 1
	assert_equal(4, n)


# Short-circuit operands: the operator call on the right of '&&'/'||'
# must not run when the left side decides, and the skipped emission
# must not disturb neighboring locals (canaries surround the flags).
void test_short_circuit():
	vec3 a = vec3(1.0, 2.0, 3.0)
	int canary_lo = 111
	int flag = 0
	int hit = 0
	int canary_hi = 222
	if (flag && ((a * a) > 1.0)):
		hit = 1
	assert_equal(0, hit)
	assert_equal(111, canary_lo)
	assert_equal(222, canary_hi)
	int taken = 0
	if (flag == 0 || ((a * a) > 100.0)):
		taken = 1
	assert_equal(1, taken)
	assert_equal(111, canary_lo)
	assert_equal(222, canary_hi)
	# Evaluated twin: the right side does run when the left cannot
	# decide. dot(a, a) = 14.
	int both = 0
	if (1 && ((a * a) > 10.0)):
		both = 1
	assert_equal(1, both)


# Scalar-result operator uses inside ternary arms, both selected and
# skipped. (Struct-valued ternary arms are a known operator-unrelated
# gap; see docs/projects/operator_overloading.md.)
void test_ternary_scalar():
	vec3 a = vec3(1.0, 2.0, 3.0)
	vec3 b = vec3(4.0, 5.0, 6.0)
	int c = 0
	float r = c ? (a * b) : 0.5
	assert_near(0.5, r)
	c = 1
	r = c ? (a * b) : 0.5
	assert_near(32.0, r)


# Operator expression as a compound assignment's right side (the LHS
# stays scalar; struct-LHS compound assignment is staged separately,
# docs/projects/operator_overloading.md).
void test_compound_assign_rhs():
	vec3 a = vec3(1.0, 2.0, 3.0)
	vec3 b = vec3(4.0, 5.0, 6.0)
	float acc = 3.0
	acc = acc + 0.0
	acc += a * b
	assert_near(35.0, acc)


# Operator results as W-variadic call elements: the packing loop walks
# the argument stack, so each element must be exactly one word.
# dot(p, q) = 23, dot(p, p) = 13, plus 100 = 136.
void test_variadic_element_args():
	ivec2 p = ivec2(2, 3)
	ivec2 q = ivec2(4, 5)
	assert_equal(136, oo_total(p * q, p * p, 100))


void test_scalar_left_dispatch():
	vec3 v = vec3(2.0, 4.0, 6.0)
	vec3 h = 0.5 * v
	assert_near(1.0, h.x)
	assert_near(2.0, h.y)
	assert_near(3.0, h.z)
	vec3 d = 2 * v
	assert_near(4.0, d.x)
	assert_near(8.0, d.y)
	assert_near(12.0, d.z)


# Operator operands and results flowing through container element and
# pointer positions: map values, fixed-array elements, pointer stores
# and dereferences.
void test_container_positions():
	vec3 a = vec3(1.0, 2.0, 3.0)
	vec3 b = vec3(4.0, 5.0, 6.0)
	map[int, vec3] m = new map[int, vec3]
	m[1] = a
	vec3 r = m[1] + b
	assert_near(5.0, r.x)
	assert_near(7.0, r.y)
	assert_near(9.0, r.z)
	m[2] = a + b
	assert_near(5.0, m[2].x)
	assert_near(9.0, m[2].z)
	vec3[3] arr
	arr[0] = a
	vec3 e = arr[0] + b
	assert_near(5.0, e.x)
	assert_near(9.0, e.z)
	arr[1] = a + b
	assert_near(7.0, arr[1].y)
	vec3 v = a
	vec3* p = &v
	*p = a + b
	assert_near(5.0, v.x)
	assert_near(9.0, v.z)
	vec3 t = *p + a
	assert_near(6.0, t.x)
	assert_near(12.0, t.z)


# Operator uses inside defer bodies, generator yields (struct pointer
# parameters dereferenced into value operands) and switch scrutinees.
void test_defer_generator_switch():
	oo_defer_capture()
	assert_equal(5, oo_defer_x)
	vec3 u = vec3(1.0, 2.0, 3.0)
	vec3 w = vec3(4.0, 5.0, 6.0)
	int sum = 0
	for int d in oo_dots(&u, &w, 3):
		sum = sum + d
	assert_equal(96, sum)
	ivec2 p = ivec2(7, 9)
	ivec2 q = ivec2(4, 5)
	int label = 0
	switch ((p % q).x):
		case 3:
			label = 30
		default:
			label = 99
	assert_equal(30, label)


# Call results feed operators as the LEFT operand, and operator
# results take method-call suffixes like any struct-by-value result
# (docs/projects/struct_methods.md). len2(5, 7, 9) = 155.
void test_result_chaining_postfix():
	vec3 a = vec3(1.0, 2.0, 3.0)
	vec3 b = vec3(4.0, 5.0, 6.0)
	vec3 r = oo_make_v() + a
	assert_near(11.0, r.x)
	assert_near(22.0, r.y)
	assert_near(33.0, r.z)
	assert_near(155.0, (a + b).len2())


# The contextual keyword never reserves the name: the global declared
# above and a local both named 'operator' stay ordinary identifiers in
# assignment and arithmetic position.
void test_operator_identifier():
	oo_set_operator_global()
	assert_equal(42, operator)
	int operator = 7
	assert_equal(21, operator * 3)
	assert_equal(42, operator + 35)
