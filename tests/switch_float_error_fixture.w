# Compile-error fixture: switching on a float scrutinee would compare
# raw bit patterns, so it is rejected.
int main():
	int r = 0
	switch (1.5):
		case 1.5:
			r = 1
	return r
