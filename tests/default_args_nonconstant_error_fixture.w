# Compile-error fixture: default parameter values must be compile-time
# constants (integer/char literals or named enum constants).
int da_shift_amount


int da_bad(int a = da_shift_amount):
	return a


int main():
	return da_bad()
