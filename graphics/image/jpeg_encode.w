# Baseline JPEG encoder (T.81 SOF0, sequential Huffman, 8-bit YCbCr).
# JFIF APP0, Annex K quantization tables scaled by quality (IJG rule),
# Annex K.3 Huffman tables, 4:2:0 or 4:4:4 sampling, integer DCT and
# color conversion (no libm). Edge blocks replicate the last row/column.
import lib.lib
import structures.string
import graphics.image.image


const int JPEG_SUBSAMPLE_420 = 0
const int JPEG_SUBSAMPLE_444 = 1


# Annex K.1 luminance/chrominance tables in natural (row-major) order.
char* jpeg_encode_luma_quant():
	return c"\x10\x0b\x0a\x10\x18\x28\x33\x3d\x0c\x0c\x0e\x13\x1a\x3a\x3c\x37\x0e\x0d\x10\x18\x28\x39\x45\x38\x0e\x11\x16\x1d\x33\x57\x50\x3e\x12\x16\x25\x38\x44\x6d\x67\x4d\x18\x23\x37\x40\x51\x68\x71\x5c\x31\x40\x4e\x57\x67\x79\x78\x65\x48\x5c\x5f\x62\x70\x64\x67\x63"


char* jpeg_encode_chroma_quant():
	return c"\x11\x12\x18\x2f\x63\x63\x63\x63\x12\x15\x1a\x42\x63\x63\x63\x63\x18\x1a\x38\x63\x63\x63\x63\x63\x2f\x42\x63\x63\x63\x63\x63\x63\x63\x63\x63\x63\x63\x63\x63\x63\x63\x63\x63\x63\x63\x63\x63\x63\x63\x63\x63\x63\x63\x63\x63\x63\x63\x63\x63\x63\x63\x63\x63\x63"


# Annex K.3 tables: 16 code-length counts followed by the symbols.
char* jpeg_encode_dc_luma():
	return c"\x00\x01\x05\x01\x01\x01\x01\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0a\x0b"


char* jpeg_encode_dc_chroma():
	return c"\x00\x03\x01\x01\x01\x01\x01\x01\x01\x01\x01\x00\x00\x00\x00\x00\x00\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0a\x0b"


char* jpeg_encode_ac_luma():
	return c"\x00\x02\x01\x03\x03\x02\x04\x03\x05\x05\x04\x04\x00\x00\x01\x7d\x01\x02\x03\x00\x04\x11\x05\x12\x21\x31\x41\x06\x13\x51\x61\x07\x22\x71\x14\x32\x81\x91\xa1\x08\x23\x42\xb1\xc1\x15\x52\xd1\xf0\x24\x33\x62\x72\x82\x09\x0a\x16\x17\x18\x19\x1a\x25\x26\x27\x28\x29\x2a\x34\x35\x36\x37\x38\x39\x3a\x43\x44\x45\x46\x47\x48\x49\x4a\x53\x54\x55\x56\x57\x58\x59\x5a\x63\x64\x65\x66\x67\x68\x69\x6a\x73\x74\x75\x76\x77\x78\x79\x7a\x83\x84\x85\x86\x87\x88\x89\x8a\x92\x93\x94\x95\x96\x97\x98\x99\x9a\xa2\xa3\xa4\xa5\xa6\xa7\xa8\xa9\xaa\xb2\xb3\xb4\xb5\xb6\xb7\xb8\xb9\xba\xc2\xc3\xc4\xc5\xc6\xc7\xc8\xc9\xca\xd2\xd3\xd4\xd5\xd6\xd7\xd8\xd9\xda\xe1\xe2\xe3\xe4\xe5\xe6\xe7\xe8\xe9\xea\xf1\xf2\xf3\xf4\xf5\xf6\xf7\xf8\xf9\xfa"


char* jpeg_encode_ac_chroma():
	return c"\x00\x02\x01\x02\x04\x04\x03\x04\x07\x05\x04\x04\x00\x01\x02\x77\x00\x01\x02\x03\x11\x04\x05\x21\x31\x06\x12\x41\x51\x07\x61\x71\x13\x22\x32\x81\x08\x14\x42\x91\xa1\xb1\xc1\x09\x23\x33\x52\xf0\x15\x62\x72\xd1\x0a\x16\x24\x34\xe1\x25\xf1\x17\x18\x19\x1a\x26\x27\x28\x29\x2a\x35\x36\x37\x38\x39\x3a\x43\x44\x45\x46\x47\x48\x49\x4a\x53\x54\x55\x56\x57\x58\x59\x5a\x63\x64\x65\x66\x67\x68\x69\x6a\x73\x74\x75\x76\x77\x78\x79\x7a\x82\x83\x84\x85\x86\x87\x88\x89\x8a\x92\x93\x94\x95\x96\x97\x98\x99\x9a\xa2\xa3\xa4\xa5\xa6\xa7\xa8\xa9\xaa\xb2\xb3\xb4\xb5\xb6\xb7\xb8\xb9\xba\xc2\xc3\xc4\xc5\xc6\xc7\xc8\xc9\xca\xd2\xd3\xd4\xd5\xd6\xd7\xd8\xd9\xda\xe2\xe3\xe4\xe5\xe6\xe7\xe8\xe9\xea\xf2\xf3\xf4\xf5\xf6\xf7\xf8\xf9\xfa"


# Table t: 0 DC luma, 1 AC luma, 2 DC chroma, 3 AC chroma.
char* jpeg_encode_huffman_table(int t):
	if (t == 0): return jpeg_encode_dc_luma()
	if (t == 1): return jpeg_encode_ac_luma()
	if (t == 2): return jpeg_encode_dc_chroma()
	return jpeg_encode_ac_chroma()


# Number of symbols in a counts+symbols table.
int jpeg_encode_table_symbols(char* table):
	int count = 0
	for i in range(16): count = count + (table[i] & 255)
	return count


struct jpeg_encoder:
	string_builder* out
	int bits
	int bit_count
	int* zigzag
	int* basis
	int* quant
	int* codes
	int* sizes


int* jpeg_encode_words(int count):
	int* words = cast(int*, malloc(count * __word_size__))
	for i in range(count): words[i] = 0
	return words


# cos(m * pi / 16) scaled by 8192, for any integer m >= 0.
int jpeg_encode_cos(int m):
	m = m % 32
	if (m > 16): m = 32 - m
	int sign = 1
	if (m > 8):
		m = 16 - m
		sign = -1
	int value = 0
	if (m == 0): value = 8192
	else if (m == 1): value = 8035
	else if (m == 2): value = 7568
	else if (m == 3): value = 6811
	else if (m == 4): value = 5793
	else if (m == 5): value = 4551
	else if (m == 6): value = 3135
	else if (m == 7): value = 1598
	return sign * value


# Canonical Huffman codes (Annex C) for table `which` (0..3) into the
# encoder's code/size arrays at symbol offset which * 256.
void jpeg_encode_build_codes(jpeg_encoder* e, char* table, int which):
	int code = 0
	int index = 16
	for bits in range(1, 17):
		int n = table[bits - 1] & 255
		for i in range(n):
			int symbol = table[index] & 255
			e.codes[which * 256 + symbol] = code
			e.sizes[which * 256 + symbol] = bits
			code = code + 1
			index = index + 1
		code = code << 1


# Quality clamps to 1..100; IJG scale: 5000/q below 50, 200 - 2q above.
void jpeg_encode_scale_quant(jpeg_encoder* e, int quality):
	if (quality < 1): quality = 1
	if (quality > 100): quality = 100
	int scale = 200 - quality * 2
	if (quality < 50): scale = 5000 / quality
	for t in range(2):
		char* base = jpeg_encode_luma_quant()
		if (t == 1): base = jpeg_encode_chroma_quant()
		for i in range(64):
			int value = ((base[i] & 255) * scale + 50) / 100
			if (value < 1): value = 1
			if (value > 255): value = 255
			e.quant[t * 64 + i] = value


jpeg_encoder* jpeg_encoder_new(int quality):
	jpeg_encoder* e = new jpeg_encoder()
	e.out = string_new()
	e.zigzag = jpeg_encode_words(64)
	e.basis = jpeg_encode_words(64)
	e.quant = jpeg_encode_words(128)
	e.codes = jpeg_encode_words(1024)
	e.sizes = jpeg_encode_words(1024)
	int index = 0
	for diagonal in range(15):
		for step in range(8):
			int x = step
			int y = diagonal - step
			if ((diagonal & 1) != 0):
				y = step
				x = diagonal - step
			if ((x >= 0) && (x < 8) && (y >= 0) && (y < 8)):
				e.zigzag[index] = y * 8 + x
				index = index + 1
	# basis[u * 8 + x] = C(u) * cos((2x + 1) u pi / 16) * 8192, C(0) = 1/sqrt(2).
	for u in range(8):
		for x in range(8):
			if (u == 0): e.basis[x] = 5793
			else: e.basis[u * 8 + x] = jpeg_encode_cos((2 * x + 1) * u)
	jpeg_encode_scale_quant(e, quality)
	for t in range(4): jpeg_encode_build_codes(e, jpeg_encode_huffman_table(t), t)
	return e


void jpeg_encoder_free(jpeg_encoder* e):
	free(e.zigzag)
	free(e.basis)
	free(e.quant)
	free(e.codes)
	free(e.sizes)
	free(e)


void jpeg_encode_u16(string_builder* out, int value):
	string_append_char(out, (value >> 8) & 255)
	string_append_char(out, value & 255)


void jpeg_encode_marker(string_builder* out, int marker, int length):
	string_append_char(out, 255)
	string_append_char(out, marker)
	jpeg_encode_u16(out, length)


# Appends `count` (<= 16) low bits of `value`, stuffing 0x00 after 0xff.
void jpeg_encode_bits(jpeg_encoder* e, int value, int count):
	if (count == 0): return
	e.bits = (e.bits << count) | (value & ((1 << count) - 1))
	e.bit_count = e.bit_count + count
	while (e.bit_count >= 8):
		int byte_value = (e.bits >> (e.bit_count - 8)) & 255
		string_append_char(e.out, byte_value)
		if (byte_value == 255): string_append_char(e.out, 0)
		e.bit_count = e.bit_count - 8
		e.bits = e.bits & ((1 << e.bit_count) - 1)


# Pads the final partial byte with 1 bits (T.81 F.1.2.3).
void jpeg_encode_flush(jpeg_encoder* e):
	if (e.bit_count > 0): jpeg_encode_bits(e, 127, 8 - e.bit_count)


int jpeg_encode_category(int value):
	if (value < 0): value = -value
	int category = 0
	while (value > 0):
		category = category + 1
		value = value >> 1
	return category


void jpeg_encode_symbol(jpeg_encoder* e, int which, int symbol):
	jpeg_encode_bits(e, e.codes[which * 256 + symbol], e.sizes[which * 256 + symbol])


# Rounded a / b for b > 0, symmetric around zero.
int jpeg_encode_div(int a, int b):
	if (a >= 0): return (a + b / 2) / b
	return -((b / 2 - a) / b)


# Forward DCT, quantization and Huffman coding of one 8x8 block of level
# shifted samples. Returns the block's quantized DC for the predictor.
int jpeg_encode_block(jpeg_encoder* e, int* samples, int table, int predictor):
	int[64] rows
	int[64] quantized
	# Row pass: rows[y * 8 + u] = sum_x s(x, y) basis(u, x) / 2048.
	for y in range(8):
		for u in range(8):
			int sum = 0
			for x in range(8): sum = sum + samples[y * 8 + x] * e.basis[u * 8 + x]
			rows[y * 8 + u] = jpeg_encode_div(sum, 2048)
	# Column pass; the 1/4 normalization and 2048 * 8192 / 2048 scale give
	# F(u, v) = sum / 131072.
	for v in range(8):
		for u in range(8):
			int sum = 0
			for y in range(8): sum = sum + rows[y * 8 + u] * e.basis[v * 8 + y]
			int q = jpeg_encode_div(sum, 131072 * e.quant[table * 64 + v * 8 + u])
			if (q > 1023): q = 1023
			if (q < -1023): q = -1023
			quantized[v * 8 + u] = q
	int dc = quantized[0]
	int diff = dc - predictor
	int category = jpeg_encode_category(diff)
	jpeg_encode_symbol(e, table * 2, category)
	if (diff < 0): diff = diff - 1
	jpeg_encode_bits(e, diff, category)
	int run = 0
	for k in range(1, 64):
		int value = quantized[e.zigzag[k]]
		if (value == 0):
			run = run + 1
			continue
		while (run > 15):
			jpeg_encode_symbol(e, table * 2 + 1, 240)
			run = run - 16
		category = jpeg_encode_category(value)
		jpeg_encode_symbol(e, table * 2 + 1, (run << 4) | category)
		if (value < 0): value = value - 1
		jpeg_encode_bits(e, value, category)
		run = 0
	if (run > 0): jpeg_encode_symbol(e, table * 2 + 1, 0)
	return dc


void jpeg_encode_headers(jpeg_encoder* e, int width, int height, int luma_sampling):
	string_builder* out = e.out
	string_append_char(out, 255)
	string_append_char(out, 216)
	# JFIF 1.01 APP0, no units, 1:1 aspect, no thumbnail.
	jpeg_encode_marker(out, 224, 16)
	string_append_bytes(out, c"JFIF", 5)
	string_append_char(out, 1)
	string_append_char(out, 1)
	string_append_char(out, 0)
	jpeg_encode_u16(out, 1)
	jpeg_encode_u16(out, 1)
	string_append_char(out, 0)
	string_append_char(out, 0)
	jpeg_encode_marker(out, 219, 132)
	for t in range(2):
		string_append_char(out, t)
		for i in range(64): string_append_char(out, e.quant[t * 64 + e.zigzag[i]])
	jpeg_encode_marker(out, 192, 17)
	string_append_char(out, 8)
	jpeg_encode_u16(out, height)
	jpeg_encode_u16(out, width)
	string_append_char(out, 3)
	for c in range(3):
		string_append_char(out, c + 1)
		if (c == 0): string_append_char(out, luma_sampling)
		else: string_append_char(out, 17)
		if (c == 0): string_append_char(out, 0)
		else: string_append_char(out, 1)
	int length = 2
	for t in range(4): length = length + 17 + jpeg_encode_table_symbols(jpeg_encode_huffman_table(t))
	jpeg_encode_marker(out, 196, length)
	for t in range(4):
		# Class (0 DC, 1 AC) in the high nibble, table id 0 luma / 1 chroma.
		char* table = jpeg_encode_huffman_table(t)
		string_append_char(out, ((t & 1) << 4) | (t >> 1))
		string_append_bytes(out, table, 16 + jpeg_encode_table_symbols(table))
	jpeg_encode_marker(out, 218, 12)
	string_append_char(out, 3)
	string_append_char(out, 1)
	string_append_char(out, 0)
	string_append_char(out, 2)
	string_append_char(out, 17)
	string_append_char(out, 3)
	string_append_char(out, 17)
	string_append_char(out, 0)
	string_append_char(out, 63)
	string_append_char(out, 0)


# Copies the 8x8 block at (x0, y0) of a plane `stride` wide, level shifted.
void jpeg_encode_load(int* block, char* plane, int stride, int x0, int y0):
	for y in range(8):
		for x in range(8): block[y * 8 + x] = (plane[(y0 + y) * stride + x0 + x] & 255) - 128


int jpeg_encode_clamp(int value):
	if (value < 0): return 0
	if (value > 255): return 255
	return value


# Encodes width x height straight RGBA rows (tightly packed, top to bottom)
# as a baseline JFIF JPEG; alpha is ignored. quality clamps to 1..100;
# subsampling is JPEG_SUBSAMPLE_420 or JPEG_SUBSAMPLE_444. Returns a
# caller-owned builder, or 0 for invalid arguments (dimensions outside
# 1..65535, a null buffer, an unknown subsampling mode, or an image whose
# padded planes would not fit in memory sizes).
string_builder* jpeg_encode_rgba_ex(int width, int height, char* rgba, int quality, int subsampling):
	if ((width < 1) || (height < 1) || (width > 65535) || (height > 65535) || (rgba == 0)): return 0
	if ((subsampling != JPEG_SUBSAMPLE_420) && (subsampling != JPEG_SUBSAMPLE_444)): return 0
	int mcu = 8
	if (subsampling == JPEG_SUBSAMPLE_420): mcu = 16
	int padded_width = (width + mcu - 1) / mcu * mcu
	int padded_height = (height + mcu - 1) / mcu * mcu
	if (padded_height > 2147483647 / 4 / padded_width): return 0
	int plane_size = padded_width * padded_height
	char* luma = cast(char*, malloc(plane_size))
	char* blue = cast(char*, malloc(plane_size))
	char* red = cast(char*, malloc(plane_size))
	# Integer JFIF RGB -> YCbCr (16-bit fixed point), edges replicated.
	for y in range(padded_height):
		int sy = y
		if (sy >= height): sy = height - 1
		for x in range(padded_width):
			int sx = x
			if (sx >= width): sx = width - 1
			char* p = rgba + (sy * width + sx) * 4
			int r = p[0] & 255
			int g = p[1] & 255
			int b = p[2] & 255
			int i = y * padded_width + x
			luma[i] = jpeg_encode_clamp((19595 * r + 38470 * g + 7471 * b + 32768) >> 16)
			blue[i] = jpeg_encode_clamp((8421376 + 32768 - 11059 * r - 21709 * g + 32768 * b) >> 16)
			red[i] = jpeg_encode_clamp((8421376 + 32768 + 32768 * r - 27439 * g - 5329 * b) >> 16)
	int chroma_width = padded_width
	if (subsampling == JPEG_SUBSAMPLE_420):
		# Box-filter 2x2 chroma in place; the half planes use the low rows.
		chroma_width = padded_width / 2
		for y in range(padded_height / 2):
			for x in range(chroma_width):
				int i = 2 * y * padded_width + 2 * x
				int cb = (blue[i] & 255) + (blue[i + 1] & 255) + (blue[i + padded_width] & 255) + (blue[i + padded_width + 1] & 255)
				int cr = (red[i] & 255) + (red[i + 1] & 255) + (red[i + padded_width] & 255) + (red[i + padded_width + 1] & 255)
				blue[y * chroma_width + x] = (cb + 2) / 4
				red[y * chroma_width + x] = (cr + 2) / 4
	jpeg_encoder* e = jpeg_encoder_new(quality)
	int luma_sampling = 17
	if (subsampling == JPEG_SUBSAMPLE_420): luma_sampling = 34
	jpeg_encode_headers(e, width, height, luma_sampling)
	int[64] block
	int predict_y = 0
	int predict_cb = 0
	int predict_cr = 0
	int luma_blocks = mcu / 8
	for my in range(padded_height / mcu):
		for mx in range(padded_width / mcu):
			for by in range(luma_blocks):
				for bx in range(luma_blocks):
					jpeg_encode_load(&block[0], luma, padded_width, mx * mcu + bx * 8, my * mcu + by * 8)
					predict_y = jpeg_encode_block(e, &block[0], 0, predict_y)
			jpeg_encode_load(&block[0], blue, chroma_width, mx * 8, my * 8)
			predict_cb = jpeg_encode_block(e, &block[0], 1, predict_cb)
			jpeg_encode_load(&block[0], red, chroma_width, mx * 8, my * 8)
			predict_cr = jpeg_encode_block(e, &block[0], 1, predict_cr)
	jpeg_encode_flush(e)
	string_append_char(e.out, 255)
	string_append_char(e.out, 217)
	free(luma)
	free(blue)
	free(red)
	string_builder* out = e.out
	jpeg_encoder_free(e)
	return out


# 4:2:0 baseline JPEG; see jpeg_encode_rgba_ex.
string_builder* jpeg_encode_rgba(int width, int height, char* rgba, int quality):
	return jpeg_encode_rgba_ex(width, height, rgba, quality, JPEG_SUBSAMPLE_420)
