/*
lib.mnist: an IDX-format loader for the MNIST digit dataset -- pure CPU,
so this file must never import lib.cuda or lib.tensor (either would drag
a libcuda.so.1 load-time dependency into every program that just wants
to read training data, docs/projects/torch.md Workstream C). Images
load into lib.ndarray's ndf (float32) and labels into ndi (int), the
same CPU substrate lib.tensor copies to/from for the GPU path.

IDX format (http://yann.lecun.com/exdb/mnist/): big-endian throughout.
A 4-byte magic number [0, 0, dtype, ndims] -- dtype 0x08 is unsigned
byte, the only variant MNIST ships and the only one this file reads --
followed by `ndims` big-endian u32 extents, then raw unsigned-byte data
in row-major order. Images files are 3-D (count, rows, cols), magic
0x00000803; label files are 1-D (count), magic 0x00000801.

Error handling follows lib/file.w's recoverable-result convention (a
bad path or malformed input returns a code; the process is never
exited), not lib/assert.w's fatal-assert convention -- a corrupt
dataset file is caller input, not a violated invariant.
*/
import lib.lib
import lib.assert
import lib.stream
import lib.ndarray


########################## error codes ##########################


int MNIST_OK():
	return 0


int MNIST_ERR_OPEN():
	return 1


int MNIST_ERR_BAD_MAGIC():
	return 2


int MNIST_ERR_BAD_DIMS():
	return 3


int MNIST_ERR_TRUNCATED():
	return 4


char* mnist_error_string(int code):
	if (code == MNIST_OK()):
		return c"mnist: ok"
	if (code == MNIST_ERR_OPEN()):
		return c"mnist: could not open file"
	if (code == MNIST_ERR_BAD_MAGIC()):
		return c"mnist: bad IDX magic number"
	if (code == MNIST_ERR_BAD_DIMS()):
		return c"mnist: bad or non-positive dimensions"
	if (code == MNIST_ERR_TRUNCATED()):
		return c"mnist: truncated file"
	return c"mnist: unknown error"


########################## IDX primitives ##########################


int MNIST_MAGIC_IMAGES():
	return 0x00000803


int MNIST_MAGIC_LABELS():
	return 0x00000801


# Reads one big-endian u32, assembled byte by byte, into *value_out.
# Returns 1 on success, 0 at end of input (short file); *value_out is
# untouched on failure.
int mnist_read_u32(wstream* in, int* value_out):
	int b0 = stream_read_byte(in)
	int b1 = stream_read_byte(in)
	int b2 = stream_read_byte(in)
	int b3 = stream_read_byte(in)
	if (b0 < 0 || b1 < 0 || b2 < 0 || b3 < 0):
		return 0
	*value_out = (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
	return 1


########################## images ##########################


# Parses an IDX images file (magic 0x00000803, 3 dims: count, rows,
# cols) into *out as a rank-3 ndf, pixels normalized to [0, 1]
# (raw_byte / 255.0). Returns MNIST_OK() on success; on any error *out
# is left untouched and a nonzero MNIST_ERR_* is returned -- bad magic,
# non-positive dims, an unopenable path, or a short file are all
# ordinary error returns, never a process exit.
int mnist_load_images(char* path, ndf* out):
	wstream* in = stream_open_read(path)
	if (in == 0):
		return MNIST_ERR_OPEN()

	int magic
	if (mnist_read_u32(in, &magic) == 0):
		stream_close(in)
		return MNIST_ERR_TRUNCATED()
	if (magic != MNIST_MAGIC_IMAGES()):
		stream_close(in)
		return MNIST_ERR_BAD_MAGIC()

	int count
	int rows
	int cols
	if (mnist_read_u32(in, &count) == 0 || mnist_read_u32(in, &rows) == 0 || mnist_read_u32(in, &cols) == 0):
		stream_close(in)
		return MNIST_ERR_TRUNCATED()
	if (count <= 0 || rows <= 0 || cols <= 0):
		stream_close(in)
		return MNIST_ERR_BAD_DIMS()

	ndf a = ndf_new3(count, rows, cols)
	int n = a.data.length
	char* raw = malloc(n)
	int got = stream_read(in, raw, n)
	stream_close(in)
	if (got != n):
		free(raw)
		return MNIST_ERR_TRUNCATED()

	# Data bytes are unsigned 0..255; raw is char* (signed), so widening
	# to int without masking would sign-extend 0x80..0xff negative.
	int i = 0
	while (i < n):
		int pixel = raw[i] & 0xff
		a.data[i] = cast(float, pixel) / 255.0
		i = i + 1
	free(raw)

	*out = a
	return MNIST_OK()


########################## labels ##########################


# Parses an IDX labels file (magic 0x00000801, 1 dim: count) into *out
# as a rank-1 ndi. Label values are the raw unsigned bytes (0..255)
# with no range validation -- MNIST's 0..9 digit range is a caller
# concern, not this loader's. Returns MNIST_OK() on success; on any
# error *out is left untouched and a nonzero MNIST_ERR_* is returned.
int mnist_load_labels(char* path, ndi* out):
	wstream* in = stream_open_read(path)
	if (in == 0):
		return MNIST_ERR_OPEN()

	int magic
	if (mnist_read_u32(in, &magic) == 0):
		stream_close(in)
		return MNIST_ERR_TRUNCATED()
	if (magic != MNIST_MAGIC_LABELS()):
		stream_close(in)
		return MNIST_ERR_BAD_MAGIC()

	int count
	if (mnist_read_u32(in, &count) == 0):
		stream_close(in)
		return MNIST_ERR_TRUNCATED()
	if (count <= 0):
		stream_close(in)
		return MNIST_ERR_BAD_DIMS()

	char* raw = malloc(count)
	int got = stream_read(in, raw, count)
	stream_close(in)
	if (got != count):
		free(raw)
		return MNIST_ERR_TRUNCATED()

	ndi a = ndi_new1(count)
	int i = 0
	while (i < count):
		a.data[i] = raw[i] & 0xff
		i = i + 1
	free(raw)

	*out = a
	return MNIST_OK()


########################## flatten for MLP input ##########################


# Rank-2 view of a rank-3 images ndf: (count, rows*cols). Zero-copy --
# mnist_load_images always builds a contiguous row-major buffer via
# ndf_new3, so the same float[] wraps directly into the flattened shape
# (ndf_wrap2's length assert always holds here: count*rows*cols ==
# count*(rows*cols)). Writes through either view are visible in the
# other, matching lib.ndarray's existing wrap/view aliasing rules.
ndf mnist_flatten_images(ndf* images):
	asserts(c"mnist_flatten_images: rank must be 3", images.rank == 3)
	return ndf_wrap2(images.data, images.n0, images.n1 * images.n2)
