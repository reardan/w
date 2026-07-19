# wbuild: name=graphics_math_test x64
import lib.testing
import lib.format
import graphics.math


# Shared tolerance for transcendental results: well within what float32
# rendering math needs, loose enough to absorb polynomial truncation.
void assert_near(float32 want, float32 got):
	if (gfx_abs(want - got) > 0.0001):
		print2(c"Assertion failed. wanted float(")
		print2(ftoa(want))
		print2(c") got float(")
		print2(ftoa(got))
		println2(c")")
		exit(1)


void assert_float_bits(int want, float32 got):
	assert_equal_hex(want, gfx_float_bits(got))


void test_scalar_helpers():
	assert_near(gfx_pi(), radians(180.0))
	assert_near(90.0, degrees(gfx_half_pi()))
	assert_float_bits(0x3fc00000, gfx_abs(-1.5))
	assert_float_bits(0x3fc00000, gfx_abs(1.5))
	assert_float_bits(0x3f800000, gfx_min(1.0, 2.0))
	assert_float_bits(0x40000000, gfx_max(1.0, 2.0))
	assert_float_bits(0x40000000, gfx_clamp(3.0, 0.0, 2.0))
	assert_float_bits(0x00000000, gfx_clamp(-1.0, 0.0, 2.0))
	assert_float_bits(0x3f000000, gfx_clamp(0.5, 0.0, 2.0))
	assert_float_bits(0x40400000, gfx_lerp(2.0, 4.0, 0.5))
	assert_float_bits(0x40000000, gfx_floor(2.75))
	assert_float_bits(cast(int, 0xc0400000), gfx_floor(-2.25))    # floor(-2.25) = -3
	assert_near(1.0, gfx_mod(7.0, 3.0))
	assert_near(2.0, gfx_mod(-7.0, 3.0))               # glm mod keeps the divisor's sign


void test_sqrt():
	assert_near(2.0, gfx_sqrt(4.0))
	assert_near(1.5, gfx_sqrt(2.25))
	assert_near(12.0, gfx_sqrt(144.0))
	assert_near(0.1, gfx_sqrt(0.01))
	assert_near(31.622776, gfx_sqrt(1000.0))
	assert_float_bits(0, gfx_sqrt(0.0))
	assert_float_bits(0, gfx_sqrt(-4.0))
	assert_near(2.0, gfx_inverse_sqrt(0.25))


void test_trig():
	assert_near(0.0, gfx_sin(0.0))
	assert_near(1.0, gfx_sin(gfx_half_pi()))
	assert_near(0.0 - 1.0, gfx_sin(0.0 - gfx_half_pi()))
	assert_near(0.5, gfx_sin(radians(30.0)))
	assert_near(0.70710678, gfx_sin(radians(45.0)))
	assert_near(0.86602540, gfx_sin(radians(60.0)))
	# outside the primary range: reduction handles it
	assert_near(0.5, gfx_sin(radians(30.0) + gfx_two_pi()))
	assert_near(0.0 - 0.5, gfx_sin(radians(210.0)))

	assert_near(1.0, gfx_cos(0.0))
	assert_near(0.0, gfx_cos(gfx_half_pi()))
	assert_near(0.0 - 1.0, gfx_cos(gfx_pi()))
	assert_near(0.86602540, gfx_cos(radians(30.0)))

	assert_near(1.0, gfx_tan(radians(45.0)))
	assert_near(0.57735027, gfx_tan(radians(30.0)))


void test_vec2():
	vec2 a = vec2_new(1.0, 2.0)
	vec2 b = vec2_new(3.0, 4.0)
	vec2 sum = vec2_add(a, b)
	assert_float_bits(0x40800000, sum.x)    # 4.0
	assert_float_bits(0x40c00000, sum.y)    # 6.0
	vec2 diff = vec2_sub(b, a)
	assert_float_bits(0x40000000, diff.x)
	assert_float_bits(0x40000000, diff.y)
	assert_float_bits(0x41300000, vec2_dot(a, b))    # 11.0
	assert_near(5.0, vec2_length(vec2_new(3.0, 4.0)))
	vec2 n = vec2_normalize(vec2_new(3.0, 4.0))
	assert_near(0.6, n.x)
	assert_near(0.8, n.y)
	vec2 mid = vec2_lerp(a, b, 0.5)
	assert_float_bits(0x40000000, mid.x)
	assert_float_bits(0x40400000, mid.y)


void test_vec3():
	vec3 a = vec3_new(1.0, 2.0, 3.0)
	vec3 b = vec3_new(4.0, 5.0, 6.0)
	vec3 sum = vec3_add(a, b)
	assert_float_bits(0x40a00000, sum.x)    # 5.0
	assert_float_bits(0x40e00000, sum.y)    # 7.0
	assert_float_bits(0x41100000, sum.z)    # 9.0
	assert_float_bits(0x42000000, vec3_dot(a, b))    # 32.0
	vec3 x_axis = vec3_new(1.0, 0.0, 0.0)
	vec3 y_axis = vec3_new(0.0, 1.0, 0.0)
	vec3 z = vec3_cross(x_axis, y_axis)
	assert_float_bits(0, z.x)
	assert_float_bits(0, z.y)
	assert_float_bits(0x3f800000, z.z)      # x cross y = z
	assert_near(3.7416574, vec3_length(a))
	vec3 n = vec3_normalize(vec3_new(2.0, 0.0, 0.0))
	assert_float_bits(0x3f800000, n.x)
	vec3 scaled = vec3_scale(a, 2.0)
	assert_float_bits(0x40000000, scaled.x)
	assert_float_bits(0x40c00000, scaled.z)
	# reflect straight-down direction off a floor: comes back up
	vec3 bounce = vec3_reflect(vec3_new(1.0, 0.0 - 1.0, 0.0), y_axis)
	assert_near(1.0, bounce.x)
	assert_near(1.0, bounce.y)
	assert_near(0.0, bounce.z)


void test_vec4():
	vec4 a = vec4_new(1.0, 2.0, 3.0, 4.0)
	vec4 b = vec4_new(5.0, 6.0, 7.0, 8.0)
	assert_float_bits(0x428c0000, vec4_dot(a, b))    # 70.0
	vec4 sum = vec4_add(a, b)
	assert_float_bits(0x40c00000, sum.x)             # 6.0
	assert_float_bits(0x41400000, sum.w)             # 12.0
	vec4 hom = vec4_from_vec3(vec3_new(1.0, 2.0, 3.0), 1.0)
	assert_float_bits(0x3f800000, hom.w)
	assert_near(2.0, vec4_length(vec4_new(1.0, 1.0, 1.0, 1.0)))


void test_mat4_identity_and_mul():
	mat4 i = mat4_identity()
	assert_float_bits(0x3f800000, i.m[0])
	assert_float_bits(0x3f800000, i.m[5])
	assert_float_bits(0x3f800000, i.m[10])
	assert_float_bits(0x3f800000, i.m[15])
	assert_float_bits(0, i.m[1])
	assert_float_bits(0, i.m[12])

	# identity * m == m
	mat4 t = mat4_translate(mat4_identity(), vec3_new(3.0, 4.0, 5.0))
	mat4 p = mat4_mul(mat4_identity(), t)
	assert_float_bits(0x40400000, p.m[12])
	assert_float_bits(0x40800000, p.m[13])
	assert_float_bits(0x40a00000, p.m[14])

	# two translations compose additively
	mat4 t2 = mat4_mul(t, t)
	assert_float_bits(0x40c00000, t2.m[12])    # 6.0
	assert_float_bits(0x41000000, t2.m[13])    # 8.0
	assert_float_bits(0x41200000, t2.m[14])    # 10.0


void test_mat4_transform_point():
	mat4 t = mat4_translate(mat4_identity(), vec3_new(10.0, 20.0, 30.0))
	vec3 p = mat4_mul_point(t, vec3_new(1.0, 2.0, 3.0))
	assert_float_bits(0x41300000, p.x)    # 11.0
	assert_float_bits(0x41b00000, p.y)    # 22.0
	assert_float_bits(0x42040000, p.z)    # 33.0

	mat4 s = mat4_scale(mat4_identity(), vec3_new(2.0, 3.0, 4.0))
	vec3 q = mat4_mul_point(s, vec3_new(1.0, 1.0, 1.0))
	assert_float_bits(0x40000000, q.x)
	assert_float_bits(0x40400000, q.y)
	assert_float_bits(0x40800000, q.z)

	# direction vectors (w = 0) ignore translation
	vec4 dir = mat4_mul_vec4(t, vec4_new(1.0, 0.0, 0.0, 0.0))
	assert_float_bits(0x3f800000, dir.x)
	assert_float_bits(0, dir.y)


void test_mat4_rotation():
	# 90 degrees about z maps +x to +y
	mat4 r = mat4_rotation(gfx_half_pi(), vec3_new(0.0, 0.0, 1.0))
	vec3 p = mat4_mul_point(r, vec3_new(1.0, 0.0, 0.0))
	assert_near(0.0, p.x)
	assert_near(1.0, p.y)
	assert_near(0.0, p.z)

	# 180 degrees about y maps +x to -x
	mat4 r2 = mat4_rotation(gfx_pi(), vec3_new(0.0, 1.0, 0.0))
	vec3 q = mat4_mul_point(r2, vec3_new(1.0, 0.0, 0.0))
	assert_near(0.0 - 1.0, q.x)
	assert_near(0.0, q.z)

	# rotate() post-multiplies like glm: translate then rotate locally
	mat4 m = mat4_translate(mat4_identity(), vec3_new(5.0, 0.0, 0.0))
	m = mat4_rotate(m, gfx_half_pi(), vec3_new(0.0, 0.0, 1.0))
	vec3 w = mat4_mul_point(m, vec3_new(1.0, 0.0, 0.0))
	assert_near(5.0, w.x)
	assert_near(1.0, w.y)


void test_mat4_transpose():
	mat4 t = mat4_translate(mat4_identity(), vec3_new(1.0, 2.0, 3.0))
	mat4 tt = mat4_transpose(t)
	assert_float_bits(0x3f800000, tt.m[0])
	assert_float_bits(0x3f800000, mat4_get(tt, 3, 0))    # row 3, col 0 = 1.0
	assert_float_bits(0x40000000, mat4_get(tt, 3, 1))    # t's ty moved to row 3, col 1
	assert_float_bits(0, tt.m[12])


void test_mat4_perspective():
	# fovy 90 degrees, square aspect: tan(fovy/2) == 1
	mat4 p = mat4_perspective(gfx_half_pi(), 1.0, 1.0, 100.0)
	assert_near(1.0, p.m[0])
	assert_near(1.0, p.m[5])
	assert_near(0.0 - 1.0202020, p.m[10])
	assert_near(0.0 - 1.0, p.m[11])
	assert_near(0.0 - 2.0202020, p.m[14])
	assert_float_bits(0, p.m[15])

	# a point on the near plane lands on z = -1 after the divide
	vec4 near_point = mat4_mul_vec4(p, vec4_new(0.0, 0.0, 0.0 - 1.0, 1.0))
	assert_near(0.0 - 1.0, near_point.z / near_point.w)
	# and on the far plane, z = +1
	vec4 far_point = mat4_mul_vec4(p, vec4_new(0.0, 0.0, 0.0 - 100.0, 1.0))
	assert_near(1.0, far_point.z / far_point.w)


void test_mat4_ortho():
	mat4 o = mat4_ortho(0.0, 800.0, 0.0, 600.0, 0.0 - 1.0, 1.0)
	# pixel-space corners map to NDC corners
	vec3 origin = mat4_mul_point(o, vec3_new(0.0, 0.0, 0.0))
	assert_near(0.0 - 1.0, origin.x)
	assert_near(0.0 - 1.0, origin.y)
	vec3 corner = mat4_mul_point(o, vec3_new(800.0, 600.0, 0.0))
	assert_near(1.0, corner.x)
	assert_near(1.0, corner.y)
	vec3 center = mat4_mul_point(o, vec3_new(400.0, 300.0, 0.0))
	assert_near(0.0, center.x)
	assert_near(0.0, center.y)


void test_mat4_look_at():
	# camera at +5z looking at the origin: a point at the origin lands
	# 5 units down the view -z axis
	mat4 view = mat4_look_at(vec3_new(0.0, 0.0, 5.0), vec3_new(0.0, 0.0, 0.0), vec3_new(0.0, 1.0, 0.0))
	vec3 p = mat4_mul_point(view, vec3_new(0.0, 0.0, 0.0))
	assert_near(0.0, p.x)
	assert_near(0.0, p.y)
	assert_near(0.0 - 5.0, p.z)
	# +x stays +x for this orientation
	vec3 q = mat4_mul_point(view, vec3_new(1.0, 0.0, 0.0))
	assert_near(1.0, q.x)


void test_quat():
	quat i = quat_identity()
	assert_float_bits(0x3f800000, i.w)
	vec3 v = quat_rotate_vec3(i, vec3_new(1.0, 2.0, 3.0))
	assert_near(1.0, v.x)
	assert_near(2.0, v.y)
	assert_near(3.0, v.z)

	# 90 degrees about z maps +x to +y
	quat r = quat_from_axis_angle(vec3_new(0.0, 0.0, 1.0), gfx_half_pi())
	vec3 p = quat_rotate_vec3(r, vec3_new(1.0, 0.0, 0.0))
	assert_near(0.0, p.x)
	assert_near(1.0, p.y)
	assert_near(0.0, p.z)

	# composing two 90-degree turns is a half turn
	quat half_turn = quat_mul(r, r)
	vec3 q = quat_rotate_vec3(half_turn, vec3_new(1.0, 0.0, 0.0))
	assert_near(0.0 - 1.0, q.x)
	assert_near(0.0, q.y)

	assert_near(1.0, quat_length(r))
	quat n = quat_normalize(quat_new(0.0, 0.0, 0.0, 4.0))
	assert_float_bits(0x3f800000, n.w)

	# the mat4 form agrees with direct rotation
	mat4 rm = quat_to_mat4(r)
	vec3 mp = mat4_mul_point(rm, vec3_new(1.0, 0.0, 0.0))
	assert_near(0.0, mp.x)
	assert_near(1.0, mp.y)


void test_quat_matches_mat4_rotation():
	vec3 axis = vec3_new(1.0, 1.0, 0.0)
	float32 angle = radians(40.0)
	quat q = quat_from_axis_angle(axis, angle)
	mat4 m = mat4_rotation(angle, axis)
	vec3 v = vec3_new(0.5, 0.0 - 2.0, 1.5)
	vec3 via_quat = quat_rotate_vec3(q, v)
	vec3 via_mat = mat4_mul_point(m, v)
	assert_near(via_mat.x, via_quat.x)
	assert_near(via_mat.y, via_quat.y)
	assert_near(via_mat.z, via_quat.z)
