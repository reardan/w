# GPU-less PTX assertions for the 'gpu' pointer qualifier
# (docs/projects/cuda.md "Execution notes (gpu pointer qualifier)"):
# loads and stores through a 'gpu T*' use the global state space
# (cvta.to.global + ld.global/st.global) at every element width, while
# plain pointers keep the generic ld/st forms. The build target
# (tests/gpu_qualifier_ptx.w.wbuild) greps the printed module.
#
# x64-only (gpu kernels require the x64 target), so not *_test.w.
import lib.lib

char* __w_ptx_module();


struct gq_pair:
	int key
	float32 weight


# float32 loads and a store through gpu pointers.
kernel gq_saxpy(gpu float32* y, gpu float32* x, float32 a, int n):
	int i = block_idx() * block_dim() + thread_idx()
	if i < n:
		y[i] = a * x[i] + y[i]


# int (64-bit), int32, uint8, int8 and int16 widths, a compound
# assignment (global load + global store of the same element) and an
# element read into an inferred local, which must stay a plain local.
kernel gq_widths(gpu int* w, gpu int32* d, gpu uint8* b, gpu int8* c, gpu int16* h, int n):
	int i = block_idx() * block_dim() + thread_idx()
	if i < n:
		w[i] += 3
		d[i] = d[i] + 1
		b[i] = b[i] + c[i]
		h[i] = 7
		v := w[i]
		w[i] = v * 2


# Struct fields through a gpu pointer stay global: '.key' is an int
# field (ld.global.u64), '.weight' a float32 field.
kernel gq_fields(gpu gq_pair* p, int n):
	int i = block_idx() * block_dim() + thread_idx()
	if i < n:
		p.weight = p.weight + 1.0
		p.key = p.key + i


# Plain pointers keep generic accesses (managed memory is valid on both
# sides; nothing proves its state space).
kernel gq_plain(float32* y, int n):
	int i = block_idx() * block_dim() + thread_idx()
	if i < n:
		y[i] = y[i] + 1.0


int main(int argc, int argv):
	print(__w_ptx_module())
	return 0
