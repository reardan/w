# Compile-error fixture: a radix type on a text value.
int main():
	char* p = c"x"
	string s = f"{p:x}"
	return 0
