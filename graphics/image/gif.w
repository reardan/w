# Bounded GIF87a/GIF89a first-image decoder. Animation is not played.
# Format: https://www.w3.org/Graphics/GIF/spec-gif89a.txt
import graphics.image.image

const int GIF_WORK_LIMIT = 134217728

struct gif_decoder:
	char* data
	int length
	int pos
	int error
	int work
	int bits
	int bit_count
	int block_left

int gif_charge(gif_decoder* d):
	if (d.work == 0):
		d.error = IMAGE_LIMIT
		return 0
	d.work = d.work - 1
	return 1

int gif_read(gif_decoder* d):
	if (d.error != 0): return 0
	if (gif_charge(d) == 0): return 0
	if (d.pos >= d.length):
		d.error = IMAGE_TRUNCATED
		return 0
	int value = d.data[d.pos] & 255
	d.pos = d.pos + 1
	return value

int gif_u16(gif_decoder* d):
	int low = gif_read(d)
	return low | (gif_read(d) << 8)


void gif_skip_blocks(gif_decoder* d):
	while (d.error == 0):
		int size = gif_read(d)
		if (size == 0): return
		if (size > d.length - d.pos):
			d.error = IMAGE_TRUNCATED
			return
		if (size > d.work):
			d.error = IMAGE_LIMIT
			return
		d.work = d.work - size
		d.pos = d.pos + size

char* gif_palette(gif_decoder* d, int count):
	if (count * 3 > d.length - d.pos):
		d.error = IMAGE_TRUNCATED
		return 0
	if (count * 3 > d.work):
		d.error = IMAGE_LIMIT
		return 0
	d.work = d.work - count * 3
	char* palette = d.data + d.pos
	d.pos = d.pos + count * 3
	return palette

int gif_code(gif_decoder* d, int width):
	while ((d.bit_count < width) && (d.error == 0)):
		if (d.block_left == 0):
			d.block_left = gif_read(d)
			if (d.error != 0): return 0
			if (d.block_left == 0):
				d.error = IMAGE_COMPRESSED_DATA
				return 0
			if (d.block_left > d.length - d.pos):
				d.error = IMAGE_TRUNCATED
				return 0
		d.bits = d.bits | (gif_read(d) << d.bit_count)
		d.bit_count = d.bit_count + 8
		d.block_left = d.block_left - 1
	int code = d.bits & ((1 << width) - 1)
	d.bits = d.bits >> width
	d.bit_count = d.bit_count - width
	return code

void gif_pixels(gif_decoder* d, rgba_image* image, char* palette, int colors, int transparent, int left, int top, int width, int height, int interlace):
	int minimum = gif_read(d)
	if (d.error != 0): return
	if ((minimum < 2) || (minimum > 8)):
		d.error = IMAGE_BAD_FORMAT
		return
	int[4096] prefix
	char[4096] suffix
	char[4096] stack
	int clear = 1 << minimum
	int end = clear + 1
	int next = clear + 2
	int code_width = minimum + 1
	int previous = -1
	int first = 0
	int written = 0
	int x = 0
	int y = 0
	int interlace_pass = 0
	int step = 8
	int seen_clear = 0
	while ((d.error == 0) && gif_charge(d)):
		int code = gif_code(d, code_width)
		if (d.error != 0): break
		if (code == clear):
			code_width = minimum + 1
			next = clear + 2
			previous = -1
			seen_clear = 1
			continue
		if (seen_clear == 0):
			d.error = IMAGE_COMPRESSED_DATA
			break
		if (code == end):
			if (written != width * height): d.error = IMAGE_COMPRESSED_DATA
			break
		int original = code
		int count = 0
		if (code == next && previous >= 0):
			stack[count] = first
			count = count + 1
			code = previous
		else if (code >= next):
			d.error = IMAGE_COMPRESSED_DATA
			break
		while ((code >= clear) && (d.error == 0)):
			if ((code < clear + 2) || (count >= 4095)):
				d.error = IMAGE_COMPRESSED_DATA
				break
			if (gif_charge(d) == 0): break
			stack[count] = suffix[code]
			count = count + 1
			code = prefix[code]
		if (d.error != 0): break
		first = code
		stack[count] = first
		count = count + 1
		if (count > width * height - written):
			d.error = IMAGE_COMPRESSED_DATA
			break
		while ((count > 0) && (d.error == 0)):
			if (gif_charge(d) == 0): break
			count = count - 1
			int index = stack[count] & 255
			if (index >= colors):
				d.error = IMAGE_BAD_FORMAT
				break
			int dest = ((top + y) * image.width + left + x) * 4
			if (index != transparent):
				image.pixels[dest] = palette[index * 3]
				image.pixels[dest + 1] = palette[index * 3 + 1]
				image.pixels[dest + 2] = palette[index * 3 + 2]
				image.pixels[dest + 3] = 255
			written = written + 1
			x = x + 1
			if (x == width):
				x = 0
				if (interlace == 0): y = y + 1
				else:
					y = y + step
					while ((y >= height) && (interlace_pass < 3)):
						interlace_pass = interlace_pass + 1
						if (interlace_pass == 1): y = 4
						else if (interlace_pass == 2):
							y = 2
							step = 4
						else:
							y = 1
							step = 2
		if ((previous >= 0) && (next < 4096)):
			prefix[next] = previous
			suffix[next] = first
			next = next + 1
			if ((next == (1 << code_width)) && (code_width < 12)): code_width = code_width + 1
		previous = original
	if (d.error != 0): return
	# Require the complete image-data terminator even when EOI arrived early.
	d.pos = d.pos + d.block_left
	d.block_left = 0
	gif_skip_blocks(d)

rgba_image* gif_first_image(gif_decoder* d, image_limits* limits):
	int screen_width = gif_u16(d)
	int screen_height = gif_u16(d)
	int packed = gif_read(d)
	int background = gif_read(d)
	gif_read(d)
	if (d.error != 0): return 0
	if ((screen_width == 0) || (screen_height == 0)):
		d.error = IMAGE_BAD_FORMAT
		return 0
	if ((screen_width > limits.width) || (screen_height > limits.height) || (screen_height > limits.rgba_bytes / 4 / screen_width)):
		d.error = IMAGE_LIMIT
		return 0
	int global_colors = 0
	char* global_palette = 0
	if ((packed & 128) != 0):
		global_colors = 1 << ((packed & 7) + 1)
		global_palette = gif_palette(d, global_colors)
		if (background >= global_colors): d.error = IMAGE_BAD_FORMAT
	int transparent = -1
	while (d.error == 0):
		int marker = gif_read(d)
		if (d.error != 0): break
		if (marker == 33):
			int label = gif_read(d)
			if (label == 249):
				int size = gif_read(d)
				int flags = gif_read(d)
				gif_u16(d)
				int index = gif_read(d)
				int terminator = gif_read(d)
				if (d.error != 0): break
				if ((size != 4) || (terminator != 0) || ((flags & 224) != 0) || (((flags >> 2) & 7) > 3)):
					d.error = IMAGE_BAD_FORMAT
					break
				transparent = -1
				if ((flags & 1) != 0): transparent = index
			else if (label == 1):
				# Plain-text rendering would change the first presentation.
				d.error = IMAGE_UNSUPPORTED
			else: gif_skip_blocks(d)
			continue
		if (marker != 44):
			d.error = IMAGE_BAD_FORMAT
			break
		int left = gif_u16(d)
		int top = gif_u16(d)
		int width = gif_u16(d)
		int height = gif_u16(d)
		int flags = gif_read(d)
		if (d.error != 0): break
		if ((width == 0) || (height == 0) || (left > screen_width) || (top > screen_height) || (width > screen_width - left) || (height > screen_height - top) || ((flags & 24) != 0)):
			d.error = IMAGE_BAD_FORMAT
			break
		int colors = global_colors
		char* palette = global_palette
		if ((flags & 128) != 0):
			colors = 1 << ((flags & 7) + 1)
			palette = gif_palette(d, colors)
		if (d.error != 0): break
		if ((colors == 0) || (transparent >= colors)):
			d.error = IMAGE_BAD_FORMAT
			break
		if (screen_width * screen_height > d.work):
			d.error = IMAGE_LIMIT
			break
		d.work = d.work - screen_width * screen_height
		rgba_image* image = new rgba_image()
		image.width = screen_width
		image.height = screen_height
		image.length = screen_width * screen_height * 4
		image.pixels = cast(char*, malloc(image.length))
		for i in range(screen_width * screen_height):
			int dest = i * 4
			for channel in range(4): image.pixels[dest + channel] = 0
			if ((transparent < 0) && (global_palette != 0)):
				for channel in range(3): image.pixels[dest + channel] = global_palette[background * 3 + channel]
				image.pixels[dest + 3] = 255
		gif_pixels(d, image, palette, colors, transparent, left, top, width, height, flags & 64)
		if (d.error != 0):
			rgba_image_free(image)
			return 0
		return image
	return 0

# Returns the logical screen after its first image. Later frames/trailer are
# intentionally not decoded; delay, disposal and looping are not implemented.
wresult[rgba_image*]* gif_decode_n(char* data, int length, image_limits* limits):
	if ((length < 0) || ((data == 0) && (length > 0))): return result_new_error[rgba_image*](IMAGE_BAD_FORMAT)
	image_limits* owned = 0
	if (limits == 0):
		owned = image_default_limits()
		limits = owned
	int error = 0
	if ((limits.input_bytes < 1) || (limits.width < 1) || (limits.height < 1) || (limits.rgba_bytes < 4) || (length > limits.input_bytes)): error = IMAGE_LIMIT
	else if (length < 6): error = IMAGE_TRUNCATED
	else if ((data[0] != 'G') || (data[1] != 'I') || (data[2] != 'F') || (data[3] != '8') || ((data[4] != '7') && (data[4] != '9')) || (data[5] != 'a')): error = IMAGE_BAD_FORMAT
	if (error != 0):
		free(owned)
		return result_new_error[rgba_image*](error)
	gif_decoder d
	d.error = 0
	d.bits = 0
	d.bit_count = 0
	d.block_left = 0
	d.data = data
	d.length = length
	d.pos = 6
	d.work = GIF_WORK_LIMIT
	rgba_image* image = gif_first_image(&d, limits)
	free(owned)
	if (d.error != 0): return result_new_error[rgba_image*](d.error)
	return result_new_ok[rgba_image*](image)
