/*
examples.photo.photo_lib: what examples/photo/photo_fx.w (the CLI) and
examples/photo/photo_viewer.w (the interactive viewer) share -- image
loading (PNG or JPEG by signature, or a synthetic "pattern:WxH"),
PNG writing, the effect-chain settings and the chain they build.

Effects always apply in one fixed order, whatever order the flags came
in: levels/gamma, brightness/contrast/saturation, LUT grade, blur,
sharpen / edge detect / emboss, vignette. A setting left at its neutral
value adds no pass. Design notes: docs/projects/effects.md
*/
import lib.lib
import lib.io
import lib.args
import lib.format
import lib.stream
import graphics.effects_core
import graphics.image.image
import graphics.image.png
import graphics.image.jpeg


struct photo_settings:
	float32 brightness
	float32 contrast
	float32 saturation
	float32 gamma
	float32 black          # input levels
	float32 white
	float32 blur           # radius in pixels, 0 = none
	float32 sharpen        # amount, 0 = none
	int32 edges
	int32 emboss
	float32 vignette       # amount, 0 = none
	float32 vignette_radius
	float32 vignette_softness
	int32 lut_preset       # FX_LUT_*, or -1 for none / a file LUT
	float32 lut_amount
	int32 lut_size
	# A LUT strip loaded from a file (owned), used when lut_preset is -1
	# and lut_file_size is nonzero.
	char* lut_file
	int32 lut_file_size


void photo_settings_init(photo_settings* s):
	s.brightness = 0.0
	s.contrast = 1.0
	s.saturation = 1.0
	s.gamma = 1.0
	s.black = 0.0
	s.white = 1.0
	s.blur = 0.0
	s.sharpen = 0.0
	s.edges = 0
	s.emboss = 0
	s.vignette = 0.0
	s.vignette_radius = 0.35
	s.vignette_softness = 0.65
	s.lut_preset = 0 - 1
	s.lut_amount = 1.0
	s.lut_size = 16
	s.lut_file = 0
	s.lut_file_size = 0


float32 photo_abs(float32 v):
	if (v < 0.0): return 0.0 - v
	return v


int photo_differs(float32 value, float32 neutral):
	return photo_abs(value - neutral) > 0.0005


# The chain for s, in the fixed order. The caller owns the effects.
list[fx_effect*] photo_build_chain(photo_settings* s):
	list[fx_effect*] chain = new list[fx_effect*]
	if (photo_differs(s.gamma, 1.0) || photo_differs(s.black, 0.0) || photo_differs(s.white, 1.0)):
		chain.push(fx_levels(s.black, s.white, s.gamma, 0.0, 1.0))
	if (photo_differs(s.brightness, 0.0) || photo_differs(s.contrast, 1.0) || photo_differs(s.saturation, 1.0)):
		chain.push(fx_bcs(s.brightness, s.contrast, s.saturation))
	if (photo_differs(s.lut_amount, 0.0)):
		if (s.lut_preset >= 0):
			chain.push(fx_lut(fx_lut_generate(s.lut_preset, s.lut_size), s.lut_size, s.lut_amount))
		else if (s.lut_file_size > 0):
			int bytes = s.lut_file_size * s.lut_file_size * s.lut_file_size * 4
			char* copy = cast(char*, malloc(bytes))
			for i in range(bytes): copy[i] = s.lut_file[i]
			chain.push(fx_lut(copy, s.lut_file_size, s.lut_amount))
	int radius = cast(int, s.blur + 0.5)
	if (radius > 0):
		chain.push(fx_blur_pass(radius, 0))
		chain.push(fx_blur_pass(radius, 1))
	if (photo_differs(s.sharpen, 0.0)): chain.push(fx_sharpen(s.sharpen))
	if (s.edges): chain.push(fx_edge_detect())
	if (s.emboss): chain.push(fx_emboss())
	if (photo_differs(s.vignette, 0.0)): chain.push(fx_vignette(s.vignette, s.vignette_radius, s.vignette_softness))
	return chain


void photo_free_chain(list[fx_effect*] chain):
	for i in range(chain.length): fx_effect_free(chain[i])


########################### image file I/O ############################

# A whole file, or 0; *length gets its size.
char* photo_read_file(char* path, int* length):
	int fd = open(path, 0, 0)
	if (fd < 0): return 0
	int size = file_size(fd)
	if ((size < 0) || (size > 268435456)):
		close(fd)
		return 0
	char* bytes = cast(char*, malloc(size + 1))
	io_result read_result
	int status = io_read_exact(fd, bytes, size, &read_result)
	close(fd)
	if (status != IO_OK):
		free(bytes)
		return 0
	*length = size
	return bytes


# A deterministic test image: color ramps, a checker and a soft disc.
rgba_image* photo_pattern(int width, int height):
	char* pixels = cast(char*, malloc(width * height * 4))
	for y in range(height):
		for x in range(width):
			char* p = &pixels[(y * width + x) * 4]
			int dx = x - width / 2
			int dy = y - height / 2
			int disc = (dx * dx + dy * dy) * 9 < (width * width + height * height)
			int check = ((x / 8) + (y / 8)) % 2
			p[0] = (x * 255) / (width - 1 + (width == 1))
			p[1] = (y * 255) / (height - 1 + (height == 1))
			p[2] = 60 + check * 120
			if (disc): p[2] = 250
			p[3] = 255
	return new rgba_image(width, height, width * height * 4, pixels)


# "pattern:WxH" -> a synthetic image, or 0 when path is not one.
rgba_image* photo_pattern_spec(char* path):
	if (starts_with(path, c"pattern:") == 0): return 0
	char* spec = path + 8
	int width = atoi(spec)
	int i = 0
	while ((spec[i] != 0) && (spec[i] != 'x')): i = i + 1
	if (spec[i] != 'x'): return 0
	int height = atoi(spec + i + 1)
	if ((width < 1) || (height < 1) || (width > 8192) || (height > 8192)): return 0
	return photo_pattern(width, height)


# Load a PNG or JPEG (chosen by signature) or a pattern: spec. Returns
# the image, or 0 after printing why.
rgba_image* photo_load(char* path):
	rgba_image* pattern = photo_pattern_spec(path)
	if (pattern != 0): return pattern
	int length = 0
	char* bytes = photo_read_file(path, &length)
	if (bytes == 0):
		print_error(c"photo: cannot read ")
		print_error(path)
		print_error(c"\n")
		return 0
	wresult[rgba_image*]* result = 0
	if ((length >= 2) && ((bytes[0] & 255) == 255) && ((bytes[1] & 255) == 216)):
		result = jpeg_decode_n(bytes, length, 0)
	else: result = png_decode_n(bytes, length, 0)
	free(bytes)
	rgba_image* image = 0
	if (result_is_error[rgba_image*](result)):
		print_error(c"photo: ")
		print_error(path)
		print_error(c": ")
		print_error(image_error_string(result.code))
		print_error(c"\n")
	else: image = result.value
	result_free[rgba_image*](result)
	return image


# Write RGBA rows as a PNG. Returns 1 on success.
int photo_write_png(char* path, int width, int height, char* pixels):
	string_builder* png = png_encode_rgba(width, height, pixels)
	wstream* out = stream_open_write(path)
	if (out == 0):
		string_free(png)
		return 0
	stream_write(out, png.data, png.length)
	io_result close_result
	int status = stream_close_checked(out, &close_result)
	string_free(png)
	return status == IO_OK


# Load a LUT strip PNG (N*N x N) into s. Returns 1 on success.
int photo_load_lut_file(photo_settings* s, char* path):
	rgba_image* lut = photo_load(path)
	if (lut == 0): return 0
	int size = fx_lut_strip_size(lut.width, lut.height)
	if (size == 0):
		print_error(c"photo: a LUT strip is N*N wide and N tall (N = 2..64): ")
		print_error(path)
		print_error(c"\n")
		rgba_image_free(lut)
		return 0
	s.lut_file = lut.pixels
	s.lut_file_size = size
	s.lut_preset = 0 - 1
	free(lut)
	return 1


########################## command-line flags #########################

float32 photo_flag_float(char* name, float32 fallback):
	char* value = args_value(name)
	if (value == 0): return fallback
	return parse_float(value, 0)


# Fill s from the command line (see photo_fx.w's usage text). Returns
# 0 after printing the problem.
int photo_settings_from_args(photo_settings* s):
	photo_settings_init(s)
	s.brightness = photo_flag_float(c"brightness", s.brightness)
	s.contrast = photo_flag_float(c"contrast", s.contrast)
	s.saturation = photo_flag_float(c"saturation", s.saturation)
	s.gamma = photo_flag_float(c"gamma", s.gamma)
	s.black = photo_flag_float(c"black", s.black)
	s.white = photo_flag_float(c"white", s.white)
	s.blur = photo_flag_float(c"blur", s.blur)
	if (args_has_flag(c"sharpen")): s.sharpen = photo_flag_float(c"sharpen", 1.0)
	s.edges = args_has_bool_flag(c"edges")
	s.emboss = args_has_bool_flag(c"emboss")
	if (args_has_flag(c"vignette")): s.vignette = photo_flag_float(c"vignette", 0.5)
	s.vignette_radius = photo_flag_float(c"vignette-radius", s.vignette_radius)
	s.vignette_softness = photo_flag_float(c"vignette-softness", s.vignette_softness)
	s.lut_amount = photo_flag_float(c"lut-amount", s.lut_amount)
	s.lut_size = cast(int, photo_flag_float(c"lut-size", 16.0))
	if ((s.lut_size < 2) || (s.lut_size > 64)):
		print_error(c"photo: --lut-size wants 2..64\n")
		return 0
	char* lut = args_value(c"lut")
	if (lut != 0):
		int preset = fx_lut_preset_named(lut)
		if (preset >= 0): s.lut_preset = preset
		else if (photo_load_lut_file(s, lut) == 0): return 0
	if (s.blur > cast(float32, fx_blur_max_radius)):
		print_error(c"photo: --blur is capped at ")
		print_error(itoa(fx_blur_max_radius))
		print_error(c" pixels\n")
		s.blur = cast(float32, fx_blur_max_radius)
	return 1
