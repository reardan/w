# wbuild: name=graphics_image_jpeg_test x64
import lib.testing
import structures.string
import graphics.image.jpeg
import tests.images.jpeg_fixtures

void jpeg_test_golden(char* data, int length, char* expected, int width, int height):
	wresult[rgba_image*]* result = jpeg_decode_n(data, length, 0)
	asserts(c"JPEG decode", result.ok)
	rgba_image* image = result.value
	assert_equal(width, image.width)
	assert_equal(height, image.height)
	assert_equal(width * height * 4, image.length)
	for i in range(image.length):
		int error = (image.pixels[i] & 255) - (expected[i] & 255)
		asserts(c"IDCT matches independent decoder within rounding", (error >= -2) && (error <= 2))
		if ((i % 4) == 3): assert_equal(255, image.pixels[i] & 255)
	rgba_image_free(image)
	free(result)

void test_jpeg_baseline_pixels_and_sampling():
	jpeg_test_golden(jpeg_fixture_gray(), jpeg_fixture_gray_length, jpeg_golden_gray(), 9, 9)
	jpeg_test_golden(jpeg_fixture_color(), jpeg_fixture_color_length, jpeg_golden_color(), 13, 9)
	jpeg_test_golden(jpeg_fixture_420(), jpeg_fixture_420_length, jpeg_golden_420(), 17, 17)
	jpeg_test_golden(jpeg_fixture_422(), jpeg_fixture_422_length, jpeg_golden_422(), 17, 17)
	jpeg_test_golden(jpeg_fixture_restart(), jpeg_fixture_restart_length, jpeg_golden_restart(), 9, 8)

void test_jpeg_truncated_and_unsupported():
	char* data = jpeg_fixture_gray()
	for length in range(jpeg_fixture_gray_length):
		wresult[rgba_image*]* result = jpeg_decode_n(data, length, 0)
		assert_equal(0, result.ok)
		free(result)
	wresult[rgba_image*]* result = jpeg_decode_n(jpeg_fixture_progressive(), jpeg_fixture_progressive_length, 0)
	assert_equal(0, result.ok)
	assert_equal(IMAGE_UNSUPPORTED, result.code)
	free(result)
	result = jpeg_decode_n(c"not jpeg", 8, 0)
	assert_equal(IMAGE_BAD_FORMAT, result.code)
	free(result)
	result = jpeg_decode_n(0, 1, 0)
	assert_equal(IMAGE_BAD_FORMAT, result.code)
	free(result)

void test_jpeg_limits_and_corruption():
	image_limits* limits = image_default_limits()
	limits.width = 8
	wresult[rgba_image*]* result = jpeg_decode_n(jpeg_fixture_gray(), jpeg_fixture_gray_length, limits)
	assert_equal(IMAGE_LIMIT, result.code)
	free(result)
	limits.width = 8192
	limits.rgba_bytes = 323
	result = jpeg_decode_n(jpeg_fixture_gray(), jpeg_fixture_gray_length, limits)
	assert_equal(IMAGE_LIMIT, result.code)
	free(result)
	limits.rgba_bytes = 67108864
	limits.input_bytes = 4
	result = jpeg_decode_n(jpeg_fixture_gray(), jpeg_fixture_gray_length, limits)
	assert_equal(IMAGE_LIMIT, result.code)
	free(result)
	free(limits)
	int length = jpeg_fixture_restart_length
	char* broken = cast(char*, malloc(length))
	for i in range(length): broken[i] = jpeg_fixture_restart()[i]
	# Corrupt the restart sequence and require an explicit failure.
	broken[length - 5] = 215
	result = jpeg_decode_n(broken, length, 0)
	assert_equal(0, result.ok)
	free(result)
	# Every one-byte mutation must either decode bounded pixels or fail cleanly.
	for i in range(length):
		for j in range(length): broken[j] = jpeg_fixture_restart()[j]
		broken[i] = 255
		result = jpeg_decode_n(broken, length, 0)
		if (result.ok): rgba_image_free(result.value)
		free(result)
	free(broken)

void jpeg_test_put(string_builder* s, int value, int size, int little):
	for i in range(size):
		int shift = (size - 1 - i) * 8
		if (little): shift = i * 8
		string_append_char(s, (value >> shift) & 255)

# APP1 Exif segment: TIFF header, IFD0 with a Make entry then an
# orientation entry of the given type/count/value, next-IFD 0.
string_builder* jpeg_test_exif(int little, int type, int count, int value):
	string_builder* tiff = string_new()
	if (little): string_append(tiff, c"II")
	else: string_append(tiff, c"MM")
	jpeg_test_put(tiff, 42, 2, little)
	jpeg_test_put(tiff, 8, 4, little)
	jpeg_test_put(tiff, 2, 2, little)
	jpeg_test_put(tiff, 271, 2, little)
	jpeg_test_put(tiff, 2, 2, little)
	jpeg_test_put(tiff, 2, 4, little)
	string_append_bytes(tiff, c"W\x00\x00\x00", 4)
	jpeg_test_put(tiff, 274, 2, little)
	jpeg_test_put(tiff, type, 2, little)
	jpeg_test_put(tiff, count, 4, little)
	jpeg_test_put(tiff, value, 2, little)
	jpeg_test_put(tiff, 0, 2, little)
	jpeg_test_put(tiff, 0, 4, little)
	string_builder* segment = string_new()
	string_append_char(segment, 255)
	string_append_char(segment, 225)
	jpeg_test_put(segment, tiff.length + 8, 2, 0)
	string_append_bytes(segment, c"Exif", 5)
	string_append_char(segment, 0)
	string_append_bytes(segment, tiff.data, tiff.length)
	string_free(tiff)
	return segment

# A copy of `jpeg` with `segment` inserted right after SOI.
string_builder* jpeg_test_insert(char* jpeg, int length, string_builder* segment):
	string_builder* out = string_new()
	string_append_bytes(out, jpeg, 2)
	string_append_bytes(out, segment.data, segment.length)
	string_append_bytes(out, jpeg + 2, length - 2)
	return out

int jpeg_test_orientation_of(int little, int type, int count, int value):
	string_builder* segment = jpeg_test_exif(little, type, count, value)
	string_builder* jpeg = jpeg_test_insert(jpeg_fixture_color(), jpeg_fixture_color_length, segment)
	int orientation = jpeg_decode_orientation(jpeg.data, jpeg.length)
	string_free(jpeg)
	string_free(segment)
	return orientation

void test_rgba_image_apply_orientation():
	# Labels of a 3x2 image (row 0: 0 1 2, row 1: 3 4 5) after each tag.
	char* expected = c"012345210543543210345012031425304152524130251403"
	for orientation in range(1, 9):
		rgba_image* image = new rgba_image(3, 2, 24, cast(char*, malloc(24)))
		for i in range(6):
			image.pixels[i * 4] = '0' + i
			image.pixels[i * 4 + 1] = i * 10
			image.pixels[i * 4 + 2] = 255 - i
			image.pixels[i * 4 + 3] = i * 40
		assert_equal(1, rgba_image_apply_orientation(image, orientation))
		if (orientation >= 5):
			assert_equal(2, image.width)
			assert_equal(3, image.height)
		else:
			assert_equal(3, image.width)
			assert_equal(2, image.height)
		assert_equal(24, image.length)
		for i in range(6):
			int label = expected[(orientation - 1) * 6 + i] - '0'
			assert_equal('0' + label, image.pixels[i * 4] & 255)
			assert_equal(label * 10, image.pixels[i * 4 + 1] & 255)
			assert_equal(255 - label, image.pixels[i * 4 + 2] & 255)
			assert_equal(label * 40, image.pixels[i * 4 + 3] & 255)
		rgba_image_free(image)
	rgba_image* image = new rgba_image(1, 1, 4, cast(char*, malloc(4)))
	assert_equal(0, rgba_image_apply_orientation(image, 0))
	assert_equal(0, rgba_image_apply_orientation(image, 9))
	assert_equal(0, rgba_image_apply_orientation(0, 6))
	rgba_image_free(image)

void test_jpeg_exif_orientation():
	for little in range(2):
		for value in range(1, 9): assert_equal(value, jpeg_test_orientation_of(little, 3, 1, value))
		# Wrong type, count or value fall back to upright.
		assert_equal(1, jpeg_test_orientation_of(little, 4, 1, 6))
		assert_equal(1, jpeg_test_orientation_of(little, 3, 2, 6))
		assert_equal(1, jpeg_test_orientation_of(little, 3, 1, 9))
		assert_equal(1, jpeg_test_orientation_of(little, 3, 1, 0))
	# JPEGs without Exif, and non-JPEG input, are upright.
	assert_equal(1, jpeg_decode_orientation(jpeg_fixture_color(), jpeg_fixture_color_length))
	assert_equal(1, jpeg_decode_orientation(c"not jpeg", 8))
	assert_equal(1, jpeg_decode_orientation(0, 4))
	string_builder* segment = jpeg_test_exif(0, 3, 1, 6)
	string_builder* jpeg = jpeg_test_insert(jpeg_fixture_color(), jpeg_fixture_color_length, segment)
	# Every prefix parses without reading past its end.
	for n in range(jpeg.length): jpeg_decode_orientation(jpeg.data, n)
	# Corrupt header pieces: byte order, magic, IFD offset, entry count.
	char* d = jpeg.data
	d[12] = 'X'
	assert_equal(1, jpeg_decode_orientation(d, jpeg.length))
	d[12] = 'M'
	d[15] = 43
	assert_equal(1, jpeg_decode_orientation(d, jpeg.length))
	d[15] = 42
	d[16] = 128
	assert_equal(1, jpeg_decode_orientation(d, jpeg.length))
	d[16] = 0
	d[19] = 200
	assert_equal(1, jpeg_decode_orientation(d, jpeg.length))
	d[19] = 8
	d[21] = 40
	assert_equal(1, jpeg_decode_orientation(d, jpeg.length))
	d[21] = 2
	assert_equal(6, jpeg_decode_orientation(d, jpeg.length))
	# Decoding with orientation rotates the decoded pixels 90 degrees.
	wresult[rgba_image*]* plain = jpeg_decode_n(jpeg.data, jpeg.length, 0)
	wresult[rgba_image*]* oriented = jpeg_decode_oriented_n(jpeg.data, jpeg.length, 0)
	asserts(c"oriented decode", plain.ok && oriented.ok)
	assert_equal(13, plain.value.width)
	assert_equal(9, oriented.value.width)
	assert_equal(13, oriented.value.height)
	rgba_image_apply_orientation(plain.value, 6)
	assert_bytes_equal(plain.value.pixels, oriented.value.pixels, plain.value.length)
	rgba_image_free(plain.value)
	rgba_image_free(oriented.value)
	free(plain)
	free(oriented)
	string_free(jpeg)
	string_free(segment)
