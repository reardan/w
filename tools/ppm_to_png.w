# wbuild: binary=ppm_to_png
# Convert 8-bit binary PPM (P6) screenshots to PNG using W's zlib encoder.
import tools.host_tools
import libs.extras.compress.zlib
import libs.extras.compress.crc32

int ppm_space(int ch):
	return ch == 32 || ch == 9 || ch == 10 || ch == 13 || ch == 11 || ch == 12

void ppm_chunk(string_builder* out, char* tag, char* payload, int length):
	char[4] number
	store_be32(&number[0], length)
	string_append_bytes(out, &number[0], 4)
	int start = out.length
	string_append_bytes(out, tag, 4)
	string_append_bytes(out, payload, length)
	store_be32(&number[0], crc32_of(out.data + start, length + 4))
	string_append_bytes(out, &number[0], 4)

int ppm_decimal(char* text):
	ht_require(text[0] != 0, c"empty PPM dimension")
	int value = 0
	for i in range(strlen(text)):
		int digit = text[i] - '0'
		ht_require(digit >= 0 && digit <= 9 && value <= (json_int_max() - digit) / 10, c"invalid PPM dimension")
		value = value * 10 + digit
	return value

int main(int argc, int argv):
	args_init(argc, argv)
	ht_require(argc == 3, c"usage: ppm_to_png in.ppm out.png")
	string_builder* data = ht_read(args_get(1))
	list[char*] header = new list[char*]
	int pos = 0
	while (header.length < 4):
		while (pos < data.length && ppm_space(data.data[pos])): pos = pos + 1
		ht_require(pos < data.length, c"truncated PPM header")
		if (data.data[pos] == '#'):
			while (pos < data.length && data.data[pos] != 10): pos = pos + 1
			continue
		int start = pos
		while (pos < data.length && !ppm_space(data.data[pos])): pos = pos + 1
		header.push(path_clone_range(data.data + start, pos - start))
	ht_require(pos < data.length && strcmp(header[0], c"P6") == 0 && ppm_decimal(header[3]) == 255, c"expected an 8-bit P6 PPM")
	pos = pos + 1
	int width = ppm_decimal(header[1])
	int height = ppm_decimal(header[2])
	ht_require(width > 0 && height > 0 && width <= (json_int_max() - 1) / 3 && height <= json_int_max() / (width * 3 + 1), c"PPM dimensions exceed host limit")
	ht_require(width * height * 3 <= data.length - pos, c"truncated PPM pixels")
	string_builder* scanlines = string_new()
	for y in range(height):
		string_append_char(scanlines, 0)
		string_append_bytes(scanlines, data.data + pos + y * width * 3, width * 3)
	zlib_result* compressed = zlib_compress(scanlines.data, scanlines.length, 9)
	ht_require(compressed != 0, c"PNG compression failed")
	string_builder* out = string_new()
	string_append_bytes(out, c"\x89PNG\r\n\x1a\n", 8)
	char[13] ihdr
	store_be32(&ihdr[0], width)
	store_be32(&ihdr[4], height)
	ihdr[8] = 8
	ihdr[9] = 2
	ihdr[10] = 0
	ihdr[11] = 0
	ihdr[12] = 0
	ppm_chunk(out, c"IHDR", &ihdr[0], 13)
	ppm_chunk(out, c"IDAT", compressed.data, compressed.length)
	ppm_chunk(out, c"IEND", c"", 0)
	ht_write(args_get(2), out.data, out.length)
	return 0
