

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

	mov_eax_int(0) /* make sure we start at zero, change this if needed later once "range(start, end, add)" is implemented */
	int type = variable_declaration()
	asserts("type not found in for_statement loop variable", type >= 0)
	int for_var = stack_pos

	expect("in")
	expect("range")

	# if (expression):
	p1 = codepos
	
	emit(7, "\x8d\x84\x24....") /* lea eax,[esp+0x12345678] */
	save_int(code + codepos - 4, ((stack_pos-for_var) * 4))

	promote(relational_less_than(type))
	# promote(expression())
	emit(8, "\x85\xc0\x0f\x84....") /* test %eax,%eax ; je ... */
	p2 = codepos

	statement() /* will handle ':' scoping + child scope statements */

	/* increment */
	/* inc [for_var] == inc [esp + ((stack_pos-for_var) * 4)] */
	emit(7, "\xff\x84\x24....") /* inc dword[esp+0x12345678] */
	save_int(code + codepos - 4, ((stack_pos-for_var) * 4))

	/* jmp back to condition */
	emit(5, "\xe9....")
	save_int(code + codepos - 4, p1 - codepos)

	/* save jmp to here if condition failed */
	save_int(code + p2 - 4, codepos - p2)

	return 1

