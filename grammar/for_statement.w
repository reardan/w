

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

	lea_eax_esp_plus((stack_pos - for_var) * word_size)
	# if (cur < max):
	promote(generate_relational_code(type, "\x9c"))

	jmp_zero_int32(1337010)
	p2 = codepos

	/* ':' scoping + child scope statements */
	statement()

	/* increment */
	/* inc [for_var] == inc [esp + ((stack_pos-for_var) * 4)] */
	inc_dword_esp_plus((stack_pos - for_var) * word_size)

	/* jmp back to condition */
	jmp_int32(1337011)
	save_int32(code + codepos - 4, p1 - codepos)

	/* save jmp to here if condition failed */
	save_int32(code + p2 - 4, codepos - p2)

	return 1

