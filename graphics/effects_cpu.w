/*
graphics.effects_cpu: the CPU reference implementation of every
graphics.effects_core effect kind.

It is the oracle graphics/effects_gl_test.w checks the GPU passes
against, and the fallback examples/photo_fx.w runs when no GL context
is available. Pixels are tightly packed RGBA8 rows, top to bottom (the
graphics.image.image layout). Each pass reads one buffer and writes a
fresh one, quantizing to 8 bits exactly as an RGBA8 framebuffer does,
and edge taps clamp to the border like GL_CLAMP_TO_EDGE.

Imports no GL, so it builds and runs on every target.

Design notes: docs/projects/effects.md
*/
import lib.lib
import lib.fmath
import graphics.effects_core
import graphics.image.image
import lib.mem


float32 fx_cpu_channel(char* pixels, int width, int height, int x, int y, int channel):
	if (x < 0): x = 0
	if (y < 0): y = 0
	if (x >= width): x = width - 1
	if (y >= height): y = height - 1
	return cast(float32, pixels[(y * width + x) * 4 + channel] & 255) / 255.0


void fx_cpu_bcs_pixel(fx_effect* e, float32* c):
	float32 brightness = e.p[0]
	float32 contrast = e.p[1]
	float32 saturation = e.p[2]
	for i in range(3): c[i] = (c[i] + brightness - 0.5) * contrast + 0.5
	float32 luma = 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]
	for i in range(3): c[i] = luma + (c[i] - luma) * saturation


void fx_cpu_levels_pixel(fx_effect* e, float32* c):
	float32 inverse_gamma = 1.0 / e.p[2]
	for i in range(3):
		float32 v = fx_clamp01((c[i] - e.p[0]) / (e.p[1] - e.p[0]))
		if (v > 0.0): v = fpow(v, inverse_gamma)
		c[i] = e.p[3] + v * (e.p[4] - e.p[3])


# Bilinear fetch of the LUT strip at texel-space coordinates (tx, ty),
# measured from the left/top edge (texel centers at +0.5); out holds 3.
void fx_cpu_lut_fetch(fx_effect* e, float32 tx, float32 ty, float32* out):
	int width = e.lut_size * e.lut_size
	int height = e.lut_size
	float32 fx = tx - 0.5
	float32 fy = ty - 0.5
	int x0 = cast(int, ffloor(fx))
	int y0 = cast(int, ffloor(fy))
	float32 ax = fx - cast(float32, x0)
	float32 ay = fy - cast(float32, y0)
	for ch in range(3):
		float32 c00 = fx_cpu_channel(e.lut, width, height, x0, y0, ch)
		float32 c10 = fx_cpu_channel(e.lut, width, height, x0 + 1, y0, ch)
		float32 c01 = fx_cpu_channel(e.lut, width, height, x0, y0 + 1, ch)
		float32 c11 = fx_cpu_channel(e.lut, width, height, x0 + 1, y0 + 1, ch)
		float32 top = c00 + (c10 - c00) * ax
		float32 bottom = c01 + (c11 - c01) * ax
		out[ch] = top + (bottom - top) * ay


void fx_cpu_lut_pixel(fx_effect* e, float32* c):
	float32 n = cast(float32, e.lut_size)
	float32 r = fx_clamp01(c[0])
	float32 g = fx_clamp01(c[1])
	float32 b = fx_clamp01(c[2]) * (n - 1.0)
	float32 b0 = ffloor(b)
	float32 b1 = b0 + 1.0
	if (b1 > n - 1.0): b1 = n - 1.0
	float32 f = b - b0
	float32 tx = r * (n - 1.0) + 0.5
	float32 ty = g * (n - 1.0) + 0.5
	float32[3] lo
	float32[3] hi
	fx_cpu_lut_fetch(e, b0 * n + tx, ty, &lo[0])
	fx_cpu_lut_fetch(e, b1 * n + tx, ty, &hi[0])
	float32 amount = e.p[0]
	for i in range(3):
		float32 graded = lo[i] + (hi[i] - lo[i]) * f
		c[i] = c[i] + (graded - c[i]) * amount


# Apply one effect to width x height RGBA src; returns a new buffer the
# caller frees (src is untouched).
char* fx_cpu_apply(fx_effect* e, char* src, int width, int height):
	char* dst = cast(char*, malloc(width * height * 4))
	float32[4] c
	float32[33] weights
	if (e.kind == FX_BLUR): fx_blur_weights(e, &weights[0])
	int radius = cast(int, e.p[0])
	int step_x = 1
	int step_y = 0
	if (e.p[2] > 0.5):
		step_x = 0
		step_y = 1
	for y in range(height):
		for x in range(width):
			for ch in range(4): c[ch] = fx_cpu_channel(src, width, height, x, y, ch)
			if (e.kind == FX_BCS): fx_cpu_bcs_pixel(e, &c[0])
			else if (e.kind == FX_LEVELS): fx_cpu_levels_pixel(e, &c[0])
			else if (e.kind == FX_CONVOLVE):
				for ch in range(3):
					float32 sum = e.p[9]
					for k in range(9):
						int dx = k % 3 - 1
						int dy = k / 3 - 1
						sum = sum + e.p[k] * fx_cpu_channel(src, width, height, x + dx, y + dy, ch)
					c[ch] = sum
			else if (e.kind == FX_BLUR):
				for ch in range(4):
					float32 sum = weights[0] * c[ch]
					int i = 1
					while (i <= radius):
						float32 a = fx_cpu_channel(src, width, height, x + i * step_x, y + i * step_y, ch)
						float32 b = fx_cpu_channel(src, width, height, x - i * step_x, y - i * step_y, ch)
						sum = sum + weights[i] * (a + b)
						i = i + 1
					c[ch] = sum
			else if (e.kind == FX_VIGNETTE):
				float32 u = (cast(float32, x) + 0.5) / cast(float32, width)
				float32 v = (cast(float32, y) + 0.5) / cast(float32, height)
				float32 factor = fx_vignette_factor(e, u, v)
				for ch in range(3): c[ch] = c[ch] * factor
			else if (e.kind == FX_LUT): fx_cpu_lut_pixel(e, &c[0])
			char* out = &dst[(y * width + x) * 4]
			for ch in range(4): out[ch] = fx_to_byte(c[ch])
	return dst


# Run effects in order over src; returns a new buffer the caller frees.
char* fx_cpu_run(list[fx_effect*] effects, char* src, int width, int height):
	char* current = cast(char*, malloc(width * height * 4))
	mem_copy(current, src, width * height * 4)
	for i in range(effects.length):
		char* next = fx_cpu_apply(effects[i], current, width, height)
		free(current)
		current = next
	return current


# The same over an rgba_image; returns a new caller-owned image.
rgba_image* fx_cpu_run_image(list[fx_effect*] effects, rgba_image* image):
	char* pixels = fx_cpu_run(effects, image.pixels, image.width, image.height)
	return new rgba_image(image.width, image.height, image.width * image.height * 4, pixels)
