# Everything the gpu pointer qualifier allows in host code compiles
# without a diagnostic: cast() in and out (the escape hatch), untyped
# constants, 'gpu void*' within the device domain, address arithmetic
# ('&d[i]', 'd + n') without a dereference, aliases, gpu-qualified
# parameters/returns/globals, and pointers-to-gpu-pointers (a host
# array of device pointers). Asserted by bin/wfixture in the
# cuda_diagnostics_test target.
# reject_stderr: warning
# reject_stderr: error
import lib.lib


type devbuf = gpu float32*

gpu int* gq_global


struct gq_rec:
	int a
	int b


gpu int* gq_pass(gpu int* p):
	return p


int main(int argc, int argv):
	gpu int* d = cast(gpu int*, malloc(64))
	gpu int* none = 0
	gpu void* untyped = d
	gpu int* back = untyped
	gpu int* second = &d[1]
	gpu int* shifted = d + 8
	int* host_view = cast(int*, d)
	host_view[0] = 1
	devbuf f = cast(devbuf, malloc(16))
	gpu float32* g = f
	gq_global = gq_pass(back)
	gpu int** table = cast(gpu int**, malloc(16))
	table[0] = d
	gpu int* first = table[0]
	gpu gq_rec* recs = cast(gpu gq_rec*, malloc(32))
	int addr = cast(int, &recs.b)
	int words = sizeof(gq_rec)
	if (cast(int, none) != 0):
		return 1
	if ((cast(int, second) - cast(int, d)) != __word_size__):
		return 1
	if ((cast(int, shifted) - cast(int, d)) != 8):
		return 1
	return (addr - cast(int, recs)) + words + cast(int, g) * 0 + cast(int, first) * 0 - __word_size__ - words
