/*
for type-name indentifier in range (int-literal):
	{ statement }

for int i in range(0, 10):
*/
int for_statement():
	int p1
	int p2
	if (accept("for") == 0):
		return 0

	int type = variable_declaration()

	expect("in")
	expect("range")

	# if (expression):
	p1 = codepos
	promote(expression())
	emit(8, "\x85\xc0\x0f\x84....") /* test %eax,%eax ; je ... */
	p2 = codepos

	statement() /* will handle ':' scoping */

	 /* increment */

	emit(5, "\xe9....") /* jmp ... */
	save_int(code + codepos - 4, p1 - codepos)
	save_int(code + p2 - 4, codepos - p2)

	return 1

