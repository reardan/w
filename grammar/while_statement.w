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
	emit(8, "\x85\xc0\x0f\x84....") /* test %eax,%eax ; je ... */
	p2 = codepos
	expect(")")

	statement()

	# loop
	emit(5, "\xe9....") /* jmp ... */

	# backtrace: save jmp out, loop jmp addresses
	save_int(code + codepos - 4, p1 - codepos)
	save_int(code + p2 - 4, codepos - p2)

	return 1

