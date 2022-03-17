

int generate_relational_code(int type, char* opcode):
	binary1(type)
	/* pop %ebx ; cmp %eax,%ebx ; setl %al ; movzbl %al,%eax */
	return binary2(shift_expr(), 9, compare_opcode(opcode))


/*
 * relational-expr:
 *         shift-expr
 *         relational-expr <= shift-expr
 *         relational-expr < shift-expr
 *         relational-expr >= shift-expr
 *         relational-expr > shift-expr
 */
int relational_expr():
	int type = shift_expr()
	while (1):
		if(accept("<=")):
			return generate_relational_code(type, "\x9e")

		else if(accept("<")):
			return generate_relational_code(type, "\x9c")

		else if(accept(">=")):
			return generate_relational_code(type, "\x9d")

		else if(accept(">")):
			return generate_relational_code(type, "\x9f")
	
		else:
			return type
