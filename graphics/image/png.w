# Bounded PNG decoder: non-interlaced 8-bit gray/RGB/indexed/GA/RGBA.
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
			color = body[9] & 255
			if (body[8] != 8 || body[10] != 0 || body[11] != 0 || body[12] != 0):
				error = IMAGE_UNSUPPORTED
				break
			if (color == 0 || color == 3): channels = 1
			else if (color == 2): channels = 3
			else if (color == 4): channels = 2
			else if (color == 6): channels = 4
			else:
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
	int row_bytes = width * channels
	# Extra filter bytes are included in the expanded allocation budget.
	if (height > 2147483647 / (row_bytes + 1)):
		string_free(compressed)
		return result_new_error[rgba_image*](IMAGE_LIMIT)
	int expected = (row_bytes + 1) * height
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
	for y in range(height):
		int filter = raw.data[y * (row_bytes + 1)] & 255
		if (filter > 4):
			error = IMAGE_BAD_FORMAT
			break
		char* row = raw.data + y * (row_bytes + 1) + 1
		for x in range(row_bytes):
			int left = 0
			int up = 0
			int upper_left = 0
			if (x >= channels): left = row[x - channels] & 255
			if (y > 0):
				up = row[x - row_bytes - 1] & 255
				if (x >= channels): upper_left = row[x - row_bytes - 1 - channels] & 255
			int value = row[x] & 255
			if (filter == 1): value = value + left
			if (filter == 2): value = value + up
			if (filter == 3): value = value + (left + up) / 2
			if (filter == 4): value = value + png_paeth(left, up, upper_left)
			row[x] = value & 255
		for x in range(width):
			int offset = (y * width + x) * 4
			int r = row[x * channels] & 255
			int g = r
			int b = r
			int a = 255
			if (color == 2 || color == 6):
				g = row[x * channels + 1] & 255
				b = row[x * channels + 2] & 255
				if (color == 6): a = row[x * channels + 3] & 255
				else if (r == transparent_r && g == transparent_g && b == transparent_b): a = 0
			else if (color == 4): a = row[x * channels + 1] & 255
			else if (color == 0 && r == transparent_gray): a = 0
			else if (color == 3):
				if (r >= palette_count):
					error = IMAGE_BAD_FORMAT
					break
				a = alpha[r] & 255
				g = palette[r * 3 + 1] & 255
				b = palette[r * 3 + 2] & 255
				r = palette[r * 3] & 255
			image.pixels[offset] = r
			image.pixels[offset + 1] = g
			image.pixels[offset + 2] = b
			image.pixels[offset + 3] = a
		if (error != 0): break
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
