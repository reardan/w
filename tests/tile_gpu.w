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
