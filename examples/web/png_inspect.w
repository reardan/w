# bin/wv2 examples/web/png_inspect.w -o bin/png_inspect
# bin/png_inspect image.png
import lib.args
import lib.io
import graphics.image.png


int main(int argc, int argv):
	args_init(argc, argv)
	if (args_positional_count() != 1):
		println2(c"usage: png_inspect image.png")
		return 2
	int fd = open(args_positional(0), 0, 0)
	if (fd < 0): return 2
	int length = file_size(fd)
	image_limits* limits = image_default_limits()
	if (length < 0 || length > limits.input_bytes):
		close(fd)
		free(limits)
		return 2
	char* bytes = cast(char*, malloc(length + 1))
	io_result read_result
	int status = io_read_exact(fd, bytes, length, &read_result)
	close(fd)
	if (status != IO_OK):
		free(bytes)
		free(limits)
		return 2
	wresult[rgba_image*]* result = png_decode_n(bytes, length, limits)
	free(bytes)
	free(limits)
	int failed = result_is_error[rgba_image*](result)
	if (failed): println2(image_error_string(result.code))
	else:
		rgba_image* image = result.value
		char* width = itoa(image.width)
		char* height = itoa(image.height)
		print(width)
		print(c" x ")
		println(height)
		free(width)
		free(height)
		rgba_image_free(image)
	result_free[rgba_image*](result)
	return failed
