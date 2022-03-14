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
		emit(3, "\x0f\xbe\x00") /* movsbl eax, [eax] */
	else if (type == 2): /* old int / char* / everything */
		emit(2, "\x8b\x00") /* mov eax, [eax] */
	else if (type == 3) {} /* void: no op */
	else if (type == 5): /* int32 */
		emit(2, "\x8b\x00") /* mov eax, [eax] */
	if (type_pointer_level > 0):
		emit(2, "\x8b\x00") /* mov eax, [eax] */
		# Lookup pointer_level - 1 and return
		type = type_lookup_pointer(type, type_pointer_level - 1)

	return type
