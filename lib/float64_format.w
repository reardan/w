import lib.lib


char* f64toa(float64 f):
	char* s = malloc(96)
	int pos = 0
	if (f < 0.0):
		s[pos] = '-'
		pos = pos + 1
		f = -f
	int whole = f
	char* whole_digits = itoa(whole)
	strcpy(s + pos, whole_digits)
	free(whole_digits)
	pos = strlen(s)
	s[pos] = '.'
	pos = pos + 1
	float64 frac = f - whole
	int i = 0
	while (i < 6):
		frac = frac * 10.0
		int digit = frac
		s[pos] = digit + '0'
		pos = pos + 1
		frac = frac - digit
		i = i + 1
	s[pos] = 0
	return s
