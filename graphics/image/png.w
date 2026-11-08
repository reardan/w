# Bounded PNG decoder: every standard color type and bit depth (1-16),
# Adam7 interlace; output is 8-bit straight RGBA (16-bit keeps the MSB);
# png_encode_rgba writes plain RGBA PNGs (test goldens, tools).
import lib.lib
import lib.bytes
import lib.result
import structures.string
import libs.extras.compress.zlib
import libs.extras.compress.crc32


import graphics.image.image


int png_chunk_is(char* chunk, char* name):
	return chunk[0] == name[0] && chunk[1] == name[1] && chunk[2] == name[2] && chunk[3] == name[3]


int png_paeth(int a, int b, int c):
	int p = a + b - c
	int pa = p - a
	int pb = p - b
	int pc = p - c
	if (pa < 0): pa = -pa
	if (pb < 0): pb = -pb
	if (pc < 0): pc = -pc
	if (pa <= pb && pa <= pc): return a
	if (pb <= pc): return b
	return c


# Adam7 pass origins and steps (PNG spec 8.2), columns or rows.
int png_adam7_start(int pass, int vertical):
	if (vertical): return c"\x00\x00\x04\x00\x02\x00\x01"[pass]
	return c"\x00\x04\x00\x02\x00\x01\x00"[pass]


int png_adam7_step(int pass, int vertical):
	if (vertical): return c"\x08\x08\x08\x04\x04\x02\x02"[pass]
	return c"\x08\x08\x04\x04\x02\x02\x01"[pass]


# Pixels (vertical = 0) or rows (vertical = 1) of `size` in Adam7 pass
# `pass`; the single pass of a non-interlaced image covers everything.
int png_pass_size(int size, int pass, int interlace, int vertical):
	if (!interlace): return size
	int start = png_adam7_start(pass, vertical)
	int step = png_adam7_step(pass, vertical)
	if (size <= start): return 0
	return (size - start + step - 1) / step


# Undo one scanline's filter in place. The prior row, when present,
# directly precedes this row's filter byte.
void png_unfilter(char* row, int row_bytes, int pixel_bytes, int filter, int has_prior):
	for x in range(row_bytes):
		int left = 0
		int up = 0
		int upper_left = 0
		if (x >= pixel_bytes): left = row[x - pixel_bytes] & 255
		if (has_prior):
			up = row[x - row_bytes - 1] & 255
			if (x >= pixel_bytes): upper_left = row[x - row_bytes - 1 - pixel_bytes] & 255
		int value = row[x] & 255
		if (filter == 1): value = value + left
		if (filter == 2): value = value + up
		if (filter == 3): value = value + (left + up) / 2
		if (filter == 4): value = value + png_paeth(left, up, upper_left)
		row[x] = value & 255


# Sample `index` of an unfiltered row: packed big-endian bit fields for
# depths below 8, big-endian 16-bit words for depth 16.
int png_sample(char* row, int index, int depth):
	if (depth == 8): return row[index] & 255
	if (depth == 16): return ((row[index * 2] & 255) << 8) | (row[index * 2 + 1] & 255)
	int bit = index * depth
	return ((row[bit >> 3] & 255) >> (8 - depth - (bit & 7))) & ((1 << depth) - 1)


# Scale a gray/color/alpha sample to 8 bits: replicate packed samples,
# keep the most significant byte of 16-bit samples.
int png_sample_to_8(int sample, int depth):
	if (depth == 16): return sample >> 8
	if (depth == 4): return sample * 17
	if (depth == 2): return sample * 85
	if (depth == 1): return sample * 255
	return sample


# Internal borrowed limits, public wrapper installs defaults. A PNG owns
# no global state except compress.crc32's documented once-initialized table.
wresult[rgba_image*]* png_decode_impl(char* data, int length, image_limits* limits):
	if (length < 0 || (data == 0 && length != 0)): return result_new_error[rgba_image*](IMAGE_BAD_FORMAT)
	if (limits.input_bytes < 1 || limits.width < 1 || limits.height < 1 || limits.rgba_bytes < 4 || length > limits.input_bytes): return result_new_error[rgba_image*](IMAGE_LIMIT)
	if (length < 8): return result_new_error[rgba_image*](IMAGE_TRUNCATED)
	if ((data[0] & 255) != 137 || data[1] != 'P' || data[2] != 'N' || data[3] != 'G' || data[4] != 13 || data[5] != 10 || data[6] != 26 || data[7] != 10): return result_new_error[rgba_image*](IMAGE_BAD_FORMAT)
	int pos = 8
	int width = 0
	int height = 0
	int channels = 0
	int color = 0
	int depth = 0
	int interlace = 0
	int seen_header = 0
	int seen_data = 0
	int ended_data = 0
	int seen_end = 0
	int palette_count = 0
	int transparent_gray = -1
	int transparent_r = -1
	int transparent_g = -1
	int transparent_b = -1
	int seen_transparency = 0
	char[768] palette
	char[256] alpha
	for i in range(256): alpha[i] = 255
	string_builder* compressed = string_new()
	int error = 0
	while (pos < length && error == 0):
		if (length - pos < 12):
			error = IMAGE_TRUNCATED
			break
		# PNG lengths must fit signed 31-bit; check before additions.
		if ((data[pos] & 128) != 0):
			error = IMAGE_LIMIT
			break
		int size = load_be32(data + pos)
		if (size > length - pos - 12):
			error = IMAGE_TRUNCATED
			break
		char* type = data + pos + 4
		char* body = data + pos + 8
		for i in range(4):
			int ch = type[i] & 255
			if (!((ch >= 'A' && ch <= 'Z') || (ch >= 'a' && ch <= 'z'))): error = IMAGE_BAD_FORMAT
		if ((type[2] & 32) != 0): error = IMAGE_BAD_FORMAT
		if (error != 0): break
		int crc = load_be32(body + size)
		if (crc32_of(type, size + 4) != crc):
			error = IMAGE_CHECKSUM
			break
		if (seen_header == 0 && !png_chunk_is(type, c"IHDR")):
			error = IMAGE_BAD_FORMAT
			break
		if (png_chunk_is(type, c"IHDR")):
			if (seen_header || size != 13):
				error = IMAGE_BAD_FORMAT
				break
			seen_header = 1
			if ((body[0] & 128) != 0 || (body[4] & 128) != 0):
				error = IMAGE_LIMIT
				break
			width = load_be32(body)
			height = load_be32(body + 4)
			if (width < 1 || height < 1 || width > limits.width || height > limits.height || width > limits.rgba_bytes / 4 || height > limits.rgba_bytes / 4 / width):
				error = IMAGE_LIMIT
				break
			depth = body[8] & 255
			color = body[9] & 255
			interlace = body[12] & 255
			if (body[10] != 0 || body[11] != 0 || interlace > 1):
				error = IMAGE_UNSUPPORTED
				break
			if (color == 0 || color == 3): channels = 1
			else if (color == 2): channels = 3
			else if (color == 4): channels = 2
			else if (color == 6): channels = 4
			else:
				error = IMAGE_UNSUPPORTED
				break
			# Allowed depths (PNG spec table 11.1): packed depths only for
			# gray/indexed, 16 for every type except indexed.
			int packed = depth == 1 || depth == 2 || depth == 4
			if (!(depth == 8 || (depth == 16 && color != 3) || (packed && (color == 0 || color == 3)))):
				error = IMAGE_UNSUPPORTED
				break
		else if (png_chunk_is(type, c"PLTE")):
			if (seen_data || palette_count != 0 || size == 0 || size > 768 || size % 3 != 0 || color == 0 || color == 4):
				error = IMAGE_BAD_FORMAT
				break
			palette_count = size / 3
			for i in range(size): palette[i] = body[i]
		else if (png_chunk_is(type, c"tRNS")):
			if (seen_data || seen_transparency):
				error = IMAGE_BAD_FORMAT
				break
			seen_transparency = 1
			if (color == 3 && palette_count > 0 && size > 0 && size <= palette_count):
				for i in range(size): alpha[i] = body[i]
			else if (color == 0 && size == 2): transparent_gray = (body[0] & 255) * 256 + (body[1] & 255)
			else if (color == 2 && size == 6):
				transparent_r = (body[0] & 255) * 256 + (body[1] & 255)
				transparent_g = (body[2] & 255) * 256 + (body[3] & 255)
				transparent_b = (body[4] & 255) * 256 + (body[5] & 255)
			else:
				error = IMAGE_BAD_FORMAT
				break
		else if (png_chunk_is(type, c"IDAT")):
			if (ended_data || (color == 3 && palette_count == 0)):
				error = IMAGE_BAD_FORMAT
				break
			seen_data = 1
			string_append_bytes(compressed, body, size)
		else if (png_chunk_is(type, c"IEND")):
			if (size != 0 || seen_data == 0): error = IMAGE_BAD_FORMAT
			seen_end = 1
			pos = pos + size + 12
			break
		else:
			if (seen_data): ended_data = 1
			# An unknown critical chunk cannot be safely ignored.
			if ((type[0] & 32) == 0): error = IMAGE_UNSUPPORTED
		pos = pos + size + 12
	if (error == 0 && seen_end == 0): error = IMAGE_TRUNCATED
	if (error == 0 && pos != length): error = IMAGE_BAD_FORMAT
	if (error != 0):
		string_free(compressed)
		return result_new_error[rgba_image*](error)
	int bits_per_pixel = channels * depth
	# Filters compare bytes one whole pixel back (at least one byte).
	int pixel_bytes = (bits_per_pixel + 7) / 8
	int passes = 1
	if (interlace): passes = 7
	if (width > 2147483647 / bits_per_pixel - 7):
		string_free(compressed)
		return result_new_error[rgba_image*](IMAGE_LIMIT)
	# Extra filter bytes are included in the expanded allocation budget.
	int expected = 0
	for pass in range(passes):
		int pass_width = png_pass_size(width, pass, interlace, 0)
		int pass_height = png_pass_size(height, pass, interlace, 1)
		if (pass_width == 0 || pass_height == 0): continue
		int pass_row = (pass_width * bits_per_pixel + 7) / 8 + 1
		if (pass_height > (2147483647 - expected) / pass_row):
			string_free(compressed)
			return result_new_error[rgba_image*](IMAGE_LIMIT)
		expected = expected + pass_height * pass_row
	int stream_consumed = 0
	int compressed_length = compressed.length
	wresult[zlib_result*]* decoded = zlib_decompress_ex(compressed.data, compressed.length, expected, &stream_consumed)
	string_free(compressed)
	if (result_is_error[zlib_result*](decoded)):
		result_free[zlib_result*](decoded)
		return result_new_error[rgba_image*](IMAGE_COMPRESSED_DATA)
	zlib_result* raw = result_value[zlib_result*](decoded)
	result_free[zlib_result*](decoded)
	if (raw.length != expected || stream_consumed != compressed_length):
		zlib_result_free(raw)
		return result_new_error[rgba_image*](IMAGE_COMPRESSED_DATA)
	rgba_image* image = new rgba_image(width, height, width * height * 4, 0)
	image.pixels = cast(char*, malloc(image.length))
	int offset = 0
	for pass in range(passes):
		int pass_width = png_pass_size(width, pass, interlace, 0)
		int pass_height = png_pass_size(height, pass, interlace, 1)
		if (pass_width == 0 || pass_height == 0): continue
		int row_bytes = (pass_width * bits_per_pixel + 7) / 8
		int start_x = 0
		int start_y = 0
		int step_x = 1
		int step_y = 1
		if (interlace):
			start_x = png_adam7_start(pass, 0)
			start_y = png_adam7_start(pass, 1)
			step_x = png_adam7_step(pass, 0)
			step_y = png_adam7_step(pass, 1)
		for y in range(pass_height):
			char* line = raw.data + offset + y * (row_bytes + 1)
			int filter = line[0] & 255
			if (filter > 4):
				error = IMAGE_BAD_FORMAT
				break
			char* row = line + 1
			# The first row of each pass has an all-zero prior row.
			png_unfilter(row, row_bytes, pixel_bytes, filter, y > 0)
			int out_row = (start_y + y * step_y) * width
			for x in range(pass_width):
				int index = x * channels
				int sample = png_sample(row, index, depth)
				int r = png_sample_to_8(sample, depth)
				int g = r
				int b = r
				int a = 255
				if (color == 2 || color == 6):
					int sample_g = png_sample(row, index + 1, depth)
					int sample_b = png_sample(row, index + 2, depth)
					g = png_sample_to_8(sample_g, depth)
					b = png_sample_to_8(sample_b, depth)
					if (color == 6): a = png_sample_to_8(png_sample(row, index + 3, depth), depth)
					else if (sample == transparent_r && sample_g == transparent_g && sample_b == transparent_b): a = 0
				else if (color == 4): a = png_sample_to_8(png_sample(row, index + 1, depth), depth)
				else if (color == 0 && sample == transparent_gray): a = 0
				else if (color == 3):
					if (sample >= palette_count):
						error = IMAGE_BAD_FORMAT
						break
					a = alpha[sample] & 255
					r = palette[sample * 3] & 255
					g = palette[sample * 3 + 1] & 255
					b = palette[sample * 3 + 2] & 255
				char* out = image.pixels + (out_row + start_x + x * step_x) * 4
				out[0] = r
				out[1] = g
				out[2] = b
				out[3] = a
			if (error != 0): break
		if (error != 0): break
		offset = offset + pass_height * (row_bytes + 1)
	zlib_result_free(raw)
	if (error != 0):
		rgba_image_free(image)
		return result_new_error[rgba_image*](error)
	return result_new_ok[rgba_image*](image)


# Input and limits are borrowed only for the call. Successful result's
# image is caller-owned; release result wrapper separately from image.
wresult[rgba_image*]* png_decode_n(char* data, int length, image_limits* limits):
	image_limits* defaults = 0
	if (limits == 0):
		defaults = image_default_limits()
		limits = defaults
	wresult[rgba_image*]* result = png_decode_impl(data, length, limits)
	free(defaults)
	return result


void png_put_be32(string_builder* out, int n):
	string_append_char(out, shr(n, 24) & 255)
	string_append_char(out, shr(n, 16) & 255)
	string_append_char(out, shr(n, 8) & 255)
	string_append_char(out, n & 255)


void png_put_chunk(string_builder* out, char* kind, char* bytes, int length):
	png_put_be32(out, length)
	int start = out.length
	string_append_bytes(out, kind, 4)
	if (length > 0): string_append_bytes(out, bytes, length)
	png_put_be32(out, crc32_of(out.data + start, length + 4))


# Encode width x height straight-alpha RGBA rows (tightly packed, top to
# bottom) as an 8-bit RGBA PNG with no row filters. Caller frees the
# returned builder. For test goldens and tools, not for size.
string_builder* png_encode_rgba(int width, int height, char* rgba):
	string_builder* out = string_new()
	string_append_char(out, 137)
	string_append(out, c"PNG\r\n")
	string_append_char(out, 26)
	string_append_char(out, 10)
	string_builder* header = string_new()
	png_put_be32(header, width)
	png_put_be32(header, height)
	string_append_char(header, 8)
	string_append_char(header, 6)
	string_append_char(header, 0)
	string_append_char(header, 0)
	string_append_char(header, 0)
	png_put_chunk(out, c"IHDR", header.data, header.length)
	string_free(header)
	string_builder* raw = string_new()
	for y in range(height):
		string_append_char(raw, 0)
		string_append_bytes(raw, rgba + y * width * 4, width * 4)
	zlib_result* compressed = zlib_compress(raw.data, raw.length, DEFLATE_LEVEL_BEST())
	string_free(raw)
	png_put_chunk(out, c"IDAT", compressed.data, compressed.length)
	zlib_result_free(compressed)
	png_put_chunk(out, c"IEND", c"", 0)
	return out
