# Compile-error fixture: only const globals fold into initializers.
int mutable_base = 5
int derived = mutable_base + 1


int main():
	return 0
