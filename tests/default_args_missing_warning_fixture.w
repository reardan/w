# Warning fixture: too few arguments when the missing parameter has no
# default keeps the existing arity warning.
int da_no_defaults(int a, int b):
	return a + b


int main():
	return da_no_defaults(1)
