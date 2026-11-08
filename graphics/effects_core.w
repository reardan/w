/*
graphics.effects_core: the target-neutral half of the photo effects
library -- what an effect IS, independent of how it runs.

An fx_effect is a kind plus up to fx_param_slots float parameters (and,
for color grading, a LUT strip). The same effect list runs on the GPU
(graphics/effects.w: one fragment-shader pass per effect over ping-pong
framebuffer objects) or on the CPU (graphics/effects_cpu.w, the
reference the GL output is tested against). This module imports no GL
and no window, so the CPU path builds for every target, x86 included.

Every formula below is shared: the GLSL in graphics/effects.w and the
loops in graphics/effects_cpu.w implement the same arithmetic on
0..1 floats, and both quantize to 8 bits between passes (an RGBA8
framebuffer does the same), so their outputs agree to a couple of
levels.

Design notes: docs/projects/effects.md
*/
import lib.lib
import lib.fmath


const int FX_BCS = 1          # brightness, contrast, saturation
const int FX_LEVELS = 2       # input levels, gamma, output levels
const int FX_CONVOLVE = 3     # 3x3 kernel (sharpen, edge detect, emboss)
const int FX_BLUR = 4         # one direction of a separable Gaussian
const int FX_VIGNETTE = 5     # radial darkening toward the corners
const int FX_LUT = 6          # 3D color-grading LUT in a strip texture
const int FX_KIND_COUNT = 7   # one past the last kind (program cache size)

const int fx_param_slots = 12
const int fx_blur_max_radius = 32

# LUT presets for fx_lut_generate.
const int FX_LUT_IDENTITY = 0
const int FX_LUT_WARM = 1
const int FX_LUT_COOL = 2
const int FX_LUT_SEPIA = 3
const int FX_LUT_MONO = 4


/*
Parameter layout per kind (p[i]):

	FX_BCS       0 brightness (additive, 0 = none), 1 contrast (1 = none),
	             2 saturation (1 = none, 0 = grayscale)
	FX_LEVELS    0 input black, 1 input white, 2 gamma (1 = none),
	             3 output black, 4 output white
	FX_CONVOLVE  0..8 kernel, row-major from the top-left neighbor,
	             9 bias (added after the weighted sum)
	FX_BLUR      0 radius in pixels (1..fx_blur_max_radius), 1 sigma,
	             2 direction (0 = horizontal, 1 = vertical)
	FX_VIGNETTE  0 amount (0 = none, 1 = black corners), 1 radius where
	             darkening starts, 2 softness (width of the falloff);
	             distances are 0 at the center and 1 at a corner
	FX_LUT       0 amount (0 = untouched, 1 = fully graded); lut/lut_size
	             hold the strip

Colors are rgb in 0..1; alpha passes through every kind but FX_BLUR,
which blurs all four channels.
*/
struct fx_effect:
	int kind
	float32[12] p
	# FX_LUT only: lut_size*lut_size wide, lut_size tall, RGBA8 rows;
	# texel (b * lut_size + r, g) holds the graded color of input
	# (r, g, b) / (lut_size - 1). Owned by the effect.
	char* lut
	int lut_size
	# FX_LUT only: the GL texture graphics/effects.w uploaded the strip
	# to (0 until first use), so a chain re-run does not re-upload.
	int32 lut_texture


fx_effect* fx_effect_new(int kind):
	# Plain `new` plus explicit zeroing: `new fx_effect(kind: kind)`
	# trips the fixed-array bounds check on p (docs/todo.txt).
	fx_effect* e = new fx_effect()
	e.kind = kind
	for i in range(fx_param_slots): e.p[i] = 0.0
	e.lut = 0
	e.lut_size = 0
	e.lut_texture = 0
	return e


void fx_effect_free(fx_effect* e):
	if (e == 0): return
	if (e.lut != 0): free(e.lut)
	free(e)


float32 fx_clamp01(float32 v):
	if (v < 0.0): return 0.0
	if (v > 1.0): return 1.0
	return v


######################### effect constructors #########################

fx_effect* fx_bcs(float32 brightness, float32 contrast, float32 saturation):
	fx_effect* e = fx_effect_new(FX_BCS)
	e.p[0] = brightness
	e.p[1] = contrast
	e.p[2] = saturation
	return e


fx_effect* fx_levels(float32 in_black, float32 in_white, float32 gamma, float32 out_black, float32 out_white):
	fx_effect* e = fx_effect_new(FX_LEVELS)
	if (in_white - in_black < 0.001): in_white = in_black + 0.001
	if (gamma < 0.01): gamma = 0.01
	e.p[0] = in_black
	e.p[1] = in_white
	e.p[2] = gamma
	e.p[3] = out_black
	e.p[4] = out_white
	return e


# Gamma alone: levels with the full input and output ranges.
fx_effect* fx_gamma(float32 gamma):
	return fx_levels(0.0, 1.0, gamma, 0.0, 1.0)


# kernel points at 9 floats, row-major from the top-left neighbor.
fx_effect* fx_convolve(float32* kernel, float32 bias):
	fx_effect* e = fx_effect_new(FX_CONVOLVE)
	for i in range(9): e.p[i] = kernel[i]
	e.p[9] = bias
	return e


# Unsharp-style 3x3 sharpen: the center gains 4 * amount, each edge
# neighbor loses amount (amount 1 is the classic 0 -1 0 / -1 5 -1 kernel).
fx_effect* fx_sharpen(float32 amount):
	float32[9] k
	for i in range(9): k[i] = 0.0
	float32 neg = 0.0 - amount
	k[1] = neg
	k[3] = neg
	k[4] = 1.0 + 4.0 * amount
	k[5] = neg
	k[7] = neg
	return fx_convolve(&k[0], 0.0)


# Laplacian edge detect: flat regions go black, edges bright.
fx_effect* fx_edge_detect():
	float32[9] k
	for i in range(9): k[i] = 0.0 - 1.0
	k[4] = 8.0
	return fx_convolve(&k[0], 0.0)


# Emboss toward the top left, centered on mid gray.
fx_effect* fx_emboss():
	float32[9] k
	for i in range(9): k[i] = 0.0
	k[0] = 0.0 - 1.0
	k[1] = 0.0 - 1.0
	k[3] = 0.0 - 1.0
	k[5] = 1.0
	k[7] = 1.0
	k[8] = 1.0
	return fx_convolve(&k[0], 0.5)


# One direction of a Gaussian blur; fx_blur_pair builds both. sigma is
# radius / 2 (at least 0.5), so the kernel reaches two sigmas.
fx_effect* fx_blur_pass(int radius, int vertical):
	if (radius < 1): radius = 1
	if (radius > fx_blur_max_radius): radius = fx_blur_max_radius
	fx_effect* e = fx_effect_new(FX_BLUR)
	e.p[0] = cast(float32, radius)
	float32 sigma = cast(float32, radius) * 0.5
	if (sigma < 0.5): sigma = 0.5
	e.p[1] = sigma
	e.p[2] = cast(float32, vertical)
	return e


# The normalized one-sided Gaussian weights of a blur pass: weights[0]
# is the center tap, weights[i] the taps at +-i, for i up to radius.
# weights must hold fx_blur_max_radius + 1 floats.
void fx_blur_weights(fx_effect* e, float32* weights):
	int radius = cast(int, e.p[0])
	float32 sigma = e.p[1]
	float32 total = 0.0
	for i in range(radius + 1):
		float32 x = cast(float32, i)
		float32 w = fexp(0.0 - x * x / (2.0 * sigma * sigma))
		weights[i] = w
		if (i == 0): total = total + w
		else: total = total + 2.0 * w
	for i in range(radius + 1): weights[i] = weights[i] / total
	int j = radius + 1
	while (j <= fx_blur_max_radius):
		weights[j] = 0.0
		j = j + 1


fx_effect* fx_vignette(float32 amount, float32 radius, float32 softness):
	fx_effect* e = fx_effect_new(FX_VIGNETTE)
	if (softness < 0.001): softness = 0.001
	e.p[0] = amount
	e.p[1] = radius
	e.p[2] = softness
	return e


# Takes ownership of lut (lut_size * lut_size wide, lut_size tall RGBA).
fx_effect* fx_lut(char* lut, int lut_size, float32 amount):
	fx_effect* e = fx_effect_new(FX_LUT)
	e.lut = lut
	e.lut_size = lut_size
	e.p[0] = amount
	return e


char* fx_kind_name(int kind):
	if (kind == FX_BCS): return c"bcs"
	if (kind == FX_LEVELS): return c"levels"
	if (kind == FX_CONVOLVE): return c"convolve"
	if (kind == FX_BLUR): return c"blur"
	if (kind == FX_VIGNETTE): return c"vignette"
	if (kind == FX_LUT): return c"lut"
	return c"unknown"


########################### shared formulas ###########################

float32 fx_smoothstep(float32 e0, float32 e1, float32 x):
	float32 t = fx_clamp01((x - e0) / (e1 - e0))
	return t * t * (3.0 - 2.0 * t)


# The vignette's brightness factor at normalized coordinates (u, v),
# both 0..1 across the image.
float32 fx_vignette_factor(fx_effect* e, float32 u, float32 v):
	float32 dx = (u - 0.5) * 2.0
	float32 dy = (v - 0.5) * 2.0
	float32 d = fsqrt(dx * dx + dy * dy) * 0.70710678
	return 1.0 - e.p[0] * fx_smoothstep(e.p[1], e.p[1] + e.p[2], d)


# 8-bit quantization of a 0..1 channel, as an RGBA8 render target does.
int fx_to_byte(float32 v):
	return cast(int, fx_clamp01(v) * 255.0 + 0.5)


############################# LUT strips ##############################

# The graded color of a preset, for an input color in 0..1; out holds 3.
void fx_lut_preset_color(int preset, float32 r, float32 g, float32 b, float32* out):
	float32 luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
	if (preset == FX_LUT_WARM):
		out[0] = fx_clamp01(r * 1.08 + 0.03)
		out[1] = fx_clamp01(g * 1.0 + 0.01)
		out[2] = fx_clamp01(b * 0.86)
	else if (preset == FX_LUT_COOL):
		out[0] = fx_clamp01(r * 0.88)
		out[1] = fx_clamp01(g * 0.98 + 0.01)
		out[2] = fx_clamp01(b * 1.08 + 0.04)
	else if (preset == FX_LUT_SEPIA):
		out[0] = fx_clamp01(0.393 * r + 0.769 * g + 0.189 * b)
		out[1] = fx_clamp01(0.349 * r + 0.686 * g + 0.168 * b)
		out[2] = fx_clamp01(0.272 * r + 0.534 * g + 0.131 * b)
	else if (preset == FX_LUT_MONO):
		# Grayscale with a gentle S-curve.
		float32 s = fx_smoothstep(0.0, 1.0, luma)
		float32 m = luma * 0.5 + s * 0.5
		out[0] = m
		out[1] = m
		out[2] = m
	else:
		out[0] = r
		out[1] = g
		out[2] = b


# A size*size x size RGBA strip for preset (size 2..64). Caller owns it.
char* fx_lut_generate(int preset, int size):
	int width = size * size
	char* lut = cast(char*, malloc(width * size * 4))
	float32 scale = 1.0 / cast(float32, size - 1)
	float32[3] c
	for g in range(size):
		for b in range(size):
			for r in range(size):
				fx_lut_preset_color(preset, cast(float32, r) * scale, cast(float32, g) * scale, cast(float32, b) * scale, &c[0])
				char* t = &lut[(g * width + b * size + r) * 4]
				t[0] = fx_to_byte(c[0])
				t[1] = fx_to_byte(c[1])
				t[2] = fx_to_byte(c[2])
				t[3] = 255
	return lut


# Preset by name ("identity", "warm", "cool", "sepia", "mono"), -1 when
# unknown.
int fx_lut_preset_named(char* name):
	if (strcmp(name, c"identity") == 0): return FX_LUT_IDENTITY
	if (strcmp(name, c"warm") == 0): return FX_LUT_WARM
	if (strcmp(name, c"cool") == 0): return FX_LUT_COOL
	if (strcmp(name, c"sepia") == 0): return FX_LUT_SEPIA
	if (strcmp(name, c"mono") == 0): return FX_LUT_MONO
	return 0 - 1


# The strip size of an image of width x height, or 0 when it is not a
# size*size x size strip.
int fx_lut_strip_size(int width, int height):
	if ((height < 2) || (height > 64)): return 0
	if (width != height * height): return 0
	return height
