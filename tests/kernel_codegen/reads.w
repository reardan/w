# Discarded reads under --kernel-codegen (tests/kernel_codegen_test.w):
# each exported function names a memory location as a statement on its
# own, the shape of C's '(void)*p' or a bare READ_ONCE(x) of a device
# register. tests/kernel_codegen/reads_main.c calls each on a PROT_NONE
# page in a child process and expects the read to fault.
struct kr_pair:
	int first
	int second

int kr_global


export void kr_deref(int* p):
	*p


export void kr_index(int* p):
	p[3]


export void kr_byte(char* p):
	p[17]


export void kr_field(kr_pair* q):
	q.second


export void kr_global_read():
	kr_global


export int* kr_global_address():
	return &kr_global


# Address arithmetic alone reads nothing.
export void kr_nothing(int* p):
	int* q = p + 8
