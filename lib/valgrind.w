# Valgrind client-request ABI (valgrind.h / memcheck.h), Linux x86/x64.
# Only initialized for W_DEBUG_ALLOC=valgrind. No libc or allocation is
# needed: a single W^X page holds the request instruction sequence.
# ABI reference: https://valgrind.org/docs/manual/manual-core-adv.html
import lib.linux

const int vg_running = 0x1001
const int vg_malloclike = 0x1301
const int vg_freelike = 0x1302
const int vg_make_defined = 0x4d430002

int vg_thunk
int vg_active

type vg_callback = fn(int*) -> int


int vg_request(int request, int a, int b, int c, int d):
	int[6] args
	args[0] = request
	args[1] = a
	args[2] = b
	args[3] = c
	args[4] = d
	args[5] = 0
	return (cast(vg_callback*, vg_thunk))(&args[0])


int vg_init():
	if (vg_active): return 1
	if (__target_isa__ != 0): return 0
	if (vg_thunk == 0):
		int page = mmap(0, 4096, 3, 34)
		if ((page < 0) && (page > -4096)): return 0
		# W stack ABI: one argument just above the return address.
		# eax/rax = request vector, edx/rdx = default/result. The four
		# rotations preserve edi/rdi; xchg is Valgrind's request marker.
		char* code = c"\x8b\x44\x24\x04\x31\xd2\xc1\xc7\x03\xc1\xc7\x0d\xc1\xc7\x1d\xc1\xc7\x13\x87\xdb\x89\xd0\xc3"
		int length = 23
		if (__word_size__ == 8):
			code = c"\x48\x8b\x44\x24\x08\x31\xd2\x48\xc1\xc7\x03\x48\xc1\xc7\x0d\x48\xc1\xc7\x3d\x48\xc1\xc7\x33\x48\x87\xdb\x48\x89\xd0\xc3"
			length = 30
		char* dst = cast(char*, page)
		for i in range(length): dst[i] = code[i]
		if (mprotect(page, 4096, 5) != 0):
			munmap(page, 4096)
			return 0
		vg_thunk = page
	vg_active = vg_request(vg_running, 0, 0, 0, 0)
	return vg_active
