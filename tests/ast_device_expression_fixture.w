import lib.cuda

kernel ast_device_mix(int* out, float32* floats, int n):
	int i = block_idx() * block_dim() + thread_idx()
	if (i < n):
		int bits = rotl(i, 3) ^ popcount(i)
		out[i] = (bits > 2 && i != 7) ? bits : -bits
		out[i] += grid_dim()
		atomic_add(out, i)
		atomic_min(out, i - 1)
		atomic_max(out, i + 1)
		atomic_add(floats, gpu_exp(1.0) + gpu_log(2.0))

kernel ast_device_shared(float32* out):
	float* a = gpu_shared_f32(32)
	float* b = gpu_shared_f32(16)
	int i = thread_idx()
	a[i] = cast(float32, i)
	gpu_barrier()
	if (i < 16):
		b[i] = a[i] + 1.0
		out[i] = b[i]

void ast_device_capture(int* out, float32* floats, int n, int bias, float32 gain):
	gpu for int i in range(n):
		out[i] = out[i] + bias * bias
		floats[i] = gain * floats[i] + bias
		out[i] = out[i] + n

int main(): return 0
