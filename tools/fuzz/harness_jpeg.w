# wbuild: target=wfuzz_jpeg_smoke tag=tests dep=wfuzz data=tools/fuzz/seeds/jpeg/
# wbuild: step="bin/wv2 --coverage tools/fuzz/harness_jpeg.w -o bin/wfuzz_jpeg_harness"
# wbuild: step="rm -rf bin/wfuzz_jpeg_smoke"
# wbuild: step="bin/wfuzz --binary bin/wfuzz_jpeg_harness --bytes --ext .jpg --corpus tools/fuzz/seeds/jpeg --out bin/wfuzz_jpeg_smoke --cases 0 --fail-on-findings" expect_stdout="crashes: 0" timeout=300000
# wbuild: target=wfuzz_jpeg tag=fuzz_campaign dep=wfuzz
# wbuild: step="bin/wv2 --coverage tools/fuzz/harness_jpeg.w -o bin/wfuzz_jpeg_harness"
# wbuild: step="bin/wfuzz --binary bin/wfuzz_jpeg_harness --bytes --ext .jpg --corpus tools/fuzz/seeds/jpeg --out bin/wfuzz_jpeg" timeout=3600000
# Fuzz harness for graphics/image/jpeg.w's baseline decoder, driven
# directly rather than through the color-font path (issue #909): marker
# segments (DQT, DHT, SOF0, DRI, SOS, APP14 Adobe), Huffman decoding,
# restart intervals, chroma subsampling, the IDCT and color conversion,
# under 1024x1024 / 4 MiB limits.
# Invariants on every decoded image: dimensions within the limits,
# length == width * height * 4, every alpha byte 255, and a second
# decode of the same bytes gives identical pixels (no state leaks
# between decoders, no reads of uninitialized memory that differ run to
# run); the same input under a limit one pixel narrower must fail with
# IMAGE_LIMIT. A decode of every proper prefix of short inputs must not
# crash either (truncation is the most common real-world damage). Seeds
# are tests/images/jpeg_fixtures.w's gray, 4:4:4 color, 4:2:0, 4:2:2,
# restart-interval and (rejected, unsupported) progressive fixtures.
import tools.fuzz.harness
import graphics.image.jpeg


image_limits* fh_jpeg_limits(int width):
	return new image_limits(16777216, width, 1024, 4194304)


int fh_jpeg_decode(char* data, int length, int check):
	image_limits* limits = fh_jpeg_limits(1024)
	wresult[rgba_image*]* r = jpeg_decode_n(data, length, limits)
	int ok = result_is_error[rgba_image*](r) == 0
	int width = 0
	if (ok && check):
		rgba_image* image = result_value[rgba_image*](r)
		fh_check((image.width >= 1) && (image.height >= 1), c"decoded image has an empty dimension")
		fh_check((image.width <= limits.width) && (image.height <= limits.height), c"decoded image exceeds the limits")
		fh_check(image.length == image.width * image.height * 4, c"pixel buffer length is not width * height * 4")
		for i in range(image.width * image.height): fh_check((image.pixels[i * 4 + 3] & 255) == 255, c"JPEG pixel alpha is not 255")
		wresult[rgba_image*]* again = jpeg_decode_n(data, length, limits)
		fh_check(result_is_error[rgba_image*](again) == 0, c"second decode of the same bytes failed")
		rgba_image* second = result_value[rgba_image*](again)
		fh_check((second.length == image.length) && fh_bytes_equal(second.pixels, image.pixels, image.length), c"second decode gave different pixels")
		rgba_image_free(second)
		free(again)
		width = image.width
	if (ok): rgba_image_free(result_value[rgba_image*](r))
	free(r)
	free(limits)
	if (width > 1):
		image_limits* narrow = fh_jpeg_limits(width - 1)
		wresult[rgba_image*]* n = jpeg_decode_n(data, length, narrow)
		fh_check(result_is_error[rgba_image*](n) && (n.code == IMAGE_LIMIT), c"an image wider than the limit decoded")
		free(n)
		free(narrow)
	return ok


int main(int argc, int argv):
	int length = 0
	char* data = fh_input(argc, argv, &length)
	if (length <= 1024):
		for n in range(length): fh_jpeg_decode(data, n, 0)
	if (fh_jpeg_decode(data, length, 1)): return 0
	return 1
