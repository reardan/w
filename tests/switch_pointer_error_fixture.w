# Compile-error fixture: switch on a non-char pointer could only match
# by identity, so it is rejected.
int main():
	int* p = 0
	switch p:
		case 0: return 1
	return 0
