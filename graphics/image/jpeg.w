# Bounded baseline JPEG (SOF0, sequential Huffman, gray/YCbCr/RGB).
# T.81 Annexes B/F: https://www.w3.org/Graphics/JPEG/itu-t81.pdf
# One interleaved scan, integer sampling ratios, nearest-neighbor chroma.
import lib.lib
import lib.result
import lib.fmath
import graphics.image.image

struct jpeg_huffman:
	int* counts
	char* symbols
	int present

struct jpeg_component:
	int id
	int h
	int v
	int quant
	int dc_table
	int ac_table
	int predictor
	char* samples

struct jpeg_decoder:
	char* data
	int length
	int pos
	int error
	int width
	int height
	int components
	int max_h
	int max_v
	int restart_interval
	int rgb
	int bits
	int bit_count
	int* quant
	int* quant_present
	int* zigzag
	float32* basis
	jpeg_huffman** tables
	jpeg_component** component

int* jpeg_words(int count):
	int* words = cast(int*, malloc(count * __word_size__))
	for i in range(count): words[i] = 0
	return words

jpeg_decoder* jpeg_decoder_new(char* data, int length):
	jpeg_decoder* d = new jpeg_decoder()
	d.data = data
	d.length = length
	d.quant = jpeg_words(256)
	d.quant_present = jpeg_words(4)
	d.zigzag = cast(int*, malloc(64 * __word_size__))
	d.basis = cast(float32*, malloc(64 * 4))
	d.tables = cast(jpeg_huffman**, malloc(8 * __word_size__))
	d.component = cast(jpeg_component**, malloc(3 * __word_size__))
	for i in range(8):
		jpeg_huffman* table = new jpeg_huffman()
		table.counts = jpeg_words(17)
		table.symbols = cast(char*, malloc(256))
		d.tables[i] = table
	for i in range(3): d.component[i] = new jpeg_component()
	int index = 0
	for diagonal in range(15):
		for step in range(8):
			int x = step
			int y = diagonal - step
			if ((diagonal & 1) != 0):
				y = step
				x = diagonal - step
			if ((x >= 0) && (x < 8) && (y >= 0) && (y < 8)):
				d.zigzag[index] = y * 8 + x
				index = index + 1
	for x in range(8):
		for u in range(8):
			float32 factor = 0.5 * fcos(cast(float32, (2 * x + 1) * u) * 0.19634954084936207)
			if (u == 0): factor = 0.3535533905932738
			d.basis[x * 8 + u] = factor
	return d

void jpeg_decoder_free(jpeg_decoder* d):
	for i in range(8):
		jpeg_huffman* table = d.tables[i]
		free(table.counts)
		free(table.symbols)
		free(table)
	for i in range(3):
		jpeg_component* c = d.component[i]
		free(c.samples)
		free(c)
	free(cast(void*, d.tables))
	free(cast(void*, d.component))
	free(d.quant)
	free(d.quant_present)
	free(d.zigzag)
	free(d.basis)
	free(d)

int jpeg_u16(char* p):
	return ((p[0] & 255) << 8) | (p[1] & 255)

int jpeg_marker(jpeg_decoder* d):
	if (d.pos >= d.length):
		d.error = IMAGE_TRUNCATED
		return 0
	if ((d.data[d.pos] & 255) != 255):
		d.error = IMAGE_BAD_FORMAT
		return 0
	while ((d.pos < d.length) && ((d.data[d.pos] & 255) == 255)): d.pos = d.pos + 1
	if (d.pos >= d.length):
		d.error = IMAGE_TRUNCATED
		return 0
	int marker = d.data[d.pos] & 255
	d.pos = d.pos + 1
	if (marker == 0): d.error = IMAGE_BAD_FORMAT
	return marker

int jpeg_bit(jpeg_decoder* d):
	if (d.error != 0): return 0
	if (d.bit_count == 0):
		if (d.pos >= d.length):
			d.error = IMAGE_TRUNCATED
			return 0
		d.bits = d.data[d.pos] & 255
		d.pos = d.pos + 1
		if (d.bits == 255):
			if (d.pos >= d.length):
				d.error = IMAGE_TRUNCATED
				return 0
			if (d.data[d.pos] != 0):
				d.error = IMAGE_COMPRESSED_DATA
				return 0
			d.pos = d.pos + 1
		d.bit_count = 8
	d.bit_count = d.bit_count - 1
	return (d.bits >> d.bit_count) & 1

int jpeg_symbol(jpeg_decoder* d, jpeg_huffman* table):
	int code = 0
	int first = 0
	int index = 0
	for bits in range(1, 17):
		code = (code << 1) | jpeg_bit(d)
		if (d.error != 0): return 0
		int count = table.counts[bits]
		if ((code >= first) && (code - first < count)): return table.symbols[index + code - first] & 255
		index = index + count
		first = (first + count) << 1
	d.error = IMAGE_COMPRESSED_DATA
	return 0

int jpeg_receive(jpeg_decoder* d, int count):
	int value = 0
	for i in range(count): value = (value << 1) | jpeg_bit(d)
	if ((count > 0) && (value < (1 << (count - 1)))): value = value - (1 << count) + 1
	return value

int jpeg_clamp(int value):
	if (value < 0): return 0
	if (value > 255): return 255
	return value

void jpeg_block(jpeg_decoder* d, jpeg_component* component, int bx, int by):
	float32[64] coefficients
	float32[64] temporary
	for i in range(64): coefficients[i] = 0.0
	int category = jpeg_symbol(d, d.tables[component.dc_table])
	if (category > 11):
		d.error = IMAGE_COMPRESSED_DATA
		return
	component.predictor = component.predictor + jpeg_receive(d, category)
	if ((component.predictor < -2048) || (component.predictor > 2047)):
		d.error = IMAGE_COMPRESSED_DATA
		return
	coefficients[0] = cast(float32, component.predictor * d.quant[component.quant * 64])
	int index = 1
	while ((index < 64) && (d.error == 0)):
		int symbol = jpeg_symbol(d, d.tables[4 + component.ac_table])
		int count = symbol & 15
		int run = symbol >> 4
		if (count == 0):
			if (run == 0): break
			if (run != 15):
				d.error = IMAGE_COMPRESSED_DATA
				break
			index = index + 16
			if (index > 64): d.error = IMAGE_COMPRESSED_DATA
		else:
			index = index + run
			if ((count > 10) || (index >= 64)):
				d.error = IMAGE_COMPRESSED_DATA
				break
			int natural = d.zigzag[index]
			coefficients[natural] = cast(float32, jpeg_receive(d, count) * d.quant[component.quant * 64 + natural])
			index = index + 1
	if (d.error != 0): return
	# Separable inverse DCT with per-instance basis; no global mutable tables.
	for y in range(8):
		for x in range(8):
			float32 sum = 0.0
			for u in range(8): sum = sum + coefficients[y * 8 + u] * d.basis[x * 8 + u]
			temporary[y * 8 + x] = sum
	for y in range(8):
		for x in range(8):
			float32 sum = 0.0
			for v in range(8): sum = sum + temporary[v * 8 + x] * d.basis[y * 8 + v]
			component.samples[(by * 8 + y) * component.h * 8 + bx * 8 + x] = jpeg_clamp(cast(int, sum + 128.5))

void jpeg_align(jpeg_decoder* d):
	int mask = (1 << d.bit_count) - 1
	if ((d.bits & mask) != mask): d.error = IMAGE_COMPRESSED_DATA
	d.bit_count = 0

rgba_image* jpeg_scan(jpeg_decoder* d, char* header, int size):
	if ((d.components == 0) || (size != 4 + 2 * d.components) || ((header[0] & 255) != d.components)):
		d.error = IMAGE_UNSUPPORTED
		return 0
	if ((header[size - 3] != 0) || ((header[size - 2] & 255) != 63) || (header[size - 1] != 0)):
		d.error = IMAGE_UNSUPPORTED
		return 0
	int[3] order
	int seen = 0
	for i in range(d.components):
		int id = header[1 + 2 * i] & 255
		int found = -1
		for j in range(d.components):
			if (d.component[j].id == id): found = j
		if ((found < 0) || ((seen & (1 << found)) != 0)):
			d.error = IMAGE_BAD_FORMAT
			return 0
		seen = seen | (1 << found)
		order[i] = found
		jpeg_component* c = d.component[found]
		int selectors = header[2 + 2 * i] & 255
		c.dc_table = selectors >> 4
		c.ac_table = selectors & 15
		if ((c.dc_table > 3) || (c.ac_table > 3)):
			d.error = IMAGE_BAD_FORMAT
			return 0
		if (!d.tables[c.dc_table].present || !d.tables[4 + c.ac_table].present || !d.quant_present[c.quant]):
			d.error = IMAGE_BAD_FORMAT
			return 0
		c.samples = cast(char*, malloc(c.h * c.v * 64))
	rgba_image* image = new rgba_image()
	image.width = d.width
	image.height = d.height
	image.length = d.width * d.height * 4
	image.pixels = cast(char*, malloc(image.length))
	int mcu_width = d.max_h * 8
	int mcu_height = d.max_v * 8
	int columns = (d.width + mcu_width - 1) / mcu_width
	int rows = (d.height + mcu_height - 1) / mcu_height
	int mcu = 0
	int restart = 0
	for my in range(rows):
		for mx in range(columns):
			if ((d.restart_interval > 0) && (mcu > 0) && ((mcu % d.restart_interval) == 0)):
				jpeg_align(d)
				if (d.error != 0): break
				if (jpeg_marker(d) != 208 + restart): d.error = IMAGE_COMPRESSED_DATA
				if (d.error != 0): break
				restart = (restart + 1) & 7
				for i in range(d.components): d.component[i].predictor = 0
			for i in range(d.components):
				jpeg_component* c = d.component[order[i]]
				for by in range(c.v):
					for bx in range(c.h):
						jpeg_block(d, c, bx, by)
						if (d.error != 0): break
					if (d.error != 0): break
				if (d.error != 0): break
			if (d.error != 0): break
			for y in range(mcu_height):
				int py = my * mcu_height + y
				if (py >= d.height): break
				for x in range(mcu_width):
					int px = mx * mcu_width + x
					if (px >= d.width): break
					int[3] samples
					for i in range(d.components):
						jpeg_component* c = d.component[i]
						samples[i] = c.samples[(y * c.v / d.max_v) * c.h * 8 + x * c.h / d.max_h] & 255
					int r = samples[0]
					int g = r
					int b = r
					if (d.components == 3):
						if (d.rgb):
							g = samples[1]
							b = samples[2]
						else:
							int cb = samples[1] - 128
							int cr = samples[2] - 128
							r = jpeg_clamp(cast(int, cast(float32, samples[0]) + 1.402 * cast(float32, cr) + 0.5))
							g = jpeg_clamp(cast(int, cast(float32, samples[0]) - 0.344136 * cast(float32, cb) - 0.714136 * cast(float32, cr) + 0.5))
							b = jpeg_clamp(cast(int, cast(float32, samples[0]) + 1.772 * cast(float32, cb) + 0.5))
					int offset = (py * d.width + px) * 4
					image.pixels[offset] = r
					image.pixels[offset + 1] = g
					image.pixels[offset + 2] = b
					image.pixels[offset + 3] = 255
			mcu = mcu + 1
		if (d.error != 0): break
	if (d.error == 0):
		jpeg_align(d)
		if (d.error == 0):
			if (jpeg_marker(d) != 217):
				if (d.error == 0): d.error = IMAGE_UNSUPPORTED
	if (d.error != 0):
		rgba_image_free(image)
		return 0
	return image

void jpeg_quantization(jpeg_decoder* d, char* data, int size):
	int pos = 0
	while ((pos < size) && (d.error == 0)):
		int info = data[pos] & 255
		pos = pos + 1
		if ((info >> 4) != 0):
			d.error = IMAGE_UNSUPPORTED
			return
		int id = info & 15
		if ((id > 3) || (size - pos < 64)):
			d.error = IMAGE_BAD_FORMAT
			return
		for i in range(64):
			int value = data[pos + i] & 255
			if (value == 0): d.error = IMAGE_BAD_FORMAT
			d.quant[id * 64 + d.zigzag[i]] = value
		d.quant_present[id] = 1
		pos = pos + 64

void jpeg_huffman_tables(jpeg_decoder* d, char* data, int size):
	int pos = 0
	while ((pos < size) && (d.error == 0)):
		if (size - pos < 17):
			d.error = IMAGE_BAD_FORMAT
			return
		int info = data[pos] & 255
		int id = info & 15
		int kind = info >> 4
		if ((id > 3) || (kind > 1)):
			d.error = IMAGE_BAD_FORMAT
			return
		jpeg_huffman* table = d.tables[kind * 4 + id]
		int count = 0
		int code = 0
		for bits in range(1, 17):
			int n = data[pos + bits] & 255
			table.counts[bits] = n
			count = count + n
			if ((n > 0) && (code + n >= (1 << bits))): d.error = IMAGE_BAD_FORMAT
			code = (code + n) << 1
		pos = pos + 17
		if ((count < 1) || (count > 256) || (count > size - pos)):
			d.error = IMAGE_BAD_FORMAT
			return
		for i in range(count): table.symbols[i] = data[pos + i]
		table.present = 1
		pos = pos + count

void jpeg_frame(jpeg_decoder* d, char* data, int size, image_limits* limits):
	if ((d.components != 0) || (size < 6)):
		d.error = IMAGE_BAD_FORMAT
		return
	if ((data[0] & 255) != 8):
		d.error = IMAGE_UNSUPPORTED
		return
	d.height = jpeg_u16(data + 1)
	d.width = jpeg_u16(data + 3)
	d.components = data[5] & 255
	if ((d.components != 1) && (d.components != 3)):
		d.error = IMAGE_UNSUPPORTED
		return
	if (size != 6 + d.components * 3):
		d.error = IMAGE_BAD_FORMAT
		return
	if ((d.width < 1) || (d.height < 1) || (d.width > limits.width) || (d.height > limits.height) || (d.width > limits.rgba_bytes / 4) || (d.height > limits.rgba_bytes / 4 / d.width)):
		d.error = IMAGE_LIMIT
		return
	int blocks = 0
	for i in range(d.components):
		jpeg_component* c = d.component[i]
		c.id = data[6 + i * 3] & 255
		c.h = (data[7 + i * 3] & 255) >> 4
		c.v = data[7 + i * 3] & 15
		c.quant = data[8 + i * 3] & 255
		for j in range(i):
			if (d.component[j].id == c.id): d.error = IMAGE_BAD_FORMAT
		if ((c.h < 1) || (c.h > 4) || (c.v < 1) || (c.v > 4) || (c.quant > 3)): d.error = IMAGE_BAD_FORMAT
		if (c.h > d.max_h): d.max_h = c.h
		if (c.v > d.max_v): d.max_v = c.v
		blocks = blocks + c.h * c.v
	if (d.error != 0): return
	if (blocks > 10): d.error = IMAGE_UNSUPPORTED
	for i in range(d.components):
		jpeg_component* c = d.component[i]
		if (((d.max_h % c.h) != 0) || ((d.max_v % c.v) != 0)): d.error = IMAGE_UNSUPPORTED
	if ((d.components == 1) && ((d.max_h != 1) || (d.max_v != 1))): d.error = IMAGE_UNSUPPORTED
	if ((d.components == 3) && (d.component[0].id == 'R') && (d.component[1].id == 'G') && (d.component[2].id == 'B')): d.rgb = 1

wresult[rgba_image*]* jpeg_decode_n(char* data, int length, image_limits* limits):
	if ((length < 0) || ((data == 0) && (length > 0))): return result_new_error[rgba_image*](IMAGE_BAD_FORMAT)
	image_limits* owned = 0
	if (limits == 0):
		owned = image_default_limits()
		limits = owned
	int error = 0
	if ((limits.input_bytes < 1) || (limits.width < 1) || (limits.height < 1) || (limits.rgba_bytes < 4) || (length > limits.input_bytes)): error = IMAGE_LIMIT
	else if (length < 2): error = IMAGE_TRUNCATED
	else if (((data[0] & 255) != 255) || ((data[1] & 255) != 216)): error = IMAGE_BAD_FORMAT
	if (error != 0):
		free(owned)
		return result_new_error[rgba_image*](error)
	jpeg_decoder* d = jpeg_decoder_new(data, length)
	d.pos = 2
	rgba_image* image = 0
	while ((d.error == 0) && (image == 0)):
		int marker = jpeg_marker(d)
		if (d.error != 0): break
		if ((marker == 216) || (marker == 217) || ((marker >= 208) && (marker <= 215)) || (marker == 1)):
			d.error = IMAGE_BAD_FORMAT
			break
		if (d.length - d.pos < 2):
			d.error = IMAGE_TRUNCATED
			break
		int size = jpeg_u16(d.data + d.pos)
		if (size < 2):
			d.error = IMAGE_BAD_FORMAT
			break
		if (size > d.length - d.pos):
			d.error = IMAGE_TRUNCATED
			break
		char* payload = d.data + d.pos + 2
		d.pos = d.pos + size
		size = size - 2
		if (marker == 219): jpeg_quantization(d, payload, size)
		else if (marker == 196): jpeg_huffman_tables(d, payload, size)
		else if (marker == 192): jpeg_frame(d, payload, size, limits)
		else if (marker == 221):
			if (size != 2): d.error = IMAGE_BAD_FORMAT
			else: d.restart_interval = jpeg_u16(payload)
		else if (marker == 218): image = jpeg_scan(d, payload, size)
		else if (marker == 238):
			if ((size >= 12) && (payload[0] == 'A') && (payload[1] == 'd') && (payload[2] == 'o') && (payload[3] == 'b') && (payload[4] == 'e')):
				if (payload[11] == 0): d.rgb = 1
				else if (payload[11] == 1): d.rgb = 0
				else: d.error = IMAGE_UNSUPPORTED
		else if (((marker >= 224) && (marker <= 239)) || (marker == 254)):
			# Application metadata and comments do not affect allocation or decode.
			continue
		else: d.error = IMAGE_UNSUPPORTED
	error = d.error
	jpeg_decoder_free(d)
	free(owned)
	if (error != 0): return result_new_error[rgba_image*](error)
	return result_new_ok[rgba_image*](image)
