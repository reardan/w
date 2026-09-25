# Compile-error fixture: a folded global initializer must fit 32 bits.
const int too_big = 1 << 31


int main():
	return 0
