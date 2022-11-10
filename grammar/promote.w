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
0 = void
1 = char lval  SWAP
2 = int lval   SWAP (to 5 for now 'int32')
3 = int/ptr/char literal - always a word (dont promote!)
other = type_size
*/
int promote(int type):
	int type_size = type_get_size(type)
	int type_pointer_level = type_get_pointer_level(type)

	if (verbosity >= 1):
		print2(itoa(line_number))
		print2(": promote(")
		print2(itoa(type))
		print2("=")
		print2(type_get_name(type))
		print2(", size=")
		print2(itoa(type_size))
		print2(", pointer_level=")
		print2(itoa(type_pointer_level))
		print2(", '")
		print2(last_identifier)
		println2("')")


	if (type == 1): /* old char: (but is also int type) */
		promote_int8_eax()
	else if (type == 2): /* old int / char* / everything */
		promote_eax()
	else if (type == 3) {} /* void: no op */

	else if (type == 5) {} /* int8 */
		# promote_int8_eax()
	else if (type == 6) {} /* int16 */
		# promote_int16_eax()
	else if (type == 7) {} /* int32 */
		# promote_eax()

	else if (type_pointer_level > 0):
		# promote_int8_eax()
		# Lookup pointer_level - 1 and return
		int new_type = type_lookup_previous_pointer(type)
		if (verbosity >= 1):
			print2(itoa(line_number))
			print2(": type_pointer_level > 0, new_type: ")
			type_print(new_type)

		if (type == 17): /* char pointer */
			print_color("promoting char pointer!\x0a", 33)
			promote_eax()
			return new_type

		if (type == 23): /* int32 pointer */
			print_color("promoting int32 pointer!", 33)
			promote_eax()
			return new_type

		if (type == 25): /* function pointer */
			promote_eax()

	return type
