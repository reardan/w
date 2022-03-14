

/*
for type-name indentifier in range (int-literal):
	{ statement }

Check if one, two, or three arguments are provided
If one argument: 0 = start, first = max = expression()
If two arguments: first = start = expression(); ","; second = max = expression()
If three arguments: ^^^; ","; third = counter = expression()
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

	# Get first argument, store in for_var
	# Check for "," second argument
	# Check for "," third argument

	p1 = codepos

	lea_eax_esp_plus((stack_pos - for_var) * 4)
	# if (cur < max):
	# promote(relational_less_than(type))
	binary1(type)
	/* pop %ebx ; cmp %eax,%ebx ; setl %al ; movzbl %al,%eax */
	promote(binary2(shift_expr(), 9, "\x5b\x39\xc3\x0f\x9c\xc0\x0f\xb6\xc0"))

	emit(8, "\x85\xc0\x0f\x84....") /* test %eax,%eax ; je ... */
	p2 = codepos

	/* ':' scoping + child scope statements */
	statement()

	/* increment */
	/* inc [for_var] == inc [esp + ((stack_pos-for_var) * 4)] */
	emit(7, "\xff\x84\x24....") /* inc dword[esp+0x12345678] */
	save_int(code + codepos - 4, ((stack_pos - for_var) * 4))

	/* jmp back to condition */
	emit(5, "\xe9....")
	save_int(code + codepos - 4, p1 - codepos)

	/* save jmp to here if condition failed */
	save_int(code + p2 - 4, codepos - p2)

	return 1

