# String literals embed host-image blobs, which device (PTX) code
# cannot address. Compiled with the x64 selector by the
# cuda_diagnostics_test target.
kernel bad(int* v, int n):
	char* s = c"nope"
	v[0] = 0

int main():
	return 0
