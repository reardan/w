# CPU reference checks for graphics.effects_cpu: known values and
# invariants of every effect kind. No GL, so it runs on every target.
# wbuild: x64 name=graphics_effects_cpu_test
import lib.testing
import graphics.effects_core
import graphics.effects_cpu


# A width x height image filled with one color.
char* fx_test_flat(int width, int height, int r, int g, int b, int a):
	char* pixels = cast(char*, malloc(width * height * 4))
	for i in range(width * height):
		pixels[i * 4] = r
		pixels[i * 4 + 1] = g
		pixels[i * 4 + 2] = b
		pixels[i * 4 + 3] = a
	return pixels


# A deterministic varied image: gradients plus a checker.
char* fx_test_pattern(int width, int height):
	char* pixels = cast(char*, malloc(width * height * 4))
	for y in range(height):
		for x in range(width):
			char* p = &pixels[(y * width + x) * 4]
			p[0] = (x * 255) / (width - 1)
			p[1] = (y * 255) / (height - 1)
			int check = ((x / 2) + (y / 2)) % 2
			p[2] = 40 + check * 170
			p[3] = 255
	return pixels


int fx_test_channel(char* pixels, int width, int x, int y, int channel):
	return pixels[(y * width + x) * 4 + channel] & 255


void fx_test_near(int want, int got, int tolerance):
	int diff = want - got
	if (diff < 0): diff = 0 - diff
	if (diff > tolerance): assert_equal(want, got)


# Every channel of every pixel within tolerance.
void fx_test_same(char* want, char* got, int length, int tolerance):
	for i in range(length): fx_test_near(want[i] & 255, got[i] & 255, tolerance)


char* fx_test_one(fx_effect* e, char* src, int width, int height):
	char* out = fx_cpu_apply(e, src, width, height)
	fx_effect_free(e)
	return out


void test_bcs_identity_is_exact():
	char* src = fx_test_pattern(8, 6)
	char* out = fx_test_one(fx_bcs(0.0, 1.0, 1.0), src, 8, 6)
	fx_test_same(src, out, 8 * 6 * 4, 0)
	free(out)
	free(src)


void test_bcs_known_values():
	char* src = fx_test_flat(2, 2, 100, 200, 50, 77)
	# brightness +0.2 adds 51 levels.
	char* out = fx_test_one(fx_bcs(0.2, 1.0, 1.0), src, 2, 2)
	assert_equal(151, fx_test_channel(out, 2, 0, 0, 0))
	assert_equal(251, fx_test_channel(out, 2, 1, 1, 1))
	assert_equal(101, fx_test_channel(out, 2, 0, 1, 2))
	assert_equal(77, fx_test_channel(out, 2, 1, 0, 3))
	free(out)
	# contrast 2 doubles the distance from mid gray: 100 -> 72.5 -> 73 rounds
	# (100/255 - 0.5) * 2 + 0.5 = 0.28431 -> 72.5; clamp 200 -> 255.
	out = fx_test_one(fx_bcs(0.0, 2.0, 1.0), src, 2, 2)
	fx_test_near(73, fx_test_channel(out, 2, 0, 0, 0), 1)
	assert_equal(255, fx_test_channel(out, 2, 0, 0, 1))
	assert_equal(0, fx_test_channel(out, 2, 0, 0, 2))
	free(out)
	# saturation 0 is Rec. 709 luma in every channel.
	out = fx_test_one(fx_bcs(0.0, 1.0, 0.0), src, 2, 2)
	int luma = fx_test_channel(out, 2, 0, 0, 0)
	fx_test_near(168, luma, 1)
	assert_equal(luma, fx_test_channel(out, 2, 0, 0, 1))
	assert_equal(luma, fx_test_channel(out, 2, 0, 0, 2))
	free(out)
	free(src)


void test_levels():
	char* src = fx_test_pattern(8, 6)
	char* out = fx_test_one(fx_gamma(1.0), src, 8, 6)
	fx_test_same(src, out, 8 * 6 * 4, 0)
	free(out)
	free(src)
	src = fx_test_flat(1, 1, 64, 128, 255, 255)
	# gamma 2 brightens mid tones: (128/255)^(1/2) = 0.7085 -> 181.
	out = fx_test_one(fx_gamma(2.0), src, 1, 1)
	fx_test_near(181, fx_test_channel(out, 1, 0, 0, 1), 1)
	assert_equal(255, fx_test_channel(out, 1, 0, 0, 2))
	free(out)
	# input black 0.25 sends 64 to black; output white 0.5 halves 255.
	out = fx_test_one(fx_levels(0.25, 1.0, 1.0, 0.0, 0.5), src, 1, 1)
	fx_test_near(0, fx_test_channel(out, 1, 0, 0, 0), 1)
	fx_test_near(128, fx_test_channel(out, 1, 0, 0, 2), 1)
	free(out)
	free(src)


void test_convolve_identity_and_flat():
	char* src = fx_test_pattern(8, 6)
	float32[9] k
	for i in range(9): k[i] = 0.0
	k[4] = 1.0
	char* out = fx_test_one(fx_convolve(&k[0], 0.0), src, 8, 6)
	fx_test_same(src, out, 8 * 6 * 4, 0)
	free(out)
	free(src)
	src = fx_test_flat(5, 5, 90, 90, 90, 255)
	out = fx_test_one(fx_sharpen(1.0), src, 5, 5)
	fx_test_same(src, out, 5 * 5 * 4, 0)
	free(out)
	out = fx_test_one(fx_edge_detect(), src, 5, 5)
	assert_equal(0, fx_test_channel(out, 5, 2, 2, 0))
	assert_equal(255, fx_test_channel(out, 5, 2, 2, 3))
	free(out)
	out = fx_test_one(fx_emboss(), src, 5, 5)
	fx_test_near(128, fx_test_channel(out, 5, 0, 4, 1), 1)
	free(out)
	free(src)


void test_convolve_edge_detect_finds_a_step():
	# Left half black, right half white: only the bright side of the step
	# lights up (the dark side goes negative and clamps), flat areas stay black.
	char* src = fx_test_flat(6, 3, 0, 0, 0, 255)
	for y in range(3):
		for x in range(3):
			char* p = &src[(y * 6 + x + 3) * 4]
			p[0] = 255
			p[1] = 255
			p[2] = 255
	char* out = fx_test_one(fx_edge_detect(), src, 6, 3)
	assert_equal(0, fx_test_channel(out, 6, 0, 1, 0))
	assert_equal(0, fx_test_channel(out, 6, 2, 1, 0))
	assert_equal(255, fx_test_channel(out, 6, 3, 1, 0))
	assert_equal(0, fx_test_channel(out, 6, 4, 1, 0))
	assert_equal(0, fx_test_channel(out, 6, 5, 1, 0))
	free(out)
	free(src)


void test_blur_weights_normalize():
	fx_effect* e = fx_blur_pass(4, 0)
	float32[33] w
	fx_blur_weights(e, &w[0])
	float32 total = w[0]
	for i in range(4): total = total + 2.0 * w[i + 1]
	assert_near(1.0, total)
	asserts(c"weights fall off", (w[0] > w[1]) && (w[1] > w[4]))
	assert_near(0.0, w[5])
	fx_effect_free(e)


void test_blur_flat_and_impulse():
	char* src = fx_test_flat(9, 9, 30, 60, 90, 200)
	list[fx_effect*] chain = new list[fx_effect*]
	chain.push(fx_blur_pass(3, 0))
	chain.push(fx_blur_pass(3, 1))
	char* out = fx_cpu_run(chain, src, 9, 9)
	fx_test_same(src, out, 9 * 9 * 4, 0)
	free(out)
	free(src)
	# A single white pixel spreads symmetrically and keeps its mass.
	src = fx_test_flat(9, 9, 0, 0, 0, 255)
	src[(4 * 9 + 4) * 4] = 255
	out = fx_cpu_run(chain, src, 9, 9)
	int center = fx_test_channel(out, 9, 4, 4, 0)
	asserts(c"center dimmed", (center > 0) && (center < 255))
	assert_equal(fx_test_channel(out, 9, 3, 4, 0), fx_test_channel(out, 9, 5, 4, 0))
	assert_equal(fx_test_channel(out, 9, 4, 3, 0), fx_test_channel(out, 9, 4, 5, 0))
	asserts(c"falls off", fx_test_channel(out, 9, 4, 1, 0) < fx_test_channel(out, 9, 4, 3, 0))
	int total = 0
	for i in range(81): total = total + (out[i * 4] & 255)
	fx_test_near(255, total, 24)
	free(out)
	free(src)
	for i in range(chain.length): fx_effect_free(chain[i])


void test_vignette():
	char* src = fx_test_flat(9, 9, 200, 200, 200, 255)
	char* out = fx_test_one(fx_vignette(1.0, 0.3, 0.6), src, 9, 9)
	# The center is inside the radius: untouched. Corners darken most.
	assert_equal(200, fx_test_channel(out, 9, 4, 4, 0))
	int corner = fx_test_channel(out, 9, 0, 0, 0)
	int edge = fx_test_channel(out, 9, 4, 0, 0)
	asserts(c"corner darker than edge", corner < edge)
	asserts(c"edge darker than center", edge < 200)
	assert_equal(corner, fx_test_channel(out, 9, 8, 8, 0))
	assert_equal(255, fx_test_channel(out, 9, 0, 0, 3))
	free(out)
	free(src)


void test_lut_identity_and_presets():
	char* src = fx_test_pattern(16, 16)
	char* out = fx_test_one(fx_lut(fx_lut_generate(FX_LUT_IDENTITY, 16), 16, 1.0), src, 16, 16)
	fx_test_same(src, out, 16 * 16 * 4, 1)
	free(out)
	# Amount 0 leaves the image alone whatever the LUT.
	out = fx_test_one(fx_lut(fx_lut_generate(FX_LUT_SEPIA, 8), 8, 0.0), src, 16, 16)
	fx_test_same(src, out, 16 * 16 * 4, 0)
	free(out)
	# A sepia LUT approximates the sepia matrix (trilinear over 17 steps).
	out = fx_test_one(fx_lut(fx_lut_generate(FX_LUT_SEPIA, 17), 17, 1.0), src, 16, 16)
	float32[3] want
	for i in range(16 * 16):
		float32 r = cast(float32, src[i * 4] & 255) / 255.0
		float32 g = cast(float32, src[i * 4 + 1] & 255) / 255.0
		float32 b = cast(float32, src[i * 4 + 2] & 255) / 255.0
		fx_lut_preset_color(FX_LUT_SEPIA, r, g, b, &want[0])
		for ch in range(3): fx_test_near(fx_to_byte(want[ch]), out[i * 4 + ch] & 255, 6)
	free(out)
	free(src)
	assert_equal(16, fx_lut_strip_size(256, 16))
	assert_equal(0, fx_lut_strip_size(256, 15))
	assert_equal(FX_LUT_WARM, fx_lut_preset_named(c"warm"))
	assert_equal(0 - 1, fx_lut_preset_named(c"nope"))


void test_chain_order_and_image():
	char* pixels = fx_test_flat(3, 2, 100, 100, 100, 255)
	rgba_image* image = new rgba_image(3, 2, 24, pixels)
	list[fx_effect*] chain = new list[fx_effect*]
	chain.push(fx_bcs(0.2, 1.0, 1.0))
	chain.push(fx_levels(0.0, 1.0, 1.0, 0.0, 0.5))
	rgba_image* out = fx_cpu_run_image(chain, image)
	assert_equal(3, out.width)
	assert_equal(2, out.height)
	# (100 + 51) * 0.5 = 75.5 -> 76 (brightness first, then levels).
	fx_test_near(76, fx_test_channel(out.pixels, 3, 2, 1, 0), 1)
	assert_equal(100, image.pixels[0] & 255)
	rgba_image_free(out)
	rgba_image_free(image)
	for i in range(chain.length): fx_effect_free(chain[i])
	assert_strings_equal(c"blur", fx_kind_name(FX_BLUR))
