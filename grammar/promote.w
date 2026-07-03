char *last_identifier


# Print a type's name followed by its pointer stars, e.g. "char**"
void print_error_type(int type_index):
	print_error(type_get_name(type_index))
	for int i in range(type_get_pointer_level(type_index)):
		print_error("*")


# Warn that 'got' does not convert to 'want'; context names the construct
# (assignment, initialization, return, ...)
void warn_type_mismatch(char* context, int want, int got):
	print_error("warning: ")
	print_error(context)
	print_error(" type mismatch: expected '")
	print_error_type(want)
	print_error("', got '")
	print_error_type(got)
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
