# wbuild: name=graphics_image_jpeg_test x64
import lib.testing
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
