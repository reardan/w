# GPU execution coverage for tile arithmetic, indexing and cooperative layouts.
import lib.testing
import lib.cuda

void tile_ops_small(float32* a, float32* out, int n, int choice, float32 scale):
	gpu[17] for tile in range(n):
		int count = +choice
		count += 3
		count -= 1
		count *= 2
		int negative = -count
		float32 factor = +scale
		factor += 0.5
		factor -= 0.25
		factor *= 2
		value := -a[tile]
		value = +value
		value = value * factor / 2.0 + negative / 2 - count % 3
		value += !0 + !0.0 + !scale
		# The zero divisors must remain unreachable on the device.
		int zero = 0
		if (zero && (9 / zero)) || (choice && count > 0):
			value -= 1.5
		else:
			value += 1.5
		if choice || (9 / zero):
			for int step in range(1, 3): value += step
		float32 threshold = 2.0
		value += (a[tile] == threshold) + (a[tile] != threshold)
		value += (a[tile] < threshold) + (a[tile] >= threshold)
		value += (a[tile] > threshold) + (a[tile] <= threshold)
		value += (count == 6) + (count != 6) + (count < 6) + (count >= 6) + (count > 6) + (count <= 6)
		out[tile] = value
		out[tile] += 3
		out[tile] -= 1
		out[tile] *= 2

void test_tile_small_width_arithmetic():
	int n = 73
	float32* a = cast(float32*, gpu_alloc((n + 2) * 4))
	float32* out = cast(float32*, gpu_alloc((n + 2) * 4))
	for i in range(n + 2):
		a[i] = (i % 9) - 4
		out[i] = -991
	tile_ops_small(a, out, n, 1, 1.25)
	gpu_sync()
	for i in range(n):
		# factor=3, negative/2=-3, remainder=0, unary ! adds2,
		# branch subtracts1.5, loop adds3, comparisons add6.
		float32 want = ((-a[i] * 3 / 2 - 3 + 2 - 1.5 + 3 + 6) + 2) * 2
		assert_near(want, out[i])
	assert_near(-991, out[n])
	assert_near(-991, out[n + 1])
	gpu_free(cast(char*, a))
	gpu_free(cast(char*, out))

void tile_ops_nan(float32* out, int n, float32 value):
	gpu[17] for tile in range(n):
		# Ordered comparisons are false for NaN; != remains true.
		out[tile] = (value == 0) + (value < 0) + (value <= 0) + (value > 0) + (value >= 0) + !value + (value != 0) * 8

void test_tile_nan_and_signed_zero():
	float32* out = cast(float32*, gpu_alloc(4))
	float32 value = 0
	save_int(cast(char*, &value), 0x7fc00000)
	tile_ops_nan(out, 1, value)
	gpu_sync()
	assert_near(8, out[0])
	save_int(cast(char*, &value), cast(int, 0x80000000))
	tile_ops_nan(out, 1, value)
	gpu_sync()
	assert_near(4, out[0])
	gpu_free(cast(char*, out))

void tile_ops_copy(float32* a, float32* out, int n):
	gpu[513] for tile in range(n):
		out[tile] = a[tile] * 2

void tile_ops_inplace(float32* a, int n):
	gpu[513] for tile in range(n):
		a[tile] += 2
		a[tile] -= 1.0
		a[tile] *= 3.0

void test_tile_odd_width_copy_and_inplace():
	int n = 1031
	float32* storage = cast(float32*, gpu_alloc((n + 4) * 4))
	float32* output = cast(float32*, gpu_alloc((n + 4) * 4))
	float32* a = &storage[2]
	float32* out = &output[2]
	for i in range(n + 4):
		storage[i] = -991
		output[i] = -991
	for i in range(n): a[i] = i % 23
	tile_ops_copy(a, out, n)
	gpu_sync()
	for i in range(n):
		assert_near(a[i] * 2, out[i])
	assert_near(-991, output[0])
	assert_near(-991, output[1])
	assert_near(-991, output[n + 2])
	assert_near(-991, output[n + 3])
	tile_ops_inplace(a, n)
	gpu_sync()
	for i in range(n): assert_near(((i % 23) + 1) * 3, a[i])
	assert_near(-991, storage[0])
	assert_near(-991, storage[1])
	assert_near(-991, storage[n + 2])
	assert_near(-991, storage[n + 3])
	gpu_free(cast(char*, storage))
	gpu_free(cast(char*, output))

void tile_ops_matrix(float32* a, float32* b, float32* out, int enabled):
	gpu[1] for tile in range(1):
		# Negative origins leave invalid rows/columns participating in barriers.
		# A is physically KxM: strides transpose it into the logical MxK tile.
		left := tile_load(a, -1, 0, 1, 13, 13, 11, 16, 16)
		right := tile_load(b, 0, -2, 14, 1, 11, 14, 16, 16)
		acc := tile_zero(16, 16)
		for int repeat in range(2): acc += dot(left, right)
		if enabled: acc += dot(left, right)
		acc = (acc + 2.0) / 2
		acc -= 1
		acc *= 2
		acc = -(-acc)
		tile_store(out, -1, -2, 14, 1, 13, 14, acc)

void test_tile_matrix_transpose_negative_origins():
	float32* a = cast(float32*, gpu_alloc(13 * 11 * 4))
	float32* b = cast(float32*, gpu_alloc(11 * 14 * 4))
	float32* storage = cast(float32*, gpu_alloc((13 * 14 + 4) * 4))
	float32* out = &storage[2]
	for i in range(13 * 11): a[i] = (i % 7) - 3
	for i in range(11 * 14): b[i] = (i % 5) - 2
	for enabled in range(2):
		for i in range(13 * 14 + 4): storage[i] = -991
		tile_ops_matrix(a, b, out, enabled)
		gpu_sync()
		for row in range(13):
			for col in range(14):
				float32 want = 0
				for q in range(11): want += a[q * 13 + row] * b[q * 14 + col]
				assert_near(want * (2 + enabled), out[row * 14 + col])
		assert_near(-991, storage[0])
		assert_near(-991, storage[1])
		assert_near(-991, storage[13 * 14 + 2])
		assert_near(-991, storage[13 * 14 + 3])
	gpu_free(cast(char*, a))
	gpu_free(cast(char*, b))
	gpu_free(cast(char*, storage))
