/*
graphics.math: glm-inspired linear algebra for the graphics stack.

Pure W, no shared-library dependency: sqrt, abs, floor, mod and the
float bit casts come from lib.fmath (thin gfx_ aliases below keep the
local naming convention), and sin/cos/tan are implemented here with
minimax-style polynomials, so programs that only need the math stay
statically linked and work on both the x86 and x64 targets.

Conventions follow glm and OpenGL:
- float32 components
- column-major mat4: element (row, col) lives at m[col * 4 + row]
- right-handed view space, clip space z in [-1, 1] (mat4_perspective /
  mat4_ortho match glm's default GLM_CLIP_CONTROL_RH_NO)
- free functions prefixed by the type they operate on (vec3_add,
  mat4_mul, quat_rotate_vec3, ...); scalar helpers use a gfx_ prefix

Design notes and the 2D/UI + 3D roadmap: docs/projects/graphics.md
*/
import lib.lib
import lib.fmath


struct vec2:
	float32 x
	float32 y


struct vec3:
	float32 x
	float32 y
	float32 z


struct vec4:
	float32 x
	float32 y
	float32 z
	float32 w


# Column-major 4x4 matrix, matching OpenGL and glm: column c, row r is
# m[c * 4 + r], and translation lives in m[12..14].
struct mat4:
	float32[16] m


# Rotation quaternion (x, y, z, w) with w the scalar part, like glm.
struct quat:
	float32 x
	float32 y
	float32 z
	float32 w


########################### scalar helpers ###########################

float32 gfx_pi():
	return 3.14159265

float32 gfx_two_pi():
	return 6.28318531

float32 gfx_half_pi():
	return 1.57079633


float32 radians(float32 degrees_value):
	return degrees_value * 0.0174532925


float32 degrees(float32 radians_value):
	return radians_value * 57.2957795


float32 gfx_abs(float32 x):
	return fabs(x)


float32 gfx_min(float32 a, float32 b):
	if (a < b):
		return a
	return b


float32 gfx_max(float32 a, float32 b):
	if (a > b):
		return a
	return b


float32 gfx_clamp(float32 x, float32 low, float32 high):
	if (x < low):
		return low
	if (x > high):
		return high
	return x


# Linear blend, glm's mix(): a at t == 0, b at t == 1.
float32 gfx_lerp(float32 a, float32 b, float32 t):
	return a + (b - a) * t


float32 gfx_floor(float32 x):
	return ffloor(x)


# glm mod(): x - floor(x / y) * y, result has the sign of y.
float32 gfx_mod(float32 x, float32 y):
	return fmod2(x, y)


int gfx_float_bits(float32 f):
	return float_bits(f)


float32 gfx_float_from_bits(int bits):
	return float_from_bits(bits)


float32 gfx_sqrt(float32 x):
	return fsqrt(x)


float32 gfx_inverse_sqrt(float32 x):
	return 1.0 / gfx_sqrt(x)


# Taylor sine on [-pi/2, pi/2]; the truncation error of the x^11 term
# is below float32 resolution there.
float32 gfx_sin_poly(float32 r):
	float32 r2 = r * r
	float32 result = r
	float32 term = r * r2 * (0.0 - 0.16666667)
	result = result + term
	term = term * r2 * (0.0 - 0.05)              # -1/20: 3!/5! with sign flip
	result = result + term
	term = term * r2 * (0.0 - 0.023809524)       # -1/42
	result = result + term
	term = term * r2 * (0.0 - 0.013888889)       # -1/72
	result = result + term
	term = term * r2 * (0.0 - 0.0090909091)      # -1/110
	result = result + term
	return result


float32 gfx_sin(float32 x):
	# Reduce to [-pi, pi]
	float32 r = gfx_mod(x + gfx_pi(), gfx_two_pi()) - gfx_pi()
	# Fold into [-pi/2, pi/2] where the polynomial converges fast
	if (r > gfx_half_pi()):
		r = gfx_pi() - r
	else if (r < 0.0 - gfx_half_pi()):
		r = (0.0 - gfx_pi()) - r
	return gfx_sin_poly(r)


float32 gfx_cos(float32 x):
	return gfx_sin(x + gfx_half_pi())


float32 gfx_tan(float32 x):
	return gfx_sin(x) / gfx_cos(x)


############################### vec2 #################################

vec2 vec2_new(float32 x, float32 y):
	vec2 v
	v.x = x
	v.y = y
	return v


vec2 vec2_add(vec2 a, vec2 b):
	return vec2_new(a.x + b.x, a.y + b.y)


vec2 vec2_sub(vec2 a, vec2 b):
	return vec2_new(a.x - b.x, a.y - b.y)


vec2 vec2_scale(vec2 a, float32 s):
	return vec2_new(a.x * s, a.y * s)


vec2 vec2_mul(vec2 a, vec2 b):
	return vec2_new(a.x * b.x, a.y * b.y)


float32 vec2_dot(vec2 a, vec2 b):
	return a.x * b.x + a.y * b.y


float32 vec2_length(vec2 a):
	return gfx_sqrt(vec2_dot(a, a))


vec2 vec2_normalize(vec2 a):
	float32 len = vec2_length(a)
	if (len == 0.0):
		return vec2_new(0.0, 0.0)
	return vec2_scale(a, 1.0 / len)


vec2 vec2_lerp(vec2 a, vec2 b, float32 t):
	return vec2_new(gfx_lerp(a.x, b.x, t), gfx_lerp(a.y, b.y, t))


############################### vec3 #################################

vec3 vec3_new(float32 x, float32 y, float32 z):
	vec3 v
	v.x = x
	v.y = y
	v.z = z
	return v


vec3 vec3_add(vec3 a, vec3 b):
	return vec3_new(a.x + b.x, a.y + b.y, a.z + b.z)


vec3 vec3_sub(vec3 a, vec3 b):
	return vec3_new(a.x - b.x, a.y - b.y, a.z - b.z)


vec3 vec3_scale(vec3 a, float32 s):
	return vec3_new(a.x * s, a.y * s, a.z * s)


vec3 vec3_mul(vec3 a, vec3 b):
	return vec3_new(a.x * b.x, a.y * b.y, a.z * b.z)


float32 vec3_dot(vec3 a, vec3 b):
	return a.x * b.x + a.y * b.y + a.z * b.z


vec3 vec3_cross(vec3 a, vec3 b):
	vec3 r
	r.x = a.y * b.z - a.z * b.y
	r.y = a.z * b.x - a.x * b.z
	r.z = a.x * b.y - a.y * b.x
	return r


float32 vec3_length(vec3 a):
	return gfx_sqrt(vec3_dot(a, a))


vec3 vec3_normalize(vec3 a):
	float32 len = vec3_length(a)
	if (len == 0.0):
		return vec3_new(0.0, 0.0, 0.0)
	return vec3_scale(a, 1.0 / len)


vec3 vec3_lerp(vec3 a, vec3 b, float32 t):
	return vec3_new(gfx_lerp(a.x, b.x, t), gfx_lerp(a.y, b.y, t), gfx_lerp(a.z, b.z, t))


# Reflect incident vector i about unit normal n (glm reflect).
vec3 vec3_reflect(vec3 i, vec3 n):
	return vec3_sub(i, vec3_scale(n, 2.0 * vec3_dot(n, i)))


############################### vec4 #################################

vec4 vec4_new(float32 x, float32 y, float32 z, float32 w):
	vec4 v
	v.x = x
	v.y = y
	v.z = z
	v.w = w
	return v


vec4 vec4_from_vec3(vec3 a, float32 w):
	return vec4_new(a.x, a.y, a.z, w)


vec4 vec4_add(vec4 a, vec4 b):
	return vec4_new(a.x + b.x, a.y + b.y, a.z + b.z, a.w + b.w)


vec4 vec4_sub(vec4 a, vec4 b):
	return vec4_new(a.x - b.x, a.y - b.y, a.z - b.z, a.w - b.w)


vec4 vec4_scale(vec4 a, float32 s):
	return vec4_new(a.x * s, a.y * s, a.z * s, a.w * s)


float32 vec4_dot(vec4 a, vec4 b):
	return a.x * b.x + a.y * b.y + a.z * b.z + a.w * b.w


float32 vec4_length(vec4 a):
	return gfx_sqrt(vec4_dot(a, a))


vec4 vec4_normalize(vec4 a):
	float32 len = vec4_length(a)
	if (len == 0.0):
		return vec4_new(0.0, 0.0, 0.0, 0.0)
	return vec4_scale(a, 1.0 / len)


############################### mat4 #################################

mat4 mat4_zero():
	mat4 r
	int i = 0
	while (i < 16):
		r.m[i] = 0.0
		i += 1
	return r


mat4 mat4_identity():
	mat4 r = mat4_zero()
	r.m[0] = 1.0
	r.m[5] = 1.0
	r.m[10] = 1.0
	r.m[15] = 1.0
	return r


float32 mat4_get(mat4 a, int row, int col):
	return a.m[col * 4 + row]


mat4 mat4_transpose(mat4 a):
	mat4 r
	int col = 0
	while (col < 4):
		int row = 0
		while (row < 4):
			r.m[col * 4 + row] = a.m[row * 4 + col]
			row += 1
		col += 1
	return r


mat4 mat4_mul(mat4 a, mat4 b):
	mat4 r
	int col = 0
	while (col < 4):
		int row = 0
		while (row < 4):
			float32 sum = 0.0
			int k = 0
			while (k < 4):
				sum = sum + a.m[k * 4 + row] * b.m[col * 4 + k]
				k += 1
			r.m[col * 4 + row] = sum
			row += 1
		col += 1
	return r


vec4 mat4_mul_vec4(mat4 a, vec4 v):
	vec4 r
	r.x = a.m[0] * v.x + a.m[4] * v.y + a.m[8] * v.z + a.m[12] * v.w
	r.y = a.m[1] * v.x + a.m[5] * v.y + a.m[9] * v.z + a.m[13] * v.w
	r.z = a.m[2] * v.x + a.m[6] * v.y + a.m[10] * v.z + a.m[14] * v.w
	r.w = a.m[3] * v.x + a.m[7] * v.y + a.m[11] * v.z + a.m[15] * v.w
	return r


# Transform a point (w = 1); the translation column applies.
vec3 mat4_mul_point(mat4 a, vec3 p):
	vec4 r = mat4_mul_vec4(a, vec4_from_vec3(p, 1.0))
	return vec3_new(r.x, r.y, r.z)


# glm::translate(m, v): post-multiply m by a translation matrix.
mat4 mat4_translate(mat4 a, vec3 v):
	mat4 r = a
	int row = 0
	while (row < 4):
		r.m[12 + row] = a.m[row] * v.x + a.m[4 + row] * v.y + a.m[8 + row] * v.z + a.m[12 + row]
		row += 1
	return r


# glm::scale(m, v): post-multiply m by a nonuniform scale.
mat4 mat4_scale(mat4 a, vec3 v):
	mat4 r = a
	int row = 0
	while (row < 4):
		r.m[row] = a.m[row] * v.x
		r.m[4 + row] = a.m[4 + row] * v.y
		r.m[8 + row] = a.m[8 + row] * v.z
		row += 1
	return r


# Rotation matrix for angle (radians) about a unit axis (glm::rotate
# applied to the identity).
mat4 mat4_rotation(float32 angle, vec3 axis):
	vec3 a = vec3_normalize(axis)
	float32 c = gfx_cos(angle)
	float32 s = gfx_sin(angle)
	float32 t = 1.0 - c
	mat4 r = mat4_identity()
	r.m[0] = c + a.x * a.x * t
	r.m[1] = a.y * a.x * t + a.z * s
	r.m[2] = a.z * a.x * t - a.y * s
	r.m[4] = a.x * a.y * t - a.z * s
	r.m[5] = c + a.y * a.y * t
	r.m[6] = a.z * a.y * t + a.x * s
	r.m[8] = a.x * a.z * t + a.y * s
	r.m[9] = a.y * a.z * t - a.x * s
	r.m[10] = c + a.z * a.z * t
	return r


# glm::rotate(m, angle, axis): post-multiply by the rotation.
mat4 mat4_rotate(mat4 a, float32 angle, vec3 axis):
	return mat4_mul(a, mat4_rotation(angle, axis))


# Right-handed perspective projection with clip z in [-1, 1]
# (glm::perspective default). fovy is the vertical field of view in
# radians.
mat4 mat4_perspective(float32 fovy, float32 aspect, float32 near, float32 far):
	float32 tan_half = gfx_tan(fovy * 0.5)
	mat4 r = mat4_zero()
	r.m[0] = 1.0 / (aspect * tan_half)
	r.m[5] = 1.0 / tan_half
	r.m[10] = (0.0 - (far + near)) / (far - near)
	r.m[11] = 0.0 - 1.0
	r.m[14] = (0.0 - (2.0 * far * near)) / (far - near)
	return r


# Right-handed orthographic projection with clip z in [-1, 1]
# (glm::ortho).
mat4 mat4_ortho(float32 left, float32 right, float32 bottom, float32 top, float32 near, float32 far):
	mat4 r = mat4_identity()
	r.m[0] = 2.0 / (right - left)
	r.m[5] = 2.0 / (top - bottom)
	r.m[10] = (0.0 - 2.0) / (far - near)
	r.m[12] = (0.0 - (right + left)) / (right - left)
	r.m[13] = (0.0 - (top + bottom)) / (top - bottom)
	r.m[14] = (0.0 - (far + near)) / (far - near)
	return r


# Right-handed view matrix (glm::lookAt).
mat4 mat4_look_at(vec3 eye, vec3 center, vec3 up):
	vec3 f = vec3_normalize(vec3_sub(center, eye))
	vec3 s = vec3_normalize(vec3_cross(f, up))
	vec3 u = vec3_cross(s, f)
	mat4 r = mat4_identity()
	r.m[0] = s.x
	r.m[4] = s.y
	r.m[8] = s.z
	r.m[1] = u.x
	r.m[5] = u.y
	r.m[9] = u.z
	r.m[2] = 0.0 - f.x
	r.m[6] = 0.0 - f.y
	r.m[10] = 0.0 - f.z
	r.m[12] = 0.0 - vec3_dot(s, eye)
	r.m[13] = 0.0 - vec3_dot(u, eye)
	r.m[14] = vec3_dot(f, eye)
	return r


############################### quat #################################

quat quat_new(float32 x, float32 y, float32 z, float32 w):
	quat q
	q.x = x
	q.y = y
	q.z = z
	q.w = w
	return q


quat quat_identity():
	return quat_new(0.0, 0.0, 0.0, 1.0)


quat quat_from_axis_angle(vec3 axis, float32 angle):
	vec3 a = vec3_normalize(axis)
	float32 half = angle * 0.5
	float32 s = gfx_sin(half)
	return quat_new(a.x * s, a.y * s, a.z * s, gfx_cos(half))


float32 quat_length(quat q):
	return gfx_sqrt(q.x * q.x + q.y * q.y + q.z * q.z + q.w * q.w)


quat quat_normalize(quat q):
	float32 len = quat_length(q)
	if (len == 0.0):
		return quat_identity()
	float32 inv = 1.0 / len
	return quat_new(q.x * inv, q.y * inv, q.z * inv, q.w * inv)


quat quat_mul(quat a, quat b):
	quat r
	r.w = a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z
	r.x = a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y
	r.y = a.w * b.y + a.y * b.w + a.z * b.x - a.x * b.z
	r.z = a.w * b.z + a.z * b.w + a.x * b.y - a.y * b.x
	return r


quat quat_conjugate(quat q):
	return quat_new(0.0 - q.x, 0.0 - q.y, 0.0 - q.z, q.w)


vec3 quat_rotate_vec3(quat q, vec3 v):
	# v' = q * (v, 0) * conj(q), expanded to avoid the temporaries:
	# t = 2 * cross(q.xyz, v); v' = v + q.w * t + cross(q.xyz, t)
	vec3 qv = vec3_new(q.x, q.y, q.z)
	vec3 t = vec3_scale(vec3_cross(qv, v), 2.0)
	return vec3_add(vec3_add(v, vec3_scale(t, q.w)), vec3_cross(qv, t))


mat4 quat_to_mat4(quat q):
	mat4 r = mat4_identity()
	float32 xx = q.x * q.x
	float32 yy = q.y * q.y
	float32 zz = q.z * q.z
	float32 xy = q.x * q.y
	float32 xz = q.x * q.z
	float32 yz = q.y * q.z
	float32 wx = q.w * q.x
	float32 wy = q.w * q.y
	float32 wz = q.w * q.z
	r.m[0] = 1.0 - 2.0 * (yy + zz)
	r.m[1] = 2.0 * (xy + wz)
	r.m[2] = 2.0 * (xz - wy)
	r.m[4] = 2.0 * (xy - wz)
	r.m[5] = 1.0 - 2.0 * (xx + zz)
	r.m[6] = 2.0 * (yz + wx)
	r.m[8] = 2.0 * (xz + wy)
	r.m[9] = 2.0 * (yz - wx)
	r.m[10] = 1.0 - 2.0 * (xx + yy)
	return r
