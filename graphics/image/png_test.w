# wbuild: x64
import lib.testing
import graphics.image.png


void png_test_be32(string_builder* out, int n):
	string_append_char(out, shr(n, 24) & 255)
	string_append_char(out, shr(n, 16) & 255)
	string_append_char(out, shr(n, 8) & 255)
	string_append_char(out, n & 255)


void png_test_chunk(string_builder* out, char* kind, char* bytes, int length):
	png_test_be32(out, length)
	int start = out.length
	string_append_bytes(out, kind, 4)
	string_append_bytes(out, bytes, length)
	png_test_be32(out, crc32_of(out.data + start, length + 4))


# A PNG with the given IHDR fields, optional PLTE/tRNS bodies (0 to
# omit) and already filtered scanline bytes.
string_builder* png_test_build(int width, int height, int depth, int color, int interlace, string_builder* palette, string_builder* transparency, char* pixels, int length):
	string_builder* out = string_new()
	string_append_char(out, 137)
	string_append(out, c"PNG\r\n")
	string_append_char(out, 26)
	string_append_char(out, 10)
	string_builder* header = string_new()
	png_test_be32(header, width)
	png_test_be32(header, height)
	string_append_char(header, depth)
	string_append_char(header, color)
	string_append_char(header, 0)
	string_append_char(header, 0)
	string_append_char(header, interlace)
	png_test_chunk(out, c"IHDR", header.data, header.length)
	string_free(header)
	if (palette != 0): png_test_chunk(out, c"PLTE", palette.data, palette.length)
	if (transparency != 0): png_test_chunk(out, c"tRNS", transparency.data, transparency.length)
	zlib_result* compressed = zlib_compress(pixels, length, DEFLATE_LEVEL_FAST())
	png_test_chunk(out, c"IDAT", compressed.data, compressed.length)
	zlib_result_free(compressed)
	png_test_chunk(out, c"IEND", c"", 0)
	return out


string_builder* png_test_encode(int width, int height, int color, char* pixels, int length):
	if (color != 3): return png_test_build(width, height, 8, color, 0, 0, 0, pixels, length)
	string_builder* palette = string_new()
	string_append_char(palette, 255)
	string_append_char(palette, 0)
	string_append_char(palette, 0)
	string_append_char(palette, 0)
	string_append_char(palette, 255)
	string_append_char(palette, 0)
	string_builder* alpha = string_new()
	string_append_char(alpha, 0)
	string_append_char(alpha, 128)
	string_builder* out = png_test_build(width, height, 8, color, 0, palette, alpha, pixels, length)
	string_free(palette)
	string_free(alpha)
	return out


void png_test_error(char* bytes, int length, image_limits* limits, int code):
	wresult[rgba_image*]* result = png_decode_n(bytes, length, limits)
	assert_equal(code, result.code)
	assert_equal(0, result.ok)
	result_free[rgba_image*](result)


void test_png_rgba_transparent_and_filters():
	char[10] row
	row[0] = 0
	row[1] = 200
	row[2] = 50
	row[3] = 100
	row[4] = 128
	for filter in range(5):
		row[5] = filter
		for i in range(4):
			int value = row[i + 1] & 255
			# Single-pixel rows: left is zero, up is the first row.
			if (filter == 2 || filter == 4): value = 0
			if (filter == 3): value = value - value / 2
			row[i + 6] = value
		string_builder* bytes = png_test_encode(1, 2, 6, &row[0], 10)
		wresult[rgba_image*]* result = png_decode_n(bytes.data, bytes.length, 0)
		assert_equal(1, result.ok)
		rgba_image* image = result.value
		assert_equal(1, image.width)
		assert_equal(2, image.height)
		assert_equal(8, image.length)
		for i in range(4):
			assert_equal(row[i + 1] & 255, image.pixels[i] & 255)
			assert_equal(row[i + 1] & 255, image.pixels[i + 4] & 255)
		rgba_image_free(image)
		result_free[rgba_image*](result)
		string_free(bytes)


void test_png_palette_transparency():
	char[3] row
	row[0] = 0
	row[1] = 0
	row[2] = 1
	string_builder* bytes = png_test_encode(2, 1, 3, &row[0], 3)
	wresult[rgba_image*]* result = png_decode_n(bytes.data, bytes.length, 0)
	assert_equal(1, result.ok)
	assert_equal(255, result.value.pixels[0] & 255)
	assert_equal(0, result.value.pixels[3] & 255)
	assert_equal(255, result.value.pixels[5] & 255)
	assert_equal(128, result.value.pixels[7] & 255)
	rgba_image_free(result.value)
	result_free[rgba_image*](result)
	string_free(bytes)
	row[2] = 2
	bytes = png_test_encode(2, 1, 3, &row[0], 3)
	png_test_error(bytes.data, bytes.length, 0, IMAGE_BAD_FORMAT)
	string_free(bytes)


void test_png_gray_rgb_and_grayalpha():
	char[4] row
	row[0] = 0
	row[1] = 123
	row[2] = 45
	row[3] = 67
	int[3] colors
	colors[0] = 0
	colors[1] = 4
	colors[2] = 2
	for i in range(3):
		string_builder* bytes = png_test_encode(1, 1, colors[i], &row[0], i + 2)
		wresult[rgba_image*]* result = png_decode_n(bytes.data, bytes.length, 0)
		assert_equal(1, result.ok)
		assert_equal(123, result.value.pixels[0] & 255)
		if (i == 1): assert_equal(45, result.value.pixels[3] & 255)
		if (i == 2): assert_equal(67, result.value.pixels[2] & 255)
		rgba_image_free(result.value)
		result_free[rgba_image*](result)
		string_free(bytes)


void test_png_malformed_truncated_limits():
	char[5] row
	row[0] = 0
	row[1] = 255
	row[2] = 0
	row[3] = 0
	row[4] = 255
	string_builder* bytes = png_test_encode(1, 1, 6, &row[0], 5)
	for n in range(bytes.length):
		wresult[rgba_image*]* result = png_decode_n(bytes.data, n, 0)
		assert_equal(0, result.ok)
		result_free[rgba_image*](result)
	bytes.data[29] = bytes.data[29] ^ 1
	png_test_error(bytes.data, bytes.length, 0, IMAGE_CHECKSUM)
	bytes.data[29] = bytes.data[29] ^ 1
	image_limits* limits = image_default_limits()
	limits.input_bytes = 8
	png_test_error(bytes.data, bytes.length, limits, IMAGE_LIMIT)
	limits.input_bytes = 1000
	limits.rgba_bytes = 3
	png_test_error(bytes.data, bytes.length, limits, IMAGE_LIMIT)
	free(limits)
	string_free(bytes)
	bytes = png_test_encode(2147483647, 2147483647, 6, &row[0], 5)
	png_test_error(bytes.data, bytes.length, 0, IMAGE_LIMIT)
	string_free(bytes)
	bytes = png_test_encode(1, 1, 6, &row[0], 4)
	png_test_error(bytes.data, bytes.length, 0, IMAGE_COMPRESSED_DATA)
	string_free(bytes)
	bytes = png_test_encode(1, 1, 6, &row[0], 5)
	# Change the deflate body and recompute IDAT CRC: exercise zlib validation.
	bytes.data[43] = bytes.data[43] ^ 255
	int size = load_be32(bytes.data + 33)
	int crc = crc32_of(bytes.data + 37, size + 4)
	int offset = 41 + size
	bytes.data[offset] = shr(crc, 24) & 255
	bytes.data[offset + 1] = shr(crc, 16) & 255
	bytes.data[offset + 2] = shr(crc, 8) & 255
	bytes.data[offset + 3] = crc & 255
	png_test_error(bytes.data, bytes.length, 0, IMAGE_COMPRESSED_DATA)
	string_free(bytes)
	row[0] = 5
	bytes = png_test_encode(1, 1, 6, &row[0], 5)
	png_test_error(bytes.data, bytes.length, 0, IMAGE_BAD_FORMAT)
	string_free(bytes)


void test_png_rejects_trailing_zlib_data():
	char[2] row
	row[0] = 0
	row[1] = 128
	string_builder* bytes = png_test_encode(1, 1, 0, &row[0], 2)
	# Replace IEND with a second contiguous IDAT containing junk.
	bytes.length = bytes.length - 12
	bytes.data[bytes.length] = 0
	png_test_chunk(bytes, c"IDAT", c"junk", 4)
	png_test_chunk(bytes, c"IEND", c"", 0)
	png_test_error(bytes.data, bytes.length, 0, IMAGE_COMPRESSED_DATA)
	string_free(bytes)


void test_png_encode_round_trip():
	char[24] rgba
	for i in range(24): rgba[i] = i * 11
	string_builder* bytes = png_encode_rgba(3, 2, &rgba[0])
	wresult[rgba_image*]* decoded = png_decode_n(bytes.data, bytes.length, 0)
	assert1(decoded.ok)
	rgba_image* image = decoded.value
	assert_equal(3, image.width)
	assert_equal(2, image.height)
	assert_bytes_equal(&rgba[0], image.pixels, 24)
	rgba_image_free(image)
	free(cast(char*, decoded))
	string_free(bytes)


# Test-side Adam7 geometry (origin x, origin y, step x, step y), written
# out independently of the decoder's tables.
void png_test_adam7(int pass, int* geometry):
	char* table = c"\x00\x00\x08\x08\x04\x00\x08\x08\x00\x04\x04\x08\x02\x00\x04\x04\x00\x02\x02\x04\x01\x00\x02\x02\x00\x01\x01\x02"
	for i in range(4): geometry[i] = table[pass * 4 + i]


int png_test_channels(int color):
	if (color == 2): return 3
	if (color == 4): return 2
	if (color == 6): return 4
	return 1


# Packs samples[(y * width + x) * channels + c] (each below 2^depth) into
# scanlines with filter 0 (None) or 1 (Sub), as Adam7 passes when
# interlaced. Caller frees the builder.
string_builder* png_test_pack(int width, int height, int channels, int depth, int interlace, int filter, int* samples):
	string_builder* out = string_new()
	int passes = 1
	if (interlace): passes = 7
	int bits = channels * depth
	int pixel_bytes = (bits + 7) / 8
	int[4] geometry
	for pass in range(passes):
		geometry[0] = 0
		geometry[1] = 0
		geometry[2] = 1
		geometry[3] = 1
		if (interlace): png_test_adam7(pass, &geometry[0])
		int pass_width = 0
		for x in range(geometry[0], width, geometry[2]): pass_width = pass_width + 1
		if (pass_width == 0): continue
		int row_bytes = (pass_width * bits + 7) / 8
		char* row = cast(char*, malloc(row_bytes))
		for y in range(geometry[1], height, geometry[3]):
			for i in range(row_bytes): row[i] = 0
			int bit = 0
			for x in range(geometry[0], width, geometry[2]):
				for c in range(channels):
					int value = samples[(y * width + x) * channels + c]
					if (depth == 16):
						row[bit / 8] = value >> 8
						row[bit / 8 + 1] = value & 255
					else if (depth == 8): row[bit / 8] = value
					else: row[bit / 8] = (row[bit / 8] & 255) | (value << (8 - depth - bit % 8))
					bit = bit + depth
			if (filter == 1):
				int i = row_bytes - 1
				while (i >= pixel_bytes):
					row[i] = ((row[i] & 255) - (row[i - pixel_bytes] & 255)) & 255
					i = i - 1
			string_append_char(out, filter)
			string_append_bytes(out, row, row_bytes)
		free(row)
	return out


int png_test_to_8(int value, int depth):
	if (depth == 16): return value / 256
	return value * 255 / ((1 << depth) - 1)


int png_test_be16(string_builder* s, int offset):
	return ((s.data[offset] & 255) << 8) | (s.data[offset + 1] & 255)


# Expected straight RGBA for samples of the given color type and depth.
char* png_test_expected(int width, int height, int depth, int color, int* samples, string_builder* palette, string_builder* transparency):
	int channels = png_test_channels(color)
	char* rgba = cast(char*, malloc(width * height * 4))
	for i in range(width * height):
		int* s = &samples[i * channels]
		char* p = rgba + i * 4
		if (color == 3):
			p[0] = palette.data[s[0] * 3]
			p[1] = palette.data[s[0] * 3 + 1]
			p[2] = palette.data[s[0] * 3 + 2]
			p[3] = 255
			if (transparency != 0 && s[0] < transparency.length): p[3] = transparency.data[s[0]]
			continue
		p[0] = png_test_to_8(s[0], depth)
		if (color == 0 || color == 4):
			p[1] = p[0]
			p[2] = p[0]
		else:
			p[1] = png_test_to_8(s[1], depth)
			p[2] = png_test_to_8(s[2], depth)
		p[3] = 255
		if (color == 4): p[3] = png_test_to_8(s[1], depth)
		if (color == 6): p[3] = png_test_to_8(s[3], depth)
		if (transparency != 0 && color == 0 && s[0] == png_test_be16(transparency, 0)): p[3] = 0
		if (transparency != 0 && color == 2):
			if (s[0] == png_test_be16(transparency, 0) && s[1] == png_test_be16(transparency, 2) && s[2] == png_test_be16(transparency, 4)): p[3] = 0
	return rgba


# Encodes samples both ways (plain and Adam7) with both filters and
# requires the decoder to reproduce the independently computed RGBA.
void png_test_samples(int width, int height, int depth, int color, int* samples, string_builder* palette, string_builder* transparency):
	char* expected = png_test_expected(width, height, depth, color, samples, palette, transparency)
	for interlace in range(2):
		for filter in range(2):
			string_builder* raw = png_test_pack(width, height, png_test_channels(color), depth, interlace, filter, samples)
			string_builder* bytes = png_test_build(width, height, depth, color, interlace, palette, transparency, raw.data, raw.length)
			wresult[rgba_image*]* result = png_decode_n(bytes.data, bytes.length, 0)
			assert_equal(0, result.code)
			assert_equal(1, result.ok)
			assert_equal(width, result.value.width)
			assert_equal(height, result.value.height)
			assert_bytes_equal(expected, result.value.pixels, width * height * 4)
			rgba_image_free(result.value)
			result_free[rgba_image*](result)
			string_free(bytes)
			string_free(raw)
	free(expected)


int* png_test_sample_buffer(int count, int depth, int seed):
	int* samples = cast(int*, malloc(count * __word_size__))
	int state = seed
	for i in range(count):
		state = (state * 1103515245 + 12345) & 2147483647
		samples[i] = (state >> 8) & ((1 << depth) - 1)
	return samples


# tRNS body: one 16-bit gray key (count 1) or an RGB key (count 3).
string_builder* png_test_key(int a, int b, int c, int count):
	string_builder* s = string_new()
	string_append_char(s, (a >> 8) & 255)
	string_append_char(s, a & 255)
	if (count == 1): return s
	string_append_char(s, (b >> 8) & 255)
	string_append_char(s, b & 255)
	string_append_char(s, (c >> 8) & 255)
	string_append_char(s, c & 255)
	return s


void test_png_sixteen_bit_all_color_types():
	char* colors = c"\x00\x02\x04\x06"
	for k in range(4):
		int* samples = png_test_sample_buffer(5 * 3 * png_test_channels(colors[k]), 16, 77 + k)
		png_test_samples(5, 3, 16, colors[k], samples, 0, 0)
		free(samples)
	# 16-bit tRNS compares all 16 bits: pixel 1 matches exactly, pixel 2
	# differs only in the low byte and stays opaque.
	int* gray = png_test_sample_buffer(15, 16, 5)
	gray[2] = gray[1] ^ 1
	string_builder* key = png_test_key(gray[1], 0, 0, 1)
	png_test_samples(5, 3, 16, 0, gray, 0, key)
	string_free(key)
	free(gray)
	int* rgb = png_test_sample_buffer(45, 16, 6)
	rgb[6] = rgb[3]
	rgb[7] = rgb[4]
	rgb[8] = rgb[5] ^ 1
	key = png_test_key(rgb[3], rgb[4], rgb[5], 3)
	png_test_samples(5, 3, 16, 2, rgb, 0, key)
	string_free(key)
	free(rgb)


void test_png_packed_grayscale():
	for depth in range(1, 9):
		if (depth != 1 && depth != 2 && depth != 4 && depth != 8): continue
		for width in range(1, 14, 4):
			int* samples = png_test_sample_buffer(width * 3, depth, 11 + width)
			png_test_samples(width, 3, depth, 0, samples, 0, 0)
			# Packed tRNS gray is compared at the sample depth.
			string_builder* key = png_test_key(samples[0], 0, 0, 1)
			png_test_samples(width, 3, depth, 0, samples, 0, key)
			string_free(key)
			free(samples)


void test_png_packed_indexed():
	for depth in range(1, 9):
		if (depth != 1 && depth != 2 && depth != 4 && depth != 8): continue
		int entries = 1 << depth
		string_builder* palette = string_new()
		string_builder* alpha = string_new()
		for i in range(entries):
			string_append_char(palette, (i * 7) & 255)
			string_append_char(palette, (i * 13 + 5) & 255)
			string_append_char(palette, 255 - i)
			if (i < 3): string_append_char(alpha, i * 100)
		for width in range(1, 12, 5):
			int* samples = png_test_sample_buffer(width * 4, depth, 3 + width)
			png_test_samples(width, 4, depth, 3, samples, palette, alpha)
			png_test_samples(width, 4, depth, 3, samples, palette, 0)
			free(samples)
		# An index past a short palette is rejected even at packed depths.
		palette.length = 3
		int[2] indexes
		indexes[0] = 0
		indexes[1] = entries - 1
		string_builder* raw = png_test_pack(2, 1, 1, depth, 0, 0, &indexes[0])
		string_builder* bytes = png_test_build(2, 1, depth, 3, 0, palette, 0, raw.data, raw.length)
		png_test_error(bytes.data, bytes.length, 0, IMAGE_BAD_FORMAT)
		string_free(bytes)
		string_free(raw)
		string_free(palette)
		string_free(alpha)


void test_png_adam7_sizes():
	# Sizes leave some passes empty (1x1 has only pass 1) or partial.
	char* widths = c"\x01\x02\x03\x08\x09\x11"
	char* heights = c"\x01\x05\x02\x08\x0b\x03"
	for k in range(6):
		int w = widths[k]
		int h = heights[k]
		int* rgba = png_test_sample_buffer(w * h * 4, 8, 101 + k)
		png_test_samples(w, h, 8, 6, rgba, 0, 0)
		free(rgba)
		int* bits = png_test_sample_buffer(w * h, 1, 201 + k)
		png_test_samples(w, h, 1, 0, bits, 0, 0)
		free(bits)


void png_test_header_error(int depth, int color, int interlace):
	char[8] raw
	for i in range(8): raw[i] = 0
	string_builder* bytes = png_test_build(1, 1, depth, color, interlace, 0, 0, &raw[0], 3)
	png_test_error(bytes.data, bytes.length, 0, IMAGE_UNSUPPORTED)
	string_free(bytes)


void test_png_depth_validation_and_interlace_framing():
	# Invalid depth/color combinations and interlace methods.
	png_test_header_error(16, 3, 0)
	png_test_header_error(4, 2, 0)
	png_test_header_error(2, 6, 0)
	png_test_header_error(1, 4, 0)
	png_test_header_error(3, 0, 0)
	png_test_header_error(8, 0, 2)
	# Non-interlaced scanlines under an Adam7 header have the wrong length.
	int* samples = png_test_sample_buffer(9 * 9 * 3, 16, 9)
	string_builder* plain = png_test_pack(9, 9, 3, 16, 0, 0, samples)
	string_builder* bytes = png_test_build(9, 9, 16, 2, 1, 0, 0, plain.data, plain.length)
	png_test_error(bytes.data, bytes.length, 0, IMAGE_COMPRESSED_DATA)
	string_free(bytes)
	string_free(plain)
	# A bad filter byte on the last row of Adam7 pass 7 (9 RGB16 pixels,
	# 54 bytes after its filter byte) fails the whole image.
	string_builder* passes = png_test_pack(9, 9, 3, 16, 1, 0, samples)
	passes.data[passes.length - 1 - 9 * 6] = 9
	bytes = png_test_build(9, 9, 16, 2, 1, 0, 0, passes.data, passes.length)
	png_test_error(bytes.data, bytes.length, 0, IMAGE_BAD_FORMAT)
	string_free(bytes)
	string_free(passes)
	# Every truncated prefix of an interlaced 16-bit image fails cleanly.
	passes = png_test_pack(9, 9, 3, 16, 1, 1, samples)
	bytes = png_test_build(9, 9, 16, 2, 1, 0, 0, passes.data, passes.length)
	for n in range(bytes.length):
		wresult[rgba_image*]* result = png_decode_n(bytes.data, n, 0)
		assert_equal(0, result.ok)
		result_free[rgba_image*](result)
	# The width/height limits still apply to interlaced images.
	image_limits* limits = image_default_limits()
	limits.width = 8
	png_test_error(bytes.data, bytes.length, limits, IMAGE_LIMIT)
	free(limits)
	string_free(bytes)
	string_free(passes)
	free(samples)
