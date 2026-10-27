# Real-GPU acceptance: partial tiles, uniform control, staged dot and masks.
import lib.testing
import lib.tensor

void tile_add_gpu(float32* a, float32* b, float32* out, int n, int choice):
	gpu[1024] for tile in range(n):
		value := a[tile] + b[tile]
		if choice:
			for int step in range(2):
				value += 1
		else:
			value *= 2
		out[tile] = value

void tile_vector_case(int n, int choice):
	int size = n
	if size < 0: size = 0
	float32* a = cast(float32*, gpu_alloc((size + 2) * 4))
	float32* b = cast(float32*, gpu_alloc((size + 2) * 4))
	float32* out = cast(float32*, gpu_alloc((size + 2) * 4))
	for i in range(size + 2):
		a[i] = i % 13
		b[i] = 2 * (i % 7)
		out[i] = -99
	tile_add_gpu(a, b, out, n, choice)
	gpu_sync()
	for i in range(size):
		float32 want = a[i] + b[i]
		if choice: want += 2
		else: want *= 2
		assert_near(want, out[i])
	assert_near(-99, out[size])
	assert_near(-99, out[size + 1])
	# Exact in-place output follows the same source-ordered loads.
	tile_add_gpu(a, b, a, n, 1)
	gpu_sync()
	for i in range(size): assert_near((i % 13) + b[i] + 2, a[i])
	gpu_free(cast(char*, a))
	gpu_free(cast(char*, b))
	gpu_free(cast(char*, out))

void test_tile_add_edges():
	tile_vector_case(-1, 1)
	tile_vector_case(0, 1)
	tile_vector_case(1, 1)
	tile_vector_case(255, 0)
	tile_vector_case(256, 1)
	tile_vector_case(257, 0)
	tile_vector_case(1023, 1)
	tile_vector_case(1024, 0)
	tile_vector_case(1025, 1)
	tile_vector_case(2051, 0)

void tile_matmul_gpu(float32* a, float32* b, float32* out, int m, int n, int k, int programs):
	gpu[1] for tile in range(programs):
		int columns = (n + 15) / 16
		int row = tile_program_id() / columns * 16
		int col = tile_program_id() % columns * 16
		acc := tile_zero(16, 16)
		for int block in range((k + 15) / 16):
			left := tile_load(a, row, block * 16, k, 1, m, k, 16, 16)
			right := tile_load(b, block * 16, col, n, 1, k, n, 16, 16)
			acc += dot(left, right)
		tile_store(out, row, col, n, 1, m, n, acc)

void tile_matrix_case(int m, int n, int k):
	float32* a = cast(float32*, gpu_alloc((m * k + 1) * 4))
	float32* b = cast(float32*, gpu_alloc((k * n + 1) * 4))
	float32* out = cast(float32*, gpu_alloc((m * n + 2) * 4))
	float32* reference = cast(float32*, gpu_alloc((m * n + 2) * 4))
	for i in range(m * k): a[i] = (i % 7) - 3
	for i in range(k * n): b[i] = (i % 5) - 2
	for i in range(m * n + 2):
		out[i] = -999
		reference[i] = -999
	int programs = ((m + 15) / 16) * ((n + 15) / 16)
	tile_matmul_gpu(a, b, out, m, n, k, programs)
	if programs > 0:
		launch tensor_matmul_tiled_kernel[programs, 256](cast(float*, a), cast(float*, b), cast(float*, reference), m, k, n, k, 1, n, 1)
	gpu_sync()
	for row in range(m):
		for col in range(n):
			float32 want = 0
			for q in range(k): want += a[row * k + q] * b[q * n + col]
			assert_near(want, out[row * n + col])
			assert_near(reference[row * n + col], out[row * n + col])
	assert_near(-999, out[m * n])
	assert_near(-999, out[m * n + 1])
	gpu_free(cast(char*, a))
	gpu_free(cast(char*, b))
	gpu_free(cast(char*, out))
	gpu_free(cast(char*, reference))

void test_tile_matmul_edges():
	tile_matrix_case(0, 7, 3)
	tile_matrix_case(3, 0, 7)
	tile_matrix_case(1, 1, 0)
	tile_matrix_case(1, 1, 1)
	tile_matrix_case(15, 17, 19)
	tile_matrix_case(16, 16, 16)
	tile_matrix_case(17, 15, 16)
	tile_matrix_case(33, 31, 35)

# Register-tiled shapes: each thread holds a strided fragment of every tile.
void tile_matmul_64(float32* a, float32* b, float32* out, int m, int n, int k, int programs):
	gpu[1] for tile in range(programs):
		int columns = (n + 63) / 64
		int row = tile_program_id() / columns * 64
		int col = tile_program_id() % columns * 64
		acc := tile_zero(64, 64)
		for int block in range((k + 15) / 16):
			left := tile_load(a, row, block * 16, k, 1, m, k, 64, 16)
			right := tile_load(b, block * 16, col, n, 1, k, n, 16, 64)
			acc += dot(left, right)
		tile_store(out, row, col, n, 1, m, n, acc)

void tile_matmul_128(float32* a, float32* b, float32* out, int m, int n, int k, int programs):
	gpu[1] for tile in range(programs):
		int columns = (n + 127) / 128
		int row = tile_program_id() / columns * 128
		int col = tile_program_id() % columns * 128
		acc := tile_zero(128, 128)
		for int block in range((k + 15) / 16):
			left := tile_load(a, row, block * 16, k, 1, m, k, 128, 16)
			right := tile_load(b, block * 16, col, n, 1, k, n, 16, 128)
			acc += dot(left, right)
		tile_store(out, row, col, n, 1, m, n, acc)

# A rectangular 32x64 output with a 32-deep K step; B is read transposed
# (physically NxK) through its strides.
void tile_matmul_32x64_bt(float32* a, float32* bt, float32* out, int m, int n, int k, int programs):
	gpu[1] for tile in range(programs):
		int columns = (n + 63) / 64
		int row = tile_program_id() / columns * 32
		int col = tile_program_id() % columns * 64
		acc := tile_zero(32, 64)
		for int block in range((k + 31) / 32):
			left := tile_load(a, row, block * 32, k, 1, m, k, 32, 32)
			right := tile_load(bt, block * 32, col, 1, k, k, n, 32, 64)
			acc += dot(left, right)
		tile_store(out, row, col, n, 1, m, n, acc)

void tile_shaped_case(int shape, int m, int n, int k):
	float32* a = cast(float32*, gpu_alloc((m * k + 1) * 4))
	float32* b = cast(float32*, gpu_alloc((k * n + 1) * 4))
	float32* bt = cast(float32*, gpu_alloc((k * n + 1) * 4))
	float32* storage = cast(float32*, gpu_alloc((m * n + 4) * 4))
	float32* out = &storage[2]
	for i in range(m * k): a[i] = (i % 7) - 3
	for i in range(k * n): b[i] = (i % 5) - 2
	for q in range(k):
		for col in range(n): bt[col * k + q] = b[q * n + col]
	for i in range(m * n + 4): storage[i] = -999
	if shape == 0: tile_matmul_64(a, b, out, m, n, k, ((m + 63) / 64) * ((n + 63) / 64))
	else if shape == 1: tile_matmul_128(a, b, out, m, n, k, ((m + 127) / 128) * ((n + 127) / 128))
	else: tile_matmul_32x64_bt(a, bt, out, m, n, k, ((m + 31) / 32) * ((n + 63) / 64))
	gpu_sync()
	for row in range(m):
		for col in range(n):
			float32 want = 0
			for q in range(k): want += a[row * k + q] * b[q * n + col]
			# Small integer inputs keep every partial sum exact.
			assert_equal(cast(int, want), cast(int, out[row * n + col]))
	assert_near(-999, storage[0])
	assert_near(-999, storage[1])
	assert_near(-999, storage[m * n + 2])
	assert_near(-999, storage[m * n + 3])
	gpu_free(cast(char*, a))
	gpu_free(cast(char*, b))
	gpu_free(cast(char*, bt))
	gpu_free(cast(char*, storage))

void test_tile_register_tiled_shapes():
	for shape in range(3):
		tile_shaped_case(shape, 0, 5, 3)
		tile_shaped_case(shape, 1, 1, 0)
		tile_shaped_case(shape, 1, 1, 1)
		tile_shaped_case(shape, 64, 64, 64)
		tile_shaped_case(shape, 65, 63, 17)
		tile_shaped_case(shape, 129, 131, 37)
		tile_shaped_case(shape, 200, 70, 45)

# Elementwise arithmetic, comparisons, unfused dots and scalar broadcast
# over multi-register fragments.
void tile_fragment_ops(float32* a, float32* b, float32* out, float32 scale):
	gpu[1] for tile in range(1):
		left := tile_load(a, 0, 0, 32, 1, 64, 32, 64, 32)
		right := tile_load(b, 0, 0, 64, 1, 32, 64, 32, 64)
		product := dot(left, right)
		acc := tile_zero(64, 64)
		acc = 2.0
		acc -= dot(left, right)
		acc = acc + product * scale
		positive := (product > 0.0) * 1.0 + !product
		acc = acc * 2 + positive - (-product) / 4
		tile_store(out, 0, 0, 64, 1, 64, 64, acc)

void test_tile_fragment_elementwise_ops():
	float32* a = cast(float32*, gpu_alloc(64 * 32 * 4))
	float32* b = cast(float32*, gpu_alloc(32 * 64 * 4))
	float32* out = cast(float32*, gpu_alloc(64 * 64 * 4))
	for i in range(64 * 32):
		a[i] = (i % 7) - 3
		b[i] = (i % 5) - 2
	tile_fragment_ops(a, b, out, 3.0)
	gpu_sync()
	for row in range(64):
		for col in range(64):
			float32 p = 0
			for q in range(32): p += a[row * 32 + q] * b[q * 64 + col]
			float32 positive = 0
			if p > 0: positive = 1
			if p == 0: positive = 1
			float32 want = (2 - p + p * 3) * 2 + positive + p / 4
			assert_near(want, out[row * 64 + col])
	gpu_free(cast(char*, a))
	gpu_free(cast(char*, b))
	gpu_free(cast(char*, out))
