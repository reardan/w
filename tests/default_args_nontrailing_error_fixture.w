# Compile-error fixture: once a parameter declares a default, every
# following parameter must declare one too.
int da_bad(int a = 1, int b):
	return a + b


int main():
	return da_bad(1, 2)
