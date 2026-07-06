# Compile-error fixture: a "T... name" variadic parameter must be the
# last parameter in the list.
int vw_bad(int... values, int tail):
	return tail


int main():
	return vw_bad(1, 2)
