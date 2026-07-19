# String literals embed host-image blobs, which device (PTX) code
# cannot address.
# wfixture: x64
# expect_fail
# expect_stderr: strings are not supported in gpu code
kernel bad(int* v, int n):
	char* s = c"nope"
	v[0] = 0

int main():
	return 0
