# wbuild: target=wfuzz_png_smoke tag=tests dep=wfuzz data=tools/fuzz/seeds/png/ data=tests/data/color_glyphs/bitmap.png data=tests/data/color_glyphs/colr.png
# wbuild: step="bin/wv2 --coverage tools/fuzz/harness_png.w -o bin/wfuzz_png_harness"
# wbuild: step="rm -rf bin/wfuzz_png_smoke"
# wbuild: step="bin/wfuzz --binary bin/wfuzz_png_harness --bytes --ext .png --corpus tools/fuzz/seeds/png --corpus tests/data/color_glyphs/bitmap.png --corpus tests/data/color_glyphs/colr.png --out bin/wfuzz_png_smoke --cases 0 --fail-on-findings" expect_stdout="crashes: 0" timeout=300000
# wbuild: target=wfuzz_png tag=fuzz_campaign dep=wfuzz
# wbuild: step="bin/wv2 --coverage tools/fuzz/harness_png.w -o bin/wfuzz_png_harness"
# wbuild: step="bin/wfuzz --binary bin/wfuzz_png_harness --bytes --ext .png --corpus tools/fuzz/seeds/png --corpus tests/data/color_glyphs/bitmap.png --corpus tests/data/color_glyphs/colr.png --out bin/wfuzz_png" timeout=3600000
# Fuzz harness for graphics/image/png.w's decoder, driven directly
# rather than through the color-font path (issue #909). Each input is
# decoded three ways, all under 1024x1024 / 4 MiB limits:
#   - as given (signature, chunk framing, CRCs, chunk ordering);
#   - with every complete chunk's CRC recomputed first, so mutations of
#     IHDR/PLTE/tRNS/IDAT bodies reach the code behind the CRC check;
#   - synthesized: when the input is at least 4 bytes, its first bytes
#     pick a small width, height and color type (and a palette and
#     tRNS for indexed color), and the rest becomes the zlib-compressed
#     scanline data of an otherwise valid PNG, so the filter and
#     color-conversion code sees arbitrary filter bytes and samples.
# Invariants on every decoded image: dimensions within the limits,
# length == width * height * 4, and png_encode_rgba of the pixels
# decodes back to identical pixels; the same input under a limit one
# pixel narrower must fail with IMAGE_LIMIT. Seeds are small PNGs of
# every supported color type and filter (mirroring
# graphics/image/png_test.w) plus the color-glyph PNG fixtures.
import tools.fuzz.harness
import lib.bytes
import graphics.image.png


image_limits* fh_png_limits(int width):
	return new image_limits(16777216, width, 1024, 4194304)


void fh_png_check_image(rgba_image* image, image_limits* limits):
	fh_check((image.width >= 1) && (image.height >= 1), c"decoded image has an empty dimension")
	fh_check((image.width <= limits.width) && (image.height <= limits.height), c"decoded image exceeds the limits")
	fh_check(image.length == image.width * image.height * 4, c"pixel buffer length is not width * height * 4")
	fh_check(image.length <= limits.rgba_bytes, c"pixel buffer exceeds rgba_bytes")
	string_builder* png = png_encode_rgba(image.width, image.height, image.pixels)
	wresult[rgba_image*]* back = png_decode_n(png.data, png.length, limits)
	fh_check(result_is_error[rgba_image*](back) == 0, c"png_encode_rgba output does not decode")
	rgba_image* again = result_value[rgba_image*](back)
	fh_check((again.width == image.width) && (again.height == image.height), c"re-encoded image changed size")
	fh_check(fh_bytes_equal(again.pixels, image.pixels, image.length), c"re-encoded image changed pixels")
	rgba_image_free(again)
	free(back)
	string_free(png)


int fh_png_decode(char* data, int length):
	image_limits* limits = fh_png_limits(1024)
	wresult[rgba_image*]* r = png_decode_n(data, length, limits)
	int ok = result_is_error[rgba_image*](r) == 0
	int width = 0
	if (ok):
		rgba_image* image = result_value[rgba_image*](r)
		fh_png_check_image(image, limits)
		width = image.width
		rgba_image_free(image)
	free(r)
	free(limits)
	if (ok && (width > 1)):
		image_limits* narrow = fh_png_limits(width - 1)
		wresult[rgba_image*]* n = png_decode_n(data, length, narrow)
		fh_check(result_is_error[rgba_image*](n) && (n.code == IMAGE_LIMIT), c"an image wider than the limit decoded")
		free(n)
		free(narrow)
	return ok


# A copy of the input with each complete chunk's CRC recomputed.
char* fh_png_fix_crcs(char* data, int length):
	char* copy = cast(char*, malloc(length + 1))
	mem_copy(copy, data, length)
	int pos = 8
	while ((pos + 12 <= length) && ((copy[pos] & 128) == 0)):
		int size = load_be32(copy + pos)
		if (size > length - pos - 12): return copy
		store_be32(copy + pos + 8 + size, crc32_of(copy + pos + 4, size + 4))
		pos = pos + 12 + size
	return copy


int fh_png_min(int a, int b):
	if (a < b): return a
	return b


void fh_png_chunk(string_builder* out, char* kind, char* body, int size):
	string_append_be32(out, size)
	int start = out.length
	string_append_bytes(out, kind, 4)
	if (size > 0): string_append_bytes(out, body, size)
	string_append_be32(out, crc32_of(out.data + start, size + 4))


int fh_png_synthesized(char* data, int length):
	if (length < 4): return 0
	int width = (data[0] & 15) + 1
	int height = ((data[0] >> 4) & 15) + 1
	char[5] colors
	colors[0] = 0
	colors[1] = 2
	colors[2] = 3
	colors[3] = 4
	colors[4] = 6
	int color = colors[(data[1] & 255) % 5]
	int palette_count = (data[2] & 255) + 1
	int trns = data[3] & 255
	string_builder* out = string_new()
	string_append_char(out, 137)
	string_append(out, c"PNG\r\n")
	string_append_char(out, 26)
	string_append_char(out, 10)
	char[13] header
	store_be32(&header[0], width)
	store_be32(&header[4], height)
	header[8] = 8
	header[9] = color
	header[10] = 0
	header[11] = 0
	header[12] = 0
	fh_png_chunk(out, c"IHDR", &header[0], 13)
	if (color == 3):
		char[768] palette
		for i in range(768): palette[i] = (i * 37) & 255
		fh_png_chunk(out, c"PLTE", &palette[0], palette_count * 3)
		if ((trns > 0) && (trns <= palette_count)): fh_png_chunk(out, c"tRNS", data + 4, fh_png_min(trns, length - 4))
	else if ((color == 0) && ((trns & 1) != 0)): fh_png_chunk(out, c"tRNS", c"\x00\x10", 2)
	else if ((color == 2) && ((trns & 1) != 0)): fh_png_chunk(out, c"tRNS", c"\x00\x10\x00\x20\x00\x30", 6)
	zlib_result* z = zlib_compress(data + 4, length - 4, 1)
	fh_png_chunk(out, c"IDAT", z.data, z.length)
	zlib_result_free(z)
	fh_png_chunk(out, c"IEND", c"", 0)
	int ok = fh_png_decode(out.data, out.length)
	string_free(out)
	return ok


int main(int argc, int argv):
	int length = 0
	char* data = fh_input(argc, argv, &length)
	int ok = fh_png_decode(data, length)
	if (length >= 8):
		char* fixed = fh_png_fix_crcs(data, length)
		if (fh_png_decode(fixed, length)): ok = 1
		free(fixed)
	if (fh_png_synthesized(data, length)): ok = 1
	if (ok): return 0
	return 1
