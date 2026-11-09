# Shared owned RGBA decode boundary and limits.
import lib.lib
import lib.result


const int IMAGE_BAD_FORMAT = 701
const int IMAGE_TRUNCATED = 702
const int IMAGE_LIMIT = 703
const int IMAGE_UNSUPPORTED = 704
const int IMAGE_CHECKSUM = 705
const int IMAGE_COMPRESSED_DATA = 706


struct image_limits:
	int input_bytes
	int width
	int height
	int rgba_bytes


struct rgba_image:
	int width
	int height
	int length
	char* pixels


image_limits* image_default_limits():
	return new image_limits(16777216, 8192, 8192, 67108864)


void rgba_image_free(rgba_image* image):
	if (image == 0): return
	free(image.pixels)
	free(image)


char* image_error_string(int code):
	if (code == IMAGE_BAD_FORMAT): return c"invalid image structure"
	if (code == IMAGE_TRUNCATED): return c"truncated image"
	if (code == IMAGE_LIMIT): return c"image resource limit"
	if (code == IMAGE_UNSUPPORTED): return c"unsupported image encoding"
	if (code == IMAGE_CHECKSUM): return c"image checksum mismatch"
	if (code == IMAGE_COMPRESSED_DATA): return c"invalid compressed image data"
	return c"unknown image error"


# EXIF/TIFF orientation (tag 0x0112): 1 is upright; 2 mirrors left-right,
# 3 rotates 180, 4 mirrors top-bottom, 5 transposes, 6 rotates 90 degrees
# clockwise, 7 transverses and 8 rotates 90 degrees counter-clockwise.
# Rewrites `image` in place into its display orientation, swapping width
# and height for 5..8. Returns 1, or 0 (image unchanged) for a null image
# or an orientation outside 1..8.
int rgba_image_apply_orientation(rgba_image* image, int orientation):
	if (image == 0 || orientation < 1 || orientation > 8): return 0
	if (orientation == 1): return 1
	int width = image.width
	int height = image.height
	int out_width = width
	int out_height = height
	if (orientation >= 5):
		out_width = height
		out_height = width
	char* source = image.pixels
	char* target = cast(char*, malloc(image.length))
	for y in range(out_height):
		for x in range(out_width):
			int sx = x
			int sy = y
			if (orientation == 2): sx = width - 1 - x
			else if (orientation == 3):
				sx = width - 1 - x
				sy = height - 1 - y
			else if (orientation == 4): sy = height - 1 - y
			else if (orientation == 5):
				sx = y
				sy = x
			else if (orientation == 6):
				sx = y
				sy = height - 1 - x
			else if (orientation == 7):
				sx = width - 1 - y
				sy = height - 1 - x
			else if (orientation == 8):
				sx = width - 1 - y
				sy = x
			char* from = source + (sy * width + sx) * 4
			char* to = target + (y * out_width + x) * 4
			to[0] = from[0]
			to[1] = from[1]
			to[2] = from[2]
			to[3] = from[3]
	free(source)
	image.pixels = target
	image.width = out_width
	image.height = out_height
	return 1
