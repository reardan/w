# Reproducible CUDA benchmark: correctness is checked before warmup and timing.
# Ordinary tests only compile this driver; runtime requires an NVIDIA device.
# wbuild: target=tile_benchmark_compile_test tag=tests dep=wv2
# wbuild: step="bin/wv2 x64 --strict tests/tile_benchmark.w -o bin/tile_benchmark --ptx=bin/tile_benchmark.ptx"
# wbuild: target=tile_benchmark dep=tile_benchmark_compile_test
# wbuild: step="bin/tile_benchmark"
import lib.tensor
import lib.time


int tile_bench_now_ns():
	timespec ts
	asserts(c"monotonic clock", sys_clock_gettime(clock_monotonic, cast(int, &ts)) == 0)
	return ts.seconds * 1000000000 + ts.nanoseconds


void tile_bench_matrix(float32* a, float32* b, float32* out, int m, int n, int k, int programs):
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


void tile_bench_matrix_launch(int reference, float32* a, float32* b, float32* out, int m, int n, int k):
	int programs = ((m + 15) / 16) * ((n + 15) / 16)
	if reference:
		launch tensor_matmul_tiled_kernel[programs, 256](cast(float*, a), cast(float*, b), cast(float*, out), m, k, n, k, 1, n, 1)
	else:
		tile_bench_matrix(a, b, out, m, n, k, programs)


int tile_bench_matrix_time(int reference, float32* a, float32* b, float32* out, int m, int n, int k, int reps):
	gpu_sync()
	int start = tile_bench_now_ns()
	for rep in range(reps): tile_bench_matrix_launch(reference, a, b, out, m, n, k)
	gpu_sync()
	return (tile_bench_now_ns() - start) / reps


void tile_bench_matrix_case(int m, int n, int k, int reps, int batches):
	float32* a = cast(float32*, gpu_alloc((m * k + 1) * 4))
	float32* b = cast(float32*, gpu_alloc((k * n + 1) * 4))
	float32* out = cast(float32*, gpu_alloc((m * n + 2) * 4))
	float32* reference = cast(float32*, gpu_alloc((m * n + 2) * 4))
	for i in range(m * k): a[i] = i % 7 - 3
	for i in range(k * n): b[i] = i % 5 - 2
	for i in range(m * n + 2):
		out[i] = -999
		reference[i] = -999
	tile_bench_matrix_launch(0, a, b, out, m, n, k)
	tile_bench_matrix_launch(1, a, b, reference, m, n, k)
	gpu_sync()
	# Small integer inputs make all sums exact float32 values at these sizes.
	for row in range(m):
		for col in range(n):
			float32 want = 0
			for q in range(k): want += a[row * k + q] * b[q * n + col]
			asserts(c"tile matrix CPU reference", out[row * n + col] == want)
			asserts(c"tensor matrix CPU reference", reference[row * n + col] == want)
	for i in range(m * n, m * n + 2):
		asserts(c"matrix output guard", out[i] == -999 && reference[i] == -999)
	for warm in range(5):
		tile_bench_matrix_launch(0, a, b, out, m, n, k)
		tile_bench_matrix_launch(1, a, b, reference, m, n, k)
	gpu_sync()
	for batch in range(batches):
		int tile_ns
		int reference_ns
		if batch % 2 == 0:
			tile_ns = tile_bench_matrix_time(0, a, b, out, m, n, k, reps)
			reference_ns = tile_bench_matrix_time(1, a, b, reference, m, n, k, reps)
		else:
			reference_ns = tile_bench_matrix_time(1, a, b, reference, m, n, k, reps)
			tile_ns = tile_bench_matrix_time(0, a, b, out, m, n, k, reps)
		print(f"matrix,{m},{n},{k},1,{m * n},{batch},{tile_ns},{reference_ns}\n")
	gpu_free(cast(char*, a))
	gpu_free(cast(char*, b))
	gpu_free(cast(char*, out))
	gpu_free(cast(char*, reference))


void tile_bench_vector_1(float32* a, float32* b, float32* out, int n):
	gpu[1] for tile in range(n):
		out[tile] = a[tile] + b[tile]


void tile_bench_vector_17(float32* a, float32* b, float32* out, int n):
	gpu[17] for tile in range(n):
		out[tile] = a[tile] + b[tile]


void tile_bench_vector_255(float32* a, float32* b, float32* out, int n):
	gpu[255] for tile in range(n):
		out[tile] = a[tile] + b[tile]


void tile_bench_vector_256(float32* a, float32* b, float32* out, int n):
	gpu[256] for tile in range(n):
		out[tile] = a[tile] + b[tile]


void tile_bench_vector_257(float32* a, float32* b, float32* out, int n):
	gpu[257] for tile in range(n):
		out[tile] = a[tile] + b[tile]


void tile_bench_vector_513(float32* a, float32* b, float32* out, int n):
	gpu[513] for tile in range(n):
		out[tile] = a[tile] + b[tile]


void tile_bench_vector_1024(float32* a, float32* b, float32* out, int n):
	gpu[1024] for tile in range(n):
		out[tile] = a[tile] + b[tile]


void tile_bench_vector_launch(int width, float32* a, float32* b, float32* out, int n):
	# The reference is the scalar GPU loop used by tensor_add_into.
	if width == 0:
		gpu for int i in range(n):
			out[i] = a[i] + b[i]
	else if width == 1: tile_bench_vector_1(a, b, out, n)
	else if width == 17: tile_bench_vector_17(a, b, out, n)
	else if width == 255: tile_bench_vector_255(a, b, out, n)
	else if width == 256: tile_bench_vector_256(a, b, out, n)
	else if width == 257: tile_bench_vector_257(a, b, out, n)
	else if width == 513: tile_bench_vector_513(a, b, out, n)
	else if width == 1024: tile_bench_vector_1024(a, b, out, n)
	else: asserts(c"unsupported benchmark width", 0)


int tile_bench_vector_time(int width, float32* a, float32* b, float32* out, int n, int reps):
	gpu_sync()
	int start = tile_bench_now_ns()
	for rep in range(reps): tile_bench_vector_launch(width, a, b, out, n)
	gpu_sync()
	return (tile_bench_now_ns() - start) / reps


void tile_bench_vector_case(int width, int n, int reps, int batches):
	float32* a = cast(float32*, gpu_alloc((n + 2) * 4))
	float32* b = cast(float32*, gpu_alloc((n + 2) * 4))
	float32* out = cast(float32*, gpu_alloc((n + 2) * 4))
	float32* reference = cast(float32*, gpu_alloc((n + 2) * 4))
	for i in range(n + 2):
		a[i] = i % 13 - 6
		b[i] = i % 7 - 3
		out[i] = -999
		reference[i] = -999
	tile_bench_vector_launch(width, a, b, out, n)
	tile_bench_vector_launch(0, a, b, reference, n)
	gpu_sync()
	for i in range(n):
		float32 want = a[i] + b[i]
		asserts(c"tile vector CPU reference", out[i] == want)
		asserts(c"scalar vector CPU reference", reference[i] == want)
	for i in range(n, n + 2):
		asserts(c"vector output guard", out[i] == -999 && reference[i] == -999)
	for warm in range(5):
		tile_bench_vector_launch(width, a, b, out, n)
		tile_bench_vector_launch(0, a, b, reference, n)
	gpu_sync()
	for batch in range(batches):
		int tile_ns
		int reference_ns
		if batch % 2 == 0:
			tile_ns = tile_bench_vector_time(width, a, b, out, n, reps)
			reference_ns = tile_bench_vector_time(0, a, b, reference, n, reps)
		else:
			reference_ns = tile_bench_vector_time(0, a, b, reference, n, reps)
			tile_ns = tile_bench_vector_time(width, a, b, out, n, reps)
		print(f"vector,0,0,0,{width},{n},{batch},{tile_ns},{reference_ns}\n")
	gpu_free(cast(char*, a))
	gpu_free(cast(char*, b))
	gpu_free(cast(char*, out))
	gpu_free(cast(char*, reference))


int main(int argc, char** argv):
	int reps = 100
	int batches = 3
	if argc > 1: reps = atoi(argv[1])
	if argc > 2: batches = atoi(argv[2])
	asserts(c"usage: tile_benchmark [positive launches_per_batch] [positive batches]", argc <= 3 && reps > 0 && batches > 0)
	asserts(c"tile benchmark requires CUDA", gpu_available())
	print(f"# launches_per_batch={reps},batches={batches},warmup_pairs=5,timing=host_launch_plus_batch_sync_ns\n")
	print(c"kind,m,n,k,width,elements,batch,tile_ns,reference_ns\n")
	tile_bench_matrix_case(1, 1, 0, reps, batches)
	tile_bench_matrix_case(1, 1, 1, reps, batches)
	tile_bench_matrix_case(15, 17, 19, reps, batches)
	tile_bench_matrix_case(16, 16, 16, reps, batches)
	tile_bench_matrix_case(64, 64, 64, reps, batches)
	tile_bench_matrix_case(128, 128, 128, reps, batches)
	tile_bench_matrix_case(256, 256, 256, reps, batches)
	tile_bench_matrix_case(512, 512, 512, reps, batches)
	tile_bench_matrix_case(511, 513, 509, reps, batches)
	tile_bench_vector_case(1, 1, reps, batches)
	tile_bench_vector_case(1, 2, reps, batches)
	tile_bench_vector_case(1, 65539, reps, batches)
	tile_bench_vector_case(17, 17, reps, batches)
	tile_bench_vector_case(17, 18, reps, batches)
	tile_bench_vector_case(17, 65539, reps, batches)
	tile_bench_vector_case(255, 255, reps, batches)
	tile_bench_vector_case(255, 256, reps, batches)
	tile_bench_vector_case(255, 65539, reps, batches)
	tile_bench_vector_case(256, 256, reps, batches)
	tile_bench_vector_case(256, 257, reps, batches)
	tile_bench_vector_case(256, 65539, reps, batches)
	tile_bench_vector_case(257, 257, reps, batches)
	tile_bench_vector_case(257, 258, reps, batches)
	tile_bench_vector_case(257, 65539, reps, batches)
	tile_bench_vector_case(513, 513, reps, batches)
	tile_bench_vector_case(513, 514, reps, batches)
	tile_bench_vector_case(513, 65539, reps, batches)
	tile_bench_vector_case(1024, 1024, reps, batches)
	tile_bench_vector_case(1024, 1025, reps, batches)
	tile_bench_vector_case(1024, 65539, reps, batches)
	return 0
