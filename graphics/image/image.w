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
