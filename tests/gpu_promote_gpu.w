# Regression surface for the PTX local-promotion pass (ptx_promote in
# code_generator/ptx.w, cuda.md A2 step 2): device behavior that only
# stays correct while promotion preserves memory semantics exactly.
#
# - sub-word locals (char / int16): a promoted register must reproduce
#   the store-truncate-then-load-widen bits of the .local slot it
#   replaced, including sign extension through wraparound.
# - a captured pointer reassigned inside the body: writes to the
#   capture cell mean that capture must NOT be promoted (the register
#   would go stale against the memory the next read would have seen if
#   any access were left unrewritten) -- the pass keeps the whole slot
#   in memory instead.
#
# gpu_promote_compile_test (default umbrella) compiles this GPU-less;
# gpu_promote_test (opt-in, next to cuda_test) runs it on hardware and
# cross-checks against the host's own sub-word arithmetic.
import lib.lib
import lib.assert
import lib.cuda

int main():
	if (gpu_available() == 0):
		print(c"gpu promote: no gpu\n")
		return 0
	int n = 64
	int* out = cast(int*, gpu_alloc(n * 8))
	# Sub-word locals: char wraps through 100-step increments, int16
	# holds values outside char range; both re-widen on every read.
	gpu for int i in range(n):
		char cc = i * 5 - 100
		int16 ss = i * 1000 - 20000
		int acc = 0
		for j in range(3):
			acc = acc + cc + ss
			cc = cc + 100
		out[i] = acc
	gpu_sync()
	for i2 in range(n):
		char ch = i2 * 5 - 100
		int16 sh = i2 * 1000 - 20000
		int acc2 = 0
		for j2 in range(3):
			acc2 = acc2 + ch + sh
			ch = ch + 100
		assert_equal(acc2, out[i2])
	# Captured pointer reassigned in the body: the capture cell is
	# written, so it must keep its .local slot. The +8 is a raw byte
	# step (T* + int never scales), i.e. one 8-byte int per iteration.
	int* base = cast(int*, gpu_alloc(8 * 8))
	int k = 0
	while (k < 8):
		base[k] = 0
		k = k + 1
	int* wp = base
	gpu for int t in range(1):
		for q in range(8):
			*wp = q + 7
			wp = wp + 8
	gpu_sync()
	k = 0
	while (k < 8):
		assert_equal(k + 7, base[k])
		k = k + 1
	print(c"gpu promote OK\n")
	return 0
