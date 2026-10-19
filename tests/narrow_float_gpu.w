# Storage conversion conformance on a real GPU. The default emit target
# reads the compiler's --ptx=<file> dump without running this CUDA-linked
# binary. The optional narrow_float_gpu_test runs the kernels on CUDA.
import lib.lib
import lib.cuda
import lib.assert
import lib.fmath

kernel narrow_float_convert(float32* input, float16* half, bfloat16* brain, float32* halfwide, float32* brainwide, int n):
	int i = block_idx() * block_dim() + thread_idx()
	if (i < n):
		half[i] = input[i]
		brain[i] = input[i]
		halfwide[i] = half[i]
		brainwide[i] = brain[i]


kernel narrow_float_storage(float16* half, bfloat16* brain, float32* halfwide, float32* brainwide, int n):
	int i = block_idx() * block_dim() + thread_idx()
	if (i < n):
		halfwide[i] = half[i]
		brainwide[i] = brain[i]
		half[i] = halfwide[i]
		brain[i] = brainwide[i]


kernel narrow_float_parameters(float32* out, float16 half, bfloat16 brain):
	out[0] = half
	out[1] = brain
	out[2] = half + brain


void check_narrow_gpu_parameters_and_captures():
	float32* out = cast(float32*, gpu_alloc(6 * 4))
	# Storage has already rounded these exact midpoint values to an even
	# significand before either launch transport or implicit capture.
	const float16 half = 1.00146484375
	const bfloat16 brain = 1.01171875
	launch narrow_float_parameters[1, 1](out, half, brain)
	gpu_sync()
	assert_equal_hex(0x3f804000, load_int32(&out[0]))
	assert_equal_hex(0x3f820000, load_int32(&out[1]))
	assert_equal_hex(0x40012000, load_int32(&out[2]))
	gpu for int i in range(3):
		out[3 + i] = half + brain + i
	gpu_sync()
	assert_equal_hex(0x40012000, load_int32(&out[3]))
	assert_equal_hex(0x40412000, load_int32(&out[4]))
	assert_equal_hex(0x40809000, load_int32(&out[5]))
	gpu_free(cast(char*, out))


void check_narrow_gpu_bits(float32 want, float32 got):
	# CUDA may canonicalize NaN payloads; classification is the contract.
	int want_bits = load_int32(&want)
	int got_bits = load_int32(&got)
	if (((want_bits & 0x7f800000) == 0x7f800000) && ((want_bits & 0x7fffff) != 0)):
		assert_equal_hex(0x7f800000, got_bits & 0x7f800000)
		assert1((got_bits & 0x7fffff) != 0)
	else: assert_equal_hex(want_bits, got_bits)


void check_narrow_gpu_rounding():
	list[int] patterns = list[int]{0, cast(int, 0x80000000), 0x3f800000, 0x3f801000, 0x3f803000, 0x3f808000, 0x3f818000, 0x33000000, 0x33000001, 0x33c00000, 0x387fe000, 0x38800000, 0x477fefff, 0x477ff000, 0x7f800000, cast(int, 0xff800000), 0x7f800001, 0x7fc00000, 0x7f7fffff, 0x00008000, 0x00008001, 0x00018000, cast(int, 0xb3000001), cast(int, 0xbf818000)}
	int n = 24
	float32* input = cast(float32*, gpu_alloc(n * 4))
	float16* half = cast(float16*, gpu_alloc(n * 2))
	bfloat16* brain = cast(bfloat16*, gpu_alloc(n * 2))
	float32* halfwide = cast(float32*, gpu_alloc(n * 4))
	float32* brainwide = cast(float32*, gpu_alloc(n * 4))
	for i in range(n): input[i] = float_from_bits(patterns[i])
	launch narrow_float_convert[1, 32](input, half, brain, halfwide, brainwide, n)
	gpu_sync()
	for i in range(n):
		float16 want_half = input[i]
		bfloat16 want_brain = input[i]
		check_narrow_gpu_bits(want_half, halfwide[i])
		check_narrow_gpu_bits(want_brain, brainwide[i])
		# Widen host/device storage separately to exercise each direction.
		check_narrow_gpu_bits(want_half, half[i])
		check_narrow_gpu_bits(want_brain, brain[i])
	patterns.free()
	gpu_free(cast(char*, input))
	gpu_free(cast(char*, half))
	gpu_free(cast(char*, brain))
	gpu_free(cast(char*, halfwide))
	gpu_free(cast(char*, brainwide))


void check_narrow_gpu_storage():
	int n = 65536
	float16* half = cast(float16*, gpu_alloc(n * 2))
	bfloat16* brain = cast(bfloat16*, gpu_alloc(n * 2))
	float32* halfwide = cast(float32*, gpu_alloc(n * 4))
	float32* brainwide = cast(float32*, gpu_alloc(n * 4))
	uint16* halfbits = cast(uint16*, half)
	uint16* brainbits = cast(uint16*, brain)
	for i in range(n):
		halfbits[i] = i
		brainbits[i] = i
	launch narrow_float_storage[256, 256](half, brain, halfwide, brainwide, n)
	gpu_sync()
	for i in range(n):
		float16 original_half
		bfloat16 original_brain
		uint16* hraw = cast(uint16*, &original_half)
		uint16* braw = cast(uint16*, &original_brain)
		*hraw = i
		*braw = i
		check_narrow_gpu_bits(original_half, halfwide[i])
		check_narrow_gpu_bits(original_brain, brainwide[i])
		if ((i & 0x7c00) != 0x7c00): assert_equal_hex(i, halfbits[i])
		if ((i & 0x7f80) != 0x7f80): assert_equal_hex(i, brainbits[i])
	gpu_free(cast(char*, half))
	gpu_free(cast(char*, brain))
	gpu_free(cast(char*, halfwide))
	gpu_free(cast(char*, brainwide))


int main():
	check_narrow_gpu_rounding()
	check_narrow_gpu_storage()
	check_narrow_gpu_parameters_and_captures()
	println(c"narrow float gpu OK")
	return 0
