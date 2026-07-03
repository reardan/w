# Set whenever an expression performs an assignment. Only the REPL reads
# it (to suppress echoing "x = 5"); it clears the flag before each entry.
int expression_is_assignment


# Store eax through the address in ebx, sized by the left-hand side's type.
void assign_store(int type):
	int lhs_size = word_size
	if ((type_get_pointer_level(type) == 0) & (type != 3) & (type != 4)):
		int declared_size = type_get_size(type)
		if (declared_size > 0):
			lhs_size = declared_size
	if (lhs_size == 1):
		store_ebx_int8()
	else if (lhs_size == 2):
		store_ebx_int16()
	else if (lhs_size == 4):
		store_ebx_int32()
	else:
		store_ebx_word()


/*
 * expression:
 *         logical-or-expr
 *         logical-or-expr = expression
 */
int expression():
	int type = logical_or_expr()
	if (accept("=")):
		expression_is_assignment = 1
		push_eax()
		stack_pos = stack_pos + 1
		int type2 = expression()
		if (verbosity >= 1):
			print2("expression() type: ")
			type_print(type)
			print_int("expression() type: ", type)
			print_int("expression() type2: ", type2)
		
		type2 = promote(type2)
		coerce(type, type2)
		pop_ebx()

		# Warn when the two sides carry conflicting types; constants (3) and
		# functions (4) act as wildcards inside types_compatible().
		if (types_compatible(type, type2) == 0):
			warn_type_mismatch("assignment", type, type2)

		# The store width comes from the left-hand side's type
		assign_store(type)

		stack_pos = stack_pos - 1

		type = 3  # assignment yields the stored value

	return type
