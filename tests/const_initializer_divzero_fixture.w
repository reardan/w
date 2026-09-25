# Compile-error fixture: division by zero in an enum value.
enum broken_enum:
	fine = 1
	broken = fine / 0


int main():
	return 0
