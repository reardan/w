/*
struct type:
	char* name
	int num_fields
	char* field1
	int type1
	...
	...
	x 100 total for 100 * 8 = 800 bytes
*/
import list


int type_size():
	return 8 + 8 * 100


int type_push(int name):
	int new_type = malloc(type_size())
	save_int(new_type, name) /* name */
	save_int(new_type + 4, 0) /* num_fields */
	return push(new_type)


int type_lookup(char* name):
	int i = 0
	while (i < length):
		int type = get(i)
		if (strcmp(name, *type) == 0):
			return i
		i = i + 1
	return 0-1


int type_add_arg(int type_index, char* field, int field_type):
	int t = get(type_index)
	int num_fields = load_int(t + 4)
	int max_fields = 100
	assert1(num_fields < max_fields)
	if (verbosity > 0):
		print_int("num_fields: ", num_fields)
		print2("adding field: ")
		print2(field)
		print2("(")
		print2(itoa(field_type))
		println2(")")
	save_int(t + 8 + 8 * num_fields, field)
	save_int(t + 12 + 8 * num_fields, field_type)
	save_int(t + 4, num_fields + 1)


int type_get_arg(int type_index, char* field):
	if (verbosity > 0):
		print2("type_get_arg(")
		print2(itoa(type_index))
		print2(", '")
		print2(field)
		println2("')")
	int t = get(type_index)
	int num_fields = load_int(t + 4)
	if (verbosity > 0):
		print_int("num_fields: ", num_fields)
	int i = 0
	while (i < num_fields):
		int f = load_int(t + 8 + 8 * i)
		if (verbosity > 0):
			print2(itoa(i))
			print2(": ")
			print2(field)
			print2(" ?= ")
			print2(f)
			println2("")
		if (strcmp(field, f) == 0):
			return i
		i = i + 1
	return 0-1


void type_print(int type_index):
	print_int("type_print: ", type_index)
	int t = get(type_index)
	print2(*t)
	int i = 0
	int num_fields = load_int(t + 4)
	if (num_fields == 0):
		print2(": ")
		return
	print2("(")
	while (i < num_fields):
		int field_name = load_int(t + 8 + 8 * i)
		int field_type = load_int(t + 12 + 8 * i)
		int field_type_name = get(field_type)

		if (i > 0):
			print2(", ")

		print2(*field_type_name)
		print2(" ")
		print2(field_name)

		i = i + 1

	println2(")")


void type_print_all():
	println2("all types:")
	int i = 0
	while (i < length):
		int type = get(i)
		print_error(itoa(i))
		print_error(": ")
		print_error(*type)
		print_error("\x0a")
		# print_int("len=", strlen(*type))
		i = i + 1


void push_basic_types():
	die() /* reset array */
	# type_push("")
	type_push("void")
	type_push("int")
	type_push("char")

