# GPU-less PTX emitter smoke (docs/projects/cuda.md Stage 2): define
# kernels in W, then print the embedded PTX module so the build target
# can grep it for the load-bearing instructions. Runs on any x64 Linux
# machine — no GPU, no libcuda: defining kernels only adds PTX text and
# the synthesized __w_ptx_module accessor to the binary.
#
# x64-only (gpu kernels require the x64 target), so this file is not
# *_test.w-suffixed: the build target is hand-declared in build.base.json
# (the cuda_smoke precedent) instead of wbuildgen's default-target twin.
import lib.lib

char* __w_ptx_module();


# Float vector add: the cuda.md reference kernel.
kernel add(float32* a, float32* b, float32* c, int n):
	int i = block_idx() * block_dim() + thread_idx()
	if i < n:
		c[i] = a[i] + b[i]


# Integer kernel: while-loop (grid-stride), multiplication, comparisons.
kernel scale(int* v, int n, int k):
	int i = block_idx() * block_dim() + thread_idx()
	int stride = grid_dim() * block_dim()
	while (i < n):
		v[i] = v[i] * k
		i = i + stride


# float64 arithmetic and an int -> float conversion.
kernel axpb64(float64* y, float64 aa, float64 b, int n):
	int i = block_idx() * block_dim() + thread_idx()
	if i < n:
		y[i] = aa * y[i] + b + i


# All nine 32-bit limb/bit intrinsics on device (same masked-unsigned
# contract as the host lowering; cuda_test cross-checks the results
# against the host's own intrinsics).
kernel bits(int* v, int n):
	int i = block_idx() * block_dim() + thread_idx()
	if i < n:
		int x = v[i]
		int hi = 0
		int carry = 0
		int acc = mul_hi(x, 0x10001)
		acc = acc + mul_wide(x, 3, &hi) + hi
		acc = acc + add_carry(x, x, &carry) + carry
		acc = acc + shr(x, 3) + rotl(x, 5) + rotr(x, 7)
		acc = acc + popcount(x) + clz(x) + ctz(x)
		v[i] = acc


# Atomics: the int add/min/max forms and the float32 add form.
kernel accum(int* s, int* mn, int* mx, float32* f, int n):
	int i = block_idx() * block_dim() + thread_idx()
	if i < n:
		atomic_add(s, i)
		atomic_min(mn, i)
		atomic_max(mx, i)
		atomic_add(f, 1.5)


# gpu_exp/gpu_log device transcendentals (docs/projects/torch.md
# Workstream E): exp via a log2(e) multiply then ex2.approx.f32; log
# via lg2.approx.f32 then a ln(2) multiply.
kernel transcendental(float32* a, float32* b, int n):
	int i = block_idx() * block_dim() + thread_idx()
	if i < n:
		float32 x = a[i]
		b[i] = gpu_exp(x) + gpu_log(x)


# gpu_shared_f32/gpu_barrier (docs/projects/torch.md Stage 4): a
# .shared array declaration + cvta.shared generic address, and the
# block-wide bar.sync.
kernel stage(float32* a, int n):
	float* buf = gpu_shared_f32(256)
	int tid = thread_idx()
	buf[tid] = 0.0
	gpu_barrier()
	if tid < n:
		a[tid] = buf[tid]


int main(int argc, int argv):
	print(__w_ptx_module())
	return 0
