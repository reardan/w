# wbuild: x64
import lib.assert
import libs.wgrind.execute_images


void image_u16(char* data, int at, int value):
	data[at] = value
	data[at + 1] = value >> 8


void image_u64(char* data, int at, int value):
	for i in range(8): data[at + i] = value >> (i * 8)


void image_segment(char* data, int at, int flags, int file, int virtual, int filesz, int memsz):
	image_u64(data, at, 1 | (flags << 32))
	image_u64(data, at + 8, file)
	image_u64(data, at + 16, virtual)
	image_u64(data, at + 32, filesz)
	image_u64(data, at + 40, memsz)
	image_u64(data, at + 48, 4096)


void image_bias_and_paths():
	wg_context* c = wg_create(8, 8, 2)
	assert1(c != 0)
	wg_symbols symbols
	wg_symbols_init(&symbols, c, 64)
	wg_images images
	wg_images_init(&images, c, &symbols, 64)
	char[12288] data
	for i in range(12288): data[i] = 0
	data[0] = 127
	data[1] = 'E'
	data[2] = 'L'
	data[3] = 'F'
	data[4] = 2
	data[5] = 1
	data[6] = 1
	image_u16(&data[0], 16, 3)
	image_u16(&data[0], 18, 62)
	image_u64(&data[0], 32, 64)
	image_u16(&data[0], 54, 56)
	image_u16(&data[0], 56, 3)
	image_segment(&data[0], 64, 4, 0, 4096, 4096, 4096)
	image_segment(&data[0], 120, 5, 4096, 12288, 8192, 8192)
	image_segment(&data[0], 176, 6, 8192, 24576, 4096, 8192)
	assert1(wg_images_headers(&data[0], 12288))
	assert1(wg_images_parse(&images, c"70001000-70002000 r--p 00000000 08:01 12 /path with spaces/image\n70003000-70004000 r-xp 00001000 08:01 12 /path with spaces/image\n70004000-70005000 r-xp 00002000 08:01 12 /path with spaces/image\n70006000-70007000 rw-p 00002000 08:01 12 /path with spaces/image\n70007000-70008000 rw-p 00000000 00:00 0\nffffffffff600000-ffffffffff601000 --xp 00000000 00:00 0 [vsyscall]\n"))
	assert_equal(6, images.maps.length)
	assert_strings_equal(c"/path with spaces/image", images.maps[0].path)
	assert1(wg_images_layout(&images, c"/path with spaces/image", &data[0], 12288))
	assert_equal(1, images.images.length)
	assert_equal(0x70000000, images.images[0].bias)
	assert_equal(1, images.roots.length)
	assert_equal(0x70006000, images.roots[0].address)
	assert_equal(8192, images.roots[0].size)
	# A duplicate refresh image does not duplicate globals or symbols.
	assert1(wg_images_layout(&images, c"/path with spaces/image", &data[0], 12288))
	assert_equal(1, images.roots.length)
	# Offset-only bias guesses would accept this relocated executable
	# mapping incorrectly; PT_LOAD virtual-address validation rejects it.
	wg_image_map bad = images.maps[1]
	bad.low = bad.low + 4096
	bad.high = bad.high + 4096
	images.maps[1] = bad
	assert_equal(0, wg_images_layout(&images, c"/path with spaces/image", &data[0], 12288))
	assert_equal(WG_INCOMPLETE, c.error)
	wg_images_destroy(&images)
	wg_symbols_destroy(&symbols)
	wg_destroy(c)


void image_live_maps():
	wg_context* c = wg_create(8, 8, 2)
	assert1(c != 0)
	wg_symbols symbols
	wg_symbols_init(&symbols, c, 256)
	wg_images images
	wg_images_init(&images, c, &symbols, 1024)
	assert1(wg_images_refresh(&images, getpid()))
	assert1(images.images.length > 0)
	assert1(images.roots.length > 0)
	int roots = images.roots.length
	assert1(wg_images_refresh(&images, getpid()))
	assert_equal(roots, images.roots.length)
	wg_images_destroy(&images)
	wg_symbols_destroy(&symbols)
	wg_destroy(c)


void image_failure_paths():
	wg_context* c = wg_create(8, 8, 2)
	assert1(c != 0)
	wg_symbols symbols
	wg_symbols_init(&symbols, c, 16)
	wg_images images
	wg_images_init(&images, c, &symbols, 16)
	assert1(wg_images_parse(&images, c"1000-2000 r-xp 00000000 08:01 12 /missing image (deleted)\n"))
	assert_equal(0, wg_images_file(&images, getpid(), images.maps[0].path))
	assert_equal(WG_INCOMPLETE, c.error)
	wg_images_destroy(&images)
	wg_symbols_destroy(&symbols)
	wg_destroy(c)
	c = wg_create(8, 8, 2)
	wg_symbols_init(&symbols, c, 16)
	wg_images_init(&images, c, &symbols, 16)
	assert_equal(0, wg_images_parse(&images, c"1000-2000 r-xp 00000000 08:01 12 /ambiguous\\012name\n"))
	assert_equal(WG_INCOMPLETE, c.error)
	wg_images_destroy(&images)
	wg_symbols_destroy(&symbols)
	wg_destroy(c)


int main():
	if (__word_size__ == 8):
		image_bias_and_paths()
		image_live_maps()
		image_failure_paths()
	println(c"wgrind_images_test: OK")
	return 0
