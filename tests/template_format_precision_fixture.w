# Compile-error fixture: precision on an int value.
int main():
	int n = 1
	string s = f"{n:.2}"
	return 0
