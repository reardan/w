

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
 *
 * Chains left-associatively, so a < b < c means (a < b) < c.
 */
int relational_expr():
	int type = shift_expr()
	while (1):
		if(accept("<=")):
			type = generate_relational_code(type, "\x9e")

		else if(accept("<")):
			type = generate_relational_code(type, "\x9c")

		else if(accept(">=")):
			type = generate_relational_code(type, "\x9d")

		else if(accept(">")):
			type = generate_relational_code(type, "\x9f")
	
		else:
			return type
