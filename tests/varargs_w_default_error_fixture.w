# Compile-error fixture: defaults and a variadic tail are mutually
# exclusive; a variadic parameter may not follow defaulted parameters.
int vw_bad(int a, int b = 1, int... rest):
	return a


int main():
	return vw_bad(1)
