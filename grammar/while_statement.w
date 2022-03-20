void statement();
# while ( expression ) statement
# no ':' required ??
int while_statement():
	int p1
	int p2
	if (accept("while") == 0):
		return 0

	# if not expression: jmp after statement block
	expect("(")
	p1 = codepos
	promote(expression())
	jmp_zero_int32(1337008)
	p2 = codepos
	expect(")")

	statement()

	# loop
	jmp_int32(1337009)

	# backtrace: save jmp out, loop jmp addresses
	save_int32(code + codepos - 4, p1 - codepos)
	save_int32(code + p2 - 4, codepos - p2)

	return 1

