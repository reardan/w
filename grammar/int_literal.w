int int_literal():
	if ((token[0]) < '0' |  (token[0] > '9')):
		return 0
	int n = 0
	int i = 0
	while (token[i]):
		n = (n << 1) + (n << 3) + token[i] - '0'
		i = i + 1

	mov_eax_int(n)
	return 1
