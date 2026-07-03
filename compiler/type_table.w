/*
struct type:
	char* name
	int num_fields
	int total_size
	int pointer_level
	field[100]
		char* field1
		int type1
	...
	...
	x 100 total for 100 * 8 = 800 bytes

	should we add total_size + field_size??
*/
import structures.list


# Float type indices, set by push_basic_types(). The two "value"
# pseudo-types follow the constant(3)/function(4) convention: eax already
# holds the value (raw IEEE-754 bits), not an address. Their names contain
# a space so no source token can ever look them up.
int float32_type
int float64_type
int float16_type
int float_type
int float32_value_type
int float64_value_type


int type_size():
	return 16 + 8 * 100


int type_push_pointer(char* name, int size, int pointer_level):
	int new_type = malloc(type_size())
	save_int(new_type, name) /* name */
	save_int(new_type + 4, 0) /* num_fields */
	save_int(new_type + 8, size) /* size */
	save_int(new_type + 12, pointer_level) /* pointer level */
	return push(new_type)


int type_push_size(char* name, int size):
	int new_type = malloc(type_size())
	save_int(new_type, name) /* name */
	save_int(new_type + 4, 0) /* num_fields */
	save_int(new_type + 8, size) /* size */
	save_int(new_type + 12, 0) /* pointer level */
	return push(new_type)


int type_push(char* name):
	return type_push_size(name, 4)


int type_lookup(char* name):
	int i = 0
	while (i < length):
		int type = get(i)
		# load_int, not *type: the name pointer occupies 4 bytes, so a full
		# word load on x64 would drag in the neighboring num_fields field
		if (strcmp(name, load_int(type)) == 0):
			return i
		i = i + 1
	return -1


char* type_get_name(int type_index):
	int t = get(type_index)
	return load_int(t)


int type_num_args(int type_index):
	int t = get(type_index)
	return load_int(t + 4)


int type_get_size(int type_index):
	int t = get(type_index)
	return load_int(t + 8)


int type_get_pointer_level(int type_index):
	int t = get(type_index)
	return load_int(t + 12)


int type_lookup_pointer(char* name, int pointer_level):
	int i = 0
	while (i < length):
		int t = get(i)
		if (verbosity >= 1):
			print_hex("type_lookup_pointer t: ", t)
		if ((strcmp(name, load_int(t)) == 0) & (pointer_level==load_int(t + 12))):
			return i
		i = i + 1
	return -1


# Return 1 when a value of type 'got' can be stored where 'want' is expected.
# "constant" (3) and "function" (4) results carry no type information, so
# they are compatible with everything. Plain "int" (1) doubles as the
# untyped machine word in a language without casts (addresses, malloc
# blocks), so it also converts both ways. Scalars convert between widths
# silently; pointers must agree on depth and base type, except that void*
# converts to and from any pointer. Distinct struct types never convert.
int types_compatible(int want, int got):
	if ((want == 3) | (want == 4) | (want == 1)):
		return 1
	if ((got == 3) | (got == 4) | (got == 1)):
		return 1
	if (want == got):
		return 1
	if (type_get_pointer_level(want) != type_get_pointer_level(got)):
		return 0
	if (type_get_pointer_level(want) == 0):
		# Struct vs scalar or two different structs
		if ((type_num_args(want) > 0) | (type_num_args(got) > 0)):
			return 0
		return 1
	if (strcmp(type_get_name(want), "void") == 0):
		return 1
	if (strcmp(type_get_name(got), "void") == 0):
		return 1
	return strcmp(type_get_name(want), type_get_name(got)) == 0


# Float kind of an expression type, as a VALUE after promote(): 0 = not
# float, 1 = float32 bits in eax, 2 = float64 bits in rax. float16 counts
# as kind 1 because its load path widens to float32. Pointer types have
# their own indices, so float* correctly reads as kind 0.
int type_float_kind(int t):
	if ((t == float32_type) | (t == float_type) |
			(t == float16_type) | (t == float32_value_type)):
		return 1
	if ((t == float64_type) | (t == float64_value_type)):
		return 2
	return 0


# Combined operating kind for a binary operator's two operand types:
# any float64 side means float64, else any float32 side means float32.
int binary_float_kind(int left_type, int right_type):
	int lk = type_float_kind(left_type)
	int rk = type_float_kind(right_type)
	if (lk > rk):
		return lk
	return rk


int type_lookup_next_pointer(int type_index):
	return type_lookup_pointer(type_get_name(type_index), type_get_pointer_level(type_index) + 1)


int type_lookup_previous_pointer(int type_index):
	return type_lookup_pointer(type_get_name(type_index), type_get_pointer_level(type_index) - 1)


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
	save_int(t + 16 + 8 * num_fields, field)
	save_int(t + 20 + 8 * num_fields, field_type)
	save_int(t + 4, num_fields + 1)
	# Update total size
	save_int(t + 8, load_int(t + 8) + type_get_size(field_type))


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
		int f = load_int(t + 16 + 8 * i)
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
	return -1


# from type_index, return the offset of the field
int type_get_field_offset(int type_index, char* field):
	int t = get(type_index)
	int num_fields = load_int(t + 4)
	int offset = 0
	int i = 0
	while (i < num_fields):
		int f = load_int(t + 16 + 8 * i)
		if (strcmp(field, f) == 0):
			return offset
		int field_type = load_int(t + 20 + 8 * i)
		int field_size = type_get_size(field_type)
		offset = offset + field_size
		i = i + 1
	return -1


# Field type by 0-based field index
int type_get_field_type_at(int type_index, int i):
	int t = get(type_index)
	return load_int(t + 20 + 8 * i)


# Byte offset of the field at 0-based index i
int type_get_field_offset_at(int type_index, int i):
	int t = get(type_index)
	int offset = 0
	int j = 0
	while (j < i):
		offset = offset + type_get_size(load_int(t + 20 + 8 * j))
		j = j + 1
	return offset


# return type.field.type
int type_get_field_type(int type_index, char* field):
	int t = get(type_index)
	int num_fields = load_int(t + 4)
	int i = 0
	while (i < num_fields):
		int f = load_int(t + 16 + 8 * i)
		int field_type = load_int(t + 20 + 8 * i)
		if (strcmp(field, f) == 0):
			return field_type
		i = i + 1
	return -1


void type_print(int type_index):
	# print_int("type_print: ", type_index)
	int t = get(type_index)
	int i = 0
	int num_fields = load_int(t + 4)
	print2((itoa(type_index)))
	print2(":")
	if (num_fields > 0):
		print2("struct ")
		print2(load_int(t))
		print2(": ")
	else:
		print2(load_int(t))
	# print_int("num_fields: ", num_fields)
	if (num_fields <= 0):
		println2("")
		return;
	print2("(")
	while (i < num_fields):
		int field_name = load_int(t + 16 + 8 * i)
		int field_type = load_int(t + 20 + 8 * i)
		int field_type_name = get(field_type)

		if (i > 0):
			print2("; ")

		print2(load_int(field_type_name))
		print2(" ")
		print2(field_name)

		i = i + 1

	println2("")


void type_print_all():
	println2("all types:")
	int i = 0
	while (i < length):
		int type = get(i)
		print_error(itoa(i))
		print_error(": ")
		print_error(load_int(type))
		for int j in range(type_get_pointer_level(i)):
			print_error("*")
		print_error("\x0a")
		# print_int("len=", strlen(*type))
		i = i + 1


# Sizes use the global target word_size: 'int', 'uint' and 'pointer' are
# word-sized (8 bytes when compiling for x64) while the explicit-width
# types (int32, int16, ...) keep their fixed sizes on every target.
void push_basic_types():
	# Callers that never pick a target (unit tests) default to 32-bit
	if (word_size == 0):
		word_size = 4
		word_size_log2 = 2

	die() /* reset array */
	type_push_size("void", 0)
	type_push_size("int", word_size)
	type_push_size("char", 1)
	type_push_size("constant", 0)
	type_push_size("function", 0)

	# newer types, use these for now until void/int/char are fixed:
	type_push_size("byte", 1)
	type_push_size("int16", 2)
	type_push_size("int32", 4)
	type_push_size("pointer", word_size)
	type_push_size("int8", 1)

	type_push_size("uint", word_size)
	type_push_size("uint32", 4)
	type_push_size("uint16", 2)
	type_push_size("uint8", 1)

	# IEEE-754 floating point. 'float' is an alias of float32 by kind (see
	# type_float_kind); float16 is storage-only (all math in float32).
	float32_type = type_push_size("float32", 4)
	float64_type = type_push_size("float64", 8)
	float16_type = type_push_size("float16", 2)
	float_type = type_push_size("float", 4)
	float32_value_type = type_push_size("float32 value", 0)
	float64_value_type = type_push_size("float64 value", 0)

	# Common pointer types; type_name() creates any others on demand
	type_push_pointer("int", word_size, 1)
	type_push_pointer("int", word_size, 2)
	type_push_pointer("char", word_size, 1)
	type_push_pointer("char", word_size, 2)
	type_push_pointer("byte", word_size, 1)
	type_push_pointer("byte", word_size, 2)
	type_push_pointer("void", word_size, 1)
	type_push_pointer("void", word_size, 2)
	type_push_pointer("int32", word_size, 1)
	type_push_pointer("uint", word_size, 1)
	type_push_pointer("function", word_size, 1)
	type_push_pointer("float", word_size, 1)
	type_push_pointer("float32", word_size, 1)
