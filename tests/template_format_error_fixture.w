# Compile-error fixture: an unknown format spec type.
int main():
	int n = 1
	string s = f"{n:q}"
	return 0
