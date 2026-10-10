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


string_builder* png_test_encode(int width, int height, int color, char* pixels, int length):
	string_builder* out = string_new()
	string_append_char(out, 137)
	string_append(out, c"PNG\r\n")
	string_append_char(out, 26)
	string_append_char(out, 10)
	string_builder* header = string_new()
	png_test_be32(header, width)
	png_test_be32(header, height)
	string_append_char(header, 8)
	string_append_char(header, color)
	string_append_char(header, 0)
	string_append_char(header, 0)
	string_append_char(header, 0)
	png_test_chunk(out, c"IHDR", header.data, header.length)
	string_free(header)
	if (color == 3):
		char[6] palette
		palette[0] = 255
		palette[1] = 0
		palette[2] = 0
		palette[3] = 0
		palette[4] = 255
		palette[5] = 0
		png_test_chunk(out, c"PLTE", &palette[0], 6)
		char[2] alpha
		alpha[0] = 0
		alpha[1] = 128
		png_test_chunk(out, c"tRNS", &alpha[0], 2)
	zlib_result* compressed = zlib_compress(pixels, length, DEFLATE_LEVEL_FAST())
	png_test_chunk(out, c"IDAT", compressed.data, compressed.length)
	zlib_result_free(compressed)
	png_test_chunk(out, c"IEND", c"", 0)
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
