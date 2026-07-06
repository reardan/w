# Compile-error fixture: interpolating an unsupported expression type
# (a non-char pointer) inside an f-string must be rejected.
int main():
	int* pointer = 0
	string s = f"p={pointer}"
	return 0
