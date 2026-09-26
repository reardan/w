# Compile-error fixture: enum_name needs an enum-typed value.
int main():
	int n = 3
	char* p = enum_name(n)
	return 0
