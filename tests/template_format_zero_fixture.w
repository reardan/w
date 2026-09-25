# Compile-error fixture: zero padding on a text value.
int main():
	char* p = c"x"
	string s = f"{p:05}"
	return 0
