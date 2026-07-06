# Compile-error fixture: 'default' must be the last clause in a switch;
# a case after it can never run.
int main():
	int r = 0
	switch (1):
		default:
			r = 99
		case 1:
			r = 10
	return r
