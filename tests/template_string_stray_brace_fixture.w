# Compile-error fixture: a single '}' in f-string literal text must be
# written as '}}'.
int main():
	string s = f"a } b"
	return 0
