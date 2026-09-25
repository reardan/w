# GPU end-to-end test for the 'gpu' pointer qualifier
# (docs/projects/cuda.md "Execution notes (gpu pointer qualifier)"):
# device-only buffers from gpu_device_alloc typed 'gpu T*' through an
# explicit cast(), moved with gpu_memcpy_to/from, and touched only by
# device code — a raw kernel with gpu-qualified parameters, a kernel
# with plain pointer parameters launched with gpu pointers, a 'gpu for'
# capturing gpu pointers (int, float32, uint8 and struct-field
# elements), all through ld.global/st.global. Needs a real NVIDIA GPU,
# so the gpu_qualifier_test target is opt-in like cuda_test; the
# GPU-less gpu_qualifier_ptx_test compiles this file with --ptx.
import lib.lib
import lib.cuda


# 4-byte fields only: W packs structs, and an 8-byte field at an odd
# multiple of a 12-byte stride would be a misaligned device access.
struct gq_cell:
	int32 count
	float32 total


kernel gq_scale(gpu float32* y, gpu float32* x, float32 a, int n):
	int i = block_idx() * block_dim() + thread_idx()
	if i < n: y[i] = a * x[i] + y[i]


# Plain pointer parameters accept gpu pointers at the launch site: a
# kernel's plain pointer means "any device-accessible memory".
kernel gq_plain_inc(int* v, int n):
	int i = block_idx() * block_dim() + thread_idx()
	if i < n: v[i] = v[i] + 1


# Device-only float32 saxpy; returns 1 when the copy-back matches.
int check_float_kernel(int n):
	int bytes = n * 4
	float32* hx = cast(float32*, malloc(bytes))
	float32* hy = cast(float32*, malloc(bytes))
	int i = 0
	while (i < n):
		hx[i] = i
		hy[i] = 1.0
		i = i + 1
	gpu float32* dx = cast(gpu float32*, gpu_device_alloc(bytes))
	gpu float32* dy = cast(gpu float32*, gpu_device_alloc(bytes))
	gpu_memcpy_to(cast(char*, dx), cast(char*, hx), bytes)
	gpu_memcpy_to(cast(char*, dy), cast(char*, hy), bytes)
	int threads = 128
	launch gq_scale[(n + threads - 1) / threads, threads](dy, dx, 2.0, n)
	gpu_memcpy_from(cast(char*, hy), cast(char*, dy), bytes)
	int ok = 1
	i = 0
	while (i < n):
		float32 want = 2.0 * i + 1.0
		if (hy[i] != want): ok = 0
		i = i + 1
	gpu_free(cast(char*, dx))
	gpu_free(cast(char*, dy))
	free(cast(char*, hx))
	free(cast(char*, hy))
	return ok


# 'gpu for' over gpu pointers of three element kinds plus struct
# fields, and a plain-parameter kernel launched with a gpu pointer.
int check_gpu_for(int n):
	int* hi = cast(int*, malloc(n * 8))
	uint8* hb = cast(uint8*, malloc(n))
	gq_cell* hc = cast(gq_cell*, malloc(n * sizeof(gq_cell)))
	int i = 0
	while (i < n):
		hi[i] = 3 * i
		hb[i] = i & 127
		hc[i].count = i
		hc[i].total = 0.5
		i = i + 1
	gpu int* di = cast(gpu int*, gpu_device_alloc(n * 8))
	gpu uint8* db = cast(gpu uint8*, gpu_device_alloc(n))
	gpu gq_cell* dc = cast(gpu gq_cell*, gpu_device_alloc(n * sizeof(gq_cell)))
	gpu_memcpy_to(cast(char*, di), cast(char*, hi), n * 8)
	gpu_memcpy_to(cast(char*, db), cast(char*, hb), n)
	gpu_memcpy_to(cast(char*, dc), cast(char*, hc), n * sizeof(gq_cell))
	gpu for int j in range(n):
		di[j] += db[j]
		db[j] = db[j] + 1
		gpu gq_cell* cell = &dc[j]
		cell.count = cell.count * 2
		cell.total = cell.total + 1.0
	int threads = 256
	launch gq_plain_inc[(n + threads - 1) / threads, threads](di, n)
	gpu_memcpy_from(cast(char*, hi), cast(char*, di), n * 8)
	gpu_memcpy_from(cast(char*, hb), cast(char*, db), n)
	gpu_memcpy_from(cast(char*, hc), cast(char*, dc), n * sizeof(gq_cell))
	int ok = 1
	i = 0
	while (i < n):
		if (hi[i] != 3 * i + (i & 127) + 1): ok = 0
		if (hb[i] != (i & 127) + 1): ok = 0
		if (hc[i].count != 2 * i): ok = 0
		if (hc[i].total != 1.5): ok = 0
		i = i + 1
	gpu_free(cast(char*, di))
	gpu_free(cast(char*, db))
	gpu_free(cast(char*, dc))
	free(cast(char*, hi))
	free(cast(char*, hb))
	free(cast(char*, hc))
	return ok


int main(int argc, int argv):
	int n = 1000
	if (check_float_kernel(n) == 0):
		println(c"gpu qualifier FAIL: float kernel")
		return 1
	if (check_gpu_for(n) == 0):
		println(c"gpu qualifier FAIL: gpu for")
		return 1
	println(c"gpu qualifier OK")
	return 0
