char *last_identifier


void warn_bad_promotion(int want, int got):
	if (want != got):
		print2("promotion type size for ")
		print2(last_identifier)
		print2(": wanted '")
		print2(itoa(want))
		print2("' got ")
		print2(itoa(got))
		warning("'")
	

/*
Convert the lvalue address in eax into an rvalue, sized by its type.

Expression types follow one convention: a real type index means eax holds
the ADDRESS of a value of that type; "constant" (3) and "function" (4)
mean eax already holds the value. Structs are used by address, so they
are never loaded either.
*/
int promote(int type):
	if (verbosity >= 1):
		print2(itoa(line_number))
		print2(": promote(")
		print2(itoa(type))
		print2("=")
		print2(type_get_name(type))
		print2(", '")
		print2(last_identifier)
		println2("')")

	if (type == 3): /* constant: already a value */
		return type
	if (type == 4): /* function: its address is its value */
		return type
	if (type_num_args(type) > 0): /* struct: keep the address */
		return type
	if (type_get_pointer_level(type) > 0):
		promote_eax()
		return type

	int size = type_get_size(type)
	if (size == 1):
		promote_int8_eax()
	else if (size == 2):
		promote_int16_eax()
	else if (size >= 4):
		promote_eax()
	/* size 0 (void): nothing to load */
	return type
