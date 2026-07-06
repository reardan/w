# Compile-error fixture: an embedded expression whose '{' is never
# closed must fail with "'}' expected in template string expression".
int main():
	int x = 1
	string s = f"{x
	return 0
