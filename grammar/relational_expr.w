

int generate_relational_code(int type, int setcc_opcode):
	binary1(type)
	type = binary2_finish_pop(shift_expr())
	alu_cmp_set(setcc_opcode)
	return type


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
			type = generate_relational_code(type, 0x9e)

		else if(accept("<")):
			type = generate_relational_code(type, 0x9c)

		else if(accept(">=")):
			type = generate_relational_code(type, 0x9d)

		else if(accept(">")):
			type = generate_relational_code(type, 0x9f)
	
		else:
			return type
