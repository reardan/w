# wbuild: x64
import lib.testing
import lib.format
import lib.stream
import lib.ndarray
import lib.mnist


void assert_feq(float want, float got):
	if (want != got):
		print2(c"Assertion failed: wanted float ")
		print2(ftoa(want))
		print2(c" got ")
		println2(ftoa(got))
		print_stack_trace()
		exit(1)


void write_u32_be(wstream* out, int v):
	stream_write_byte(out, (v >> 24) & 0xff)
	stream_write_byte(out, (v >> 16) & 0xff)
	stream_write_byte(out, (v >> 8) & 0xff)
	stream_write_byte(out, v & 0xff)


# Writes a tiny 3x4x5 IDX images fixture: mostly-zero pixels with a
# handful of known values planted at fixed flat offsets, so the test can
# assert exact byte->[0,1] conversions without recomputing the loader's
# own formula. Flat offset k maps to (image, row, col) row-major:
# k = image*20 + row*5 + col.
void write_mnist_images_fixture(char* path):
	wstream* out = stream_open_write(path)
	write_u32_be(out, MNIST_MAGIC_IMAGES())
	write_u32_be(out, 3)
	write_u32_be(out, 4)
	write_u32_be(out, 5)
	int i = 0
	while (i < 60):
		int v = 0
		if (i == 0):
			v = 255       # (image 0, row 0, col 0)
		if (i == 7):
			v = 128       # (image 0, row 1, col 2)
		if (i == 59):
			v = 200       # (image 2, row 3, col 4) -- last byte in the file
		stream_write_byte(out, v)
		i = i + 1
	stream_close(out)


void write_mnist_labels_fixture(char* path):
	wstream* out = stream_open_write(path)
	write_u32_be(out, MNIST_MAGIC_LABELS())
	write_u32_be(out, 3)
	stream_write_byte(out, 7)
	stream_write_byte(out, 3)
	stream_write_byte(out, 9)
	stream_close(out)


############################## happy path ##############################


void test_mnist_load_images():
	write_mnist_images_fixture(c"bin/mnist_test_images.idx")
	ndf images
	int rc = mnist_load_images(c"bin/mnist_test_images.idx", &images)
	assert_equal(MNIST_OK(), rc)
	assert_equal(3, images.rank)
	assert_equal(3, images.n0)
	assert_equal(4, images.n1)
	assert_equal(5, images.n2)
	assert_feq(1.0, ndf_at3(&images, 0, 0, 0))         # 255 -> 1.0
	assert_feq(0.0, ndf_at3(&images, 0, 0, 1))         # 0 -> 0.0
	assert_feq(128.0 / 255.0, ndf_at3(&images, 0, 1, 2))
	assert_feq(200.0 / 255.0, ndf_at3(&images, 2, 3, 4))
	assert_feq(0.0, ndf_at3(&images, 1, 0, 0))         # untouched middle image


void test_mnist_load_labels():
	write_mnist_labels_fixture(c"bin/mnist_test_labels.idx")
	ndi labels
	int rc = mnist_load_labels(c"bin/mnist_test_labels.idx", &labels)
	assert_equal(MNIST_OK(), rc)
	assert_equal(1, labels.rank)
	assert_equal(3, labels.n0)
	assert_equal(7, ndi_at1(&labels, 0))
	assert_equal(3, ndi_at1(&labels, 1))
	assert_equal(9, ndi_at1(&labels, 2))


void test_mnist_flatten_images():
	write_mnist_images_fixture(c"bin/mnist_test_flatten.idx")
	ndf images
	assert_equal(MNIST_OK(), mnist_load_images(c"bin/mnist_test_flatten.idx", &images))
	ndf flat = mnist_flatten_images(&images)
	assert_equal(2, flat.rank)
	assert_equal(3, flat.n0)
	assert_equal(20, flat.n1)
	assert_feq(1.0, ndf_at2(&flat, 0, 0))
	assert_feq(128.0 / 255.0, ndf_at2(&flat, 0, 7))
	# flatten shares the backing buffer (zero-copy view): a write through
	# the flat view must be visible back through the original rank-3 array.
	ndf_set2(&flat, 1, 0, 0.5)
	assert_feq(0.5, ndf_at3(&images, 1, 0, 0))


############################## error paths ##############################


void test_mnist_load_images_missing_file():
	ndf images
	int rc = mnist_load_images(c"bin/mnist_test_missing_11aa.idx", &images)
	assert_equal(MNIST_ERR_OPEN(), rc)


void test_mnist_load_images_bad_magic():
	wstream* out = stream_open_write(c"bin/mnist_test_bad_magic.idx")
	write_u32_be(out, MNIST_MAGIC_LABELS())
	stream_close(out)
	ndf images
	int rc = mnist_load_images(c"bin/mnist_test_bad_magic.idx", &images)
	assert_equal(MNIST_ERR_BAD_MAGIC(), rc)


void test_mnist_load_images_truncated_header():
	wstream* out = stream_open_write(c"bin/mnist_test_truncated_header.idx")
	write_u32_be(out, MNIST_MAGIC_IMAGES())
	write_u32_be(out, 3)
	# rows/cols dimensions missing entirely
	stream_close(out)
	ndf images
	int rc = mnist_load_images(c"bin/mnist_test_truncated_header.idx", &images)
	assert_equal(MNIST_ERR_TRUNCATED(), rc)


void test_mnist_load_images_truncated_pixels():
	wstream* out = stream_open_write(c"bin/mnist_test_truncated_pixels.idx")
	write_u32_be(out, MNIST_MAGIC_IMAGES())
	write_u32_be(out, 1)
	write_u32_be(out, 2)
	write_u32_be(out, 2)
	stream_write_byte(out, 10)
	stream_write_byte(out, 20)
	# header declares 1*2*2 = 4 pixel bytes; only 2 were written
	stream_close(out)
	ndf images
	int rc = mnist_load_images(c"bin/mnist_test_truncated_pixels.idx", &images)
	assert_equal(MNIST_ERR_TRUNCATED(), rc)


void test_mnist_load_labels_bad_magic():
	wstream* out = stream_open_write(c"bin/mnist_test_labels_bad_magic.idx")
	write_u32_be(out, MNIST_MAGIC_IMAGES())
	stream_close(out)
	ndi labels
	int rc = mnist_load_labels(c"bin/mnist_test_labels_bad_magic.idx", &labels)
	assert_equal(MNIST_ERR_BAD_MAGIC(), rc)


void test_mnist_load_labels_missing_file():
	ndi labels
	int rc = mnist_load_labels(c"bin/mnist_test_labels_missing_11aa.idx", &labels)
	assert_equal(MNIST_ERR_OPEN(), rc)
