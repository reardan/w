# wbuild: name=graphics_image_jpeg_encode_test x64
import lib.testing
import graphics.image.jpeg
import graphics.image.jpeg_encode


# 0..31..0 ramp with period 64, so slopes do not depend on image size.
int jpeg_encode_test_triangle(int v):
	v = v % 64
	if (v < 32): return v
	return 63 - v


# A smooth photo-like pattern: gradients plus a soft diagonal band.
char* jpeg_encode_test_pattern(int width, int height):
	char* rgba = cast(char*, malloc(width * height * 4))
	for y in range(height):
		for x in range(width):
			int i = (y * width + x) * 4
			int band = x + y
			if (band > 24): band = 48 - band
			if (band < 0): band = 0
			rgba[i] = 40 + jpeg_encode_test_triangle(x) * 5 + band * 2
			rgba[i + 1] = 30 + jpeg_encode_test_triangle(y) * 6
			rgba[i + 2] = 60 + jpeg_encode_test_triangle(x + y) * 4
			rgba[i + 3] = (x * 37) & 255
	return rgba


# Decodes `jpeg` and returns the mean squared RGB error (rounded up)
# against `rgba`, or -1 when decoding fails or the dimensions differ.
int jpeg_encode_test_mse(string_builder* jpeg, int width, int height, char* rgba):
	wresult[rgba_image*]* result = jpeg_decode_n(jpeg.data, jpeg.length, 0)
	if (!result.ok):
		free(result)
		return -1
	rgba_image* image = result.value
	free(result)
	if ((image.width != width) || (image.height != height)):
		rgba_image_free(image)
		return -1
	int sum = 0
	int samples = width * height * 3
	for i in range(width * height):
		for c in range(3):
			int error = (image.pixels[i * 4 + c] & 255) - (rgba[i * 4 + c] & 255)
			sum = sum + error * error
		assert_equal(255, image.pixels[i * 4 + 3] & 255)
	rgba_image_free(image)
	return (sum + samples - 1) / samples


void jpeg_encode_test_framing(string_builder* jpeg):
	char* d = jpeg.data
	asserts(c"starts with SOI", ((d[0] & 255) == 255) && ((d[1] & 255) == 216))
	asserts(c"APP0 follows SOI", ((d[2] & 255) == 255) && ((d[3] & 255) == 224))
	asserts(c"APP0 is JFIF", (d[6] == 'J') && (d[7] == 'F') && (d[8] == 'I') && (d[9] == 'F') && (d[10] == 0))
	int n = jpeg.length
	asserts(c"ends with EOI", ((d[n - 2] & 255) == 255) && ((d[n - 1] & 255) == 217))
	# Locate SOS and check every entropy-coded 0xff is stuffed.
	int pos = 2
	while (pos + 4 <= n):
		int marker = d[pos + 1] & 255
		int size = ((d[pos + 2] & 255) << 8) | (d[pos + 3] & 255)
		pos = pos + 2 + size
		if (marker == 218): break
	asserts(c"SOS found", pos < n)
	for i in range(pos, n - 2):
		if ((d[i] & 255) == 255): asserts(c"entropy 0xff is stuffed", d[i + 1] == 0)


void test_jpeg_encode_round_trip_sizes():
	int[7] widths
	int[7] heights
	widths[0] = 1
	heights[0] = 1
	widths[1] = 7
	heights[1] = 5
	widths[2] = 8
	heights[2] = 8
	widths[3] = 16
	heights[3] = 16
	widths[4] = 17
	heights[4] = 13
	widths[5] = 33
	heights[5] = 31
	widths[6] = 40
	heights[6] = 9
	for s in range(7):
		int w = widths[s]
		int h = heights[s]
		char* rgba = jpeg_encode_test_pattern(w, h)
		for mode in range(2):
			string_builder* jpeg = jpeg_encode_rgba_ex(w, h, rgba, 90, mode)
			jpeg_encode_test_framing(jpeg)
			int mse = jpeg_encode_test_mse(jpeg, w, h, rgba)
			# MSE 16 is a PSNR of about 36 dB, MSE 5 about 41 dB.
			asserts(c"round trip decodes", mse >= 0)
			if (mode == JPEG_SUBSAMPLE_444): asserts(c"4:4:4 q90 MSE <= 5 (PSNR >= 41 dB)", mse <= 5)
			else: asserts(c"4:2:0 q90 MSE <= 16 (PSNR >= 36 dB)", mse <= 16)
			string_free(jpeg)
		free(rgba)


void test_jpeg_encode_quality_scaling():
	int w = 24
	int h = 20
	char* rgba = jpeg_encode_test_pattern(w, h)
	int previous_mse = 1000000
	int previous_length = 0
	int[5] qualities
	qualities[0] = 1
	qualities[1] = 25
	qualities[2] = 50
	qualities[3] = 75
	qualities[4] = 100
	for i in range(5):
		string_builder* jpeg = jpeg_encode_rgba_ex(w, h, rgba, qualities[i], JPEG_SUBSAMPLE_444)
		jpeg_encode_test_framing(jpeg)
		int mse = jpeg_encode_test_mse(jpeg, w, h, rgba)
		asserts(c"quality decodes", mse >= 0)
		asserts(c"higher quality does not increase error", mse <= previous_mse)
		asserts(c"higher quality does not shrink output", jpeg.length >= previous_length)
		if (qualities[i] == 100): asserts(c"q100 MSE <= 2", mse <= 2)
		if (qualities[i] == 50): asserts(c"q50 MSE <= 12", mse <= 12)
		previous_mse = mse
		previous_length = jpeg.length
		string_free(jpeg)
	# Out-of-range qualities clamp instead of failing.
	string_builder* low = jpeg_encode_rgba(w, h, rgba, -5)
	string_builder* one = jpeg_encode_rgba(w, h, rgba, 1)
	assert_equal(one.length, low.length)
	assert_bytes_equal(one.data, low.data, low.length)
	string_free(low)
	string_free(one)
	string_builder* high = jpeg_encode_rgba(w, h, rgba, 1000)
	asserts(c"quality above 100 decodes", jpeg_encode_test_mse(high, w, h, rgba) >= 0)
	string_free(high)
	free(rgba)


void test_jpeg_encode_extremes_and_stuffing():
	# High-contrast noise drives large coefficients and 0xff entropy bytes.
	int w = 19
	int h = 21
	char* rgba = cast(char*, malloc(w * h * 4))
	int seed = 12345
	for i in range(w * h * 4):
		seed = (seed * 1103515245 + 12345) & 2147483647
		int value = 0
		if (((seed >> 16) & 1) != 0): value = 255
		rgba[i] = value
	for mode in range(2):
		for q in range(1, 101, 33):
			string_builder* jpeg = jpeg_encode_rgba_ex(w, h, rgba, q, mode)
			jpeg_encode_test_framing(jpeg)
			asserts(c"noise decodes", jpeg_encode_test_mse(jpeg, w, h, rgba) >= 0)
			string_free(jpeg)
	# Flat colors (including the gamut corners) survive almost exactly.
	for corner in range(8):
		for i in range(w * h):
			rgba[i * 4] = 255 * (corner & 1)
			rgba[i * 4 + 1] = 255 * ((corner >> 1) & 1)
			rgba[i * 4 + 2] = 255 * ((corner >> 2) & 1)
			rgba[i * 4 + 3] = 0
		string_builder* jpeg = jpeg_encode_rgba(w, h, rgba, 100)
		asserts(c"flat color MSE <= 4", jpeg_encode_test_mse(jpeg, w, h, rgba) <= 4)
		asserts(c"flat color decodes", jpeg_encode_test_mse(jpeg, w, h, rgba) >= 0)
		string_free(jpeg)
	free(rgba)


void test_jpeg_encode_rejects_invalid_arguments():
	char[4] pixel
	assert_equal(0, cast(int, jpeg_encode_rgba(0, 1, &pixel[0], 50)))
	assert_equal(0, cast(int, jpeg_encode_rgba(1, 0, &pixel[0], 50)))
	assert_equal(0, cast(int, jpeg_encode_rgba(65536, 1, &pixel[0], 50)))
	assert_equal(0, cast(int, jpeg_encode_rgba(1, 1, 0, 50)))
	assert_equal(0, cast(int, jpeg_encode_rgba_ex(1, 1, &pixel[0], 50, 7)))


void test_jpeg_encode_huffman_tables_cover_symbols():
	# Each AC table must code EOB, ZRL and every run/size pair exactly once.
	for t in range(2):
		char* table = jpeg_encode_ac_luma()
		if (t == 1): table = jpeg_encode_ac_chroma()
		assert_equal(162, jpeg_encode_table_symbols(table))
		int[256] seen
		for i in range(256): seen[i] = 0
		for i in range(162): seen[table[16 + i] & 255] = seen[table[16 + i] & 255] + 1
		assert_equal(1, seen[0])
		assert_equal(1, seen[240])
		for run in range(16):
			for size in range(1, 11): assert_equal(1, seen[run * 16 + size])
