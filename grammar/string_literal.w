int process_string_literal():
	int i = 0
	int j = 1
	int k
	while (token[j] != '"'):
		# \x0a formatting
		if ((token[j] == 92) & (token[j + 1] == 'x')):
			if (token[j + 2] <= '9'):
				k = token[j + 2] - '0'
			else:
				k = token[j + 2] - 'a' + 10
			k = k << 4
			if (token[j + 3] <= '9'):
				k = k + token[j + 3] - '0'
			else:
				k = k + token[j + 3] - 'a' + 10
			token[i] = k
			j = j + 4

		else:
			token[i] = token[j]
			j = j + 1

		i = i + 1
	return i


# like a char_pointer_literal()
# except it emits the code directly to be executed
int raw_asm_literal():
	if (accept("raw_asm") == 0):
		return 0
	expect("(")
	if (token[0] != '"'):
		error("double quote expected inside raw_asm( ... ) literal")

	int i = process_string_literal()
	emit(i, token)
	get_token()
	expect(")")
	return 1


int char_pointer_literal():
	if (token[0] != '"'):
		return 0
	int i = process_string_literal()
	token[i] = 0
	/* call ... ; the string ; pop %eax */
	emit(5, "\xe8....")
	save_int(code + codepos - 4, i + 1)
	emit(i + 1, token)
	emit(1, "\x58")

	return 1
