import lib.linux


int _main(int argc, char** argv):
	if (argc < 2): return 2
	# The argument count keeps arithmetic live in the emitted program.
	int n = argc + 40
	if ((n / 6) != 7): return 3
	if ((n * 6) != 252): return 4
	if (((0 - n) / 6) != -7): return 5
	if ((n >> argc) != 10): return 6
	if ((n << argc) != 168): return 7
	char* p = cast(char*, malloc(8))
	if (argv[1][0] == 'u'):
		int quotient = p[0] / n
		if (quotient == 1): return 8
	elif (argv[1][0] == 's'):
		int shifted = 1 << p[0]
		if (shifted == 2): return 9
	else:
		int zero = argc - 2
		int product = p[0] * zero
		if (product != 0): return 10
	free(p)
	return 0
