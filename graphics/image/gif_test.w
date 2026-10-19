# wbuild: name=graphics_image_gif_test x64
import lib.testing
import graphics.image.gif
import tests.images.gif_fixtures

void gif_test_golden(char* data, int length, char* expected, int width, int height):
	wresult[rgba_image*]* result = gif_decode_n(data, length, 0)
	asserts(c"GIF decode", result.ok)
	rgba_image* image = result.value
	assert_equal(width, image.width)
	assert_equal(height, image.height)
	assert_equal(width * height * 4, image.length)
	for i in range(image.length): assert_equal(expected[i] & 255, image.pixels[i] & 255)
	rgba_image_free(image)
	free(result)

void test_gif_palette_offset_transparency_interlace():
	gif_test_golden(gif_fixture_offset(), gif_fixture_offset_length, gif_golden_offset(), 3, 3)
	gif_test_golden(gif_fixture_background(), gif_fixture_background_length, gif_golden_background(), 3, 2)
	gif_test_golden(gif_fixture_interlace(), gif_fixture_interlace_length, gif_golden_interlace(), 3, 9)

void test_gif_lzw_growth_clear_and_deferred_clear():
	gif_test_golden(gif_fixture_kwkwk(), gif_fixture_kwkwk_length, gif_golden_kwkwk(), 7, 1)
	gif_test_golden(gif_fixture_deferred(), gif_fixture_deferred_length, gif_golden_deferred(), 5000, 1)
	gif_test_golden(gif_fixture_pillow(), gif_fixture_pillow_length, gif_golden_pillow(), 80, 80)

void test_gif_truncation_and_corruption():
	char* data = gif_fixture_offset()
	int length = gif_fixture_offset_length
	# The first-image API requires all image data; the later trailer is optional.
	for size in range(length - 1):
		wresult[rgba_image*]* result = gif_decode_n(data, size, 0)
		assert_equal(0, result.ok)
		free(result)
	wresult[rgba_image*]* result = gif_decode_n(data, length - 1, 0)
	assert_equal(1, result.ok)
	rgba_image_free(result.value)
	free(result)
	char* broken = cast(char*, malloc(length))
	for pos in range(length):
		for i in range(length): broken[i] = data[i]
		broken[pos] = 255
		result = gif_decode_n(broken, length, 0)
		if (result.ok): rgba_image_free(result.value)
		free(result)
	for i in range(length): broken[i] = data[i]
	broken[4] = '7'
	result = gif_decode_n(broken, length, 0)
	assert_equal(1, result.ok)
	rgba_image_free(result.value)
	free(result)
	free(broken)
	result = gif_decode_n(c"not gif", 7, 0)
	assert_equal(IMAGE_BAD_FORMAT, result.code)
	free(result)
	result = gif_decode_n(0, 1, 0)
	assert_equal(IMAGE_BAD_FORMAT, result.code)
	free(result)

void test_gif_limits_and_work():
	image_limits* limits = image_default_limits()
	limits.width = 2
	wresult[rgba_image*]* result = gif_decode_n(gif_fixture_offset(), gif_fixture_offset_length, limits)
	assert_equal(IMAGE_LIMIT, result.code)
	free(result)
	limits.width = 8192
	limits.rgba_bytes = 35
	result = gif_decode_n(gif_fixture_offset(), gif_fixture_offset_length, limits)
	assert_equal(IMAGE_LIMIT, result.code)
	free(result)
	limits.rgba_bytes = 67108864
	limits.input_bytes = 4
	result = gif_decode_n(gif_fixture_offset(), gif_fixture_offset_length, limits)
	assert_equal(IMAGE_LIMIT, result.code)
	free(result)
	limits.input_bytes = 16777216
	gif_decoder d
	d.error = 0
	d.bits = 0
	d.bit_count = 0
	d.block_left = 0
	d.data = gif_fixture_offset()
	d.length = gif_fixture_offset_length
	d.pos = 6
	d.work = 1
	rgba_image* image = gif_first_image(&d, limits)
	asserts(c"work exhaustion releases partial image", image == 0)
	assert_equal(IMAGE_LIMIT, d.error)
	free(limits)

void gif_test_bad(char* data, int length):
	wresult[rgba_image*]* result = gif_decode_n(data, length, 0)
	assert_equal(IMAGE_COMPRESSED_DATA, result.code)
	free(result)

void test_gif_invalid_lzw():
	gif_test_bad(gif_bad_no_clear(), gif_bad_no_clear_length)
	gif_test_bad(gif_bad_bad_code(), gif_bad_bad_code_length)
	gif_test_bad(gif_bad_too_many(), gif_bad_too_many_length)
	gif_test_bad(gif_bad_too_few(), gif_bad_too_few_length)
	gif_test_bad(gif_bad_no_eoi(), gif_bad_no_eoi_length)
