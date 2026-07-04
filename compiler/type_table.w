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
int bool_type
int int64_type
int uint64_type
int type_kind_alias
int type_kind_function
int type_kind_union
int type_kind_enum
int type_kind_const
int string_type
int string_value_type


char* type_get_name(int type_index);
int type_get_size(int type_index);
int type_get_pointer_level(int type_index);
int type_lookup_previous_pointer(int type_index);
int type_canonical(int type_index);
int type_unqualified(int type_index);
int type_get_kind(int type_index);
void type_set_kind(int type_index, int kind);
int type_get_element_type(int type_index);
int type_get_array_length(int type_index);
int type_num_args(int type_index);
int type_get_field_type_at(int type_index, int i);


int type_size():
	return 16 + 8 * 100 + 56


int type_push_pointer(char* name, int size, int pointer_level):
	int new_type = malloc(type_size())
	save_int(new_type, name) /* name */
	save_int(new_type + 4, 0) /* num_fields */
	save_int(new_type + 8, size) /* size */
	save_int(new_type + 12, pointer_level) /* pointer level */
	save_int(new_type + 816, -1) /* alias target */
	save_int(new_type + 820, 0) /* reserved kind/flags */
	save_int(new_type + 824, -1) /* function return type */
	save_int(new_type + 828, -1) /* function parameter count */
	return push(new_type)


int type_push_size(char* name, int size):
	int new_type = malloc(type_size())
	save_int(new_type, name) /* name */
	save_int(new_type + 4, 0) /* num_fields */
	save_int(new_type + 8, size) /* size */
	save_int(new_type + 12, 0) /* pointer level */
	save_int(new_type + 816, -1) /* alias target */
	save_int(new_type + 820, 0) /* reserved kind/flags */
	save_int(new_type + 824, -1) /* function return type */
	save_int(new_type + 828, -1) /* function parameter count */
	return push(new_type)


int type_kind_array():
	return 6


int type_kind_slice():
	return 7


int type_kind_string():
	return 8


int type_kind_slice_value():
	return 9


int type_kind_map():
	return 10


int type_kind_set():
	return 11


char* type_make_array_name(int element_type, int length):
	char* open = strjoin(type_get_name(element_type), c"[")
	char* n = itoa(length)
	char* with_len = strjoin(open, n)
	char* name = strjoin(with_len, c"]")
	free(open)
	free(n)
	free(with_len)
	return name


char* type_make_slice_name(int element_type):
	return strjoin(type_get_name(element_type), c"[]")


char* type_make_map_name(int key_type, int value_type):
	char* open = strjoin(c"map[", type_get_name(key_type))
	char* comma = strjoin(open, c", ")
	char* value = strjoin(comma, type_get_name(value_type))
	char* name = strjoin(value, c"]")
	free(open)
	free(comma)
	free(value)
	return name


char* type_make_set_name(int key_type):
	char* open = strjoin(c"set[", type_get_name(key_type))
	char* name = strjoin(open, c"]")
	free(open)
	return name


int type_push_array(int element_type, int length):
	int new_type = malloc(type_size())
	save_int(new_type, type_make_array_name(element_type, length))
	save_int(new_type + 4, 0)
	save_int(new_type + 8, (2 * word_size) + (length * type_get_size(element_type)))
	save_int(new_type + 12, 0)
	save_int(new_type + 816, element_type)
	save_int(new_type + 820, type_kind_array())
	save_int(new_type + 824, length)
	save_int(new_type + 828, -1)
	return push(new_type)


int type_push_slice(int element_type):
	int new_type = malloc(type_size())
	save_int(new_type, type_make_slice_name(element_type))
	save_int(new_type + 4, 0)
	save_int(new_type + 8, word_size)
	save_int(new_type + 12, 0)
	save_int(new_type + 816, element_type)
	save_int(new_type + 820, type_kind_slice())
	save_int(new_type + 824, -1)
	save_int(new_type + 828, -1)
	return push(new_type)


int type_push_slice_value(int element_type):
	int new_type = malloc(type_size())
	char* storage_name = type_make_slice_name(element_type)
	char* name = strjoin(storage_name, c" value")
	free(storage_name)
	save_int(new_type, name)
	save_int(new_type + 4, 0)
	save_int(new_type + 8, 0)
	save_int(new_type + 12, 0)
	save_int(new_type + 816, element_type)
	save_int(new_type + 820, type_kind_slice_value())
	save_int(new_type + 824, -1)
	save_int(new_type + 828, -1)
	return push(new_type)


int type_push_map(int key_type, int value_type):
	int new_type = malloc(type_size())
	save_int(new_type, type_make_map_name(key_type, value_type))
	save_int(new_type + 4, 0)
	save_int(new_type + 8, word_size)
	save_int(new_type + 12, 0)
	save_int(new_type + 816, type_canonical(key_type))
	save_int(new_type + 820, type_kind_map())
	save_int(new_type + 824, type_canonical(value_type))
	save_int(new_type + 828, -1)
	return push(new_type)


int type_push_set(int key_type):
	int new_type = malloc(type_size())
	save_int(new_type, type_make_set_name(key_type))
	save_int(new_type + 4, 0)
	save_int(new_type + 8, word_size)
	save_int(new_type + 12, 0)
	save_int(new_type + 816, type_canonical(key_type))
	save_int(new_type + 820, type_kind_set())
	save_int(new_type + 824, -1)
	save_int(new_type + 828, -1)
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


int type_value(int type_index):
	if (type_index < -1):
		return type_index
	return 0 - type_index - 2


int type_is_value(int type_index):
	return type_index < -1


int type_real(int type_index):
	if (type_index < -1):
		return 0 - type_index - 2
	return type_index


int type_get_alias_target(int type_index):
	type_index = type_real(type_index)
	if (type_index < 0):
		return -1
	int t = get(type_index)
	if (load_int(t + 820) != type_kind_alias):
		return -1
	return load_int(t + 816)


int type_canonical(int type_index):
	type_index = type_real(type_index)
	if (type_index < 0):
		return type_index
	int guard = 0
	while ((type_index >= 0) & (type_get_alias_target(type_index) >= 0) & (guard < 100)):
		type_index = type_get_alias_target(type_index)
		guard = guard + 1
	return type_index


int type_get_const_target(int type_index):
	type_index = type_real(type_index)
	if (type_index < 0):
		return -1
	int t = get(type_index)
	if (load_int(t + 820) != type_kind_const):
		return -1
	return load_int(t + 816)


int type_unqualified(int type_index):
	type_index = type_canonical(type_index)
	if (type_index < 0):
		return type_index
	int guard = 0
	while ((type_index >= 0) & (type_get_const_target(type_index) >= 0) & (guard < 100)):
		type_index = type_get_const_target(type_index)
		type_index = type_canonical(type_index)
		if (type_index < 0):
			return type_index
		guard = guard + 1
	return type_index


int type_push_alias(char* name, int target):
	int real_target = type_canonical(target)
	int new_type = malloc(type_size())
	int target_record = get(real_target)
	save_int(new_type, name) /* name */
	save_int(new_type + 4, load_int(target_record + 4)) /* num_fields */
	save_int(new_type + 8, load_int(target_record + 8)) /* size */
	save_int(new_type + 12, load_int(target_record + 12)) /* pointer level */
	int i = 0
	while (i < 100):
		save_int(new_type + 16 + 8 * i, load_int(target_record + 16 + 8 * i))
		save_int(new_type + 20 + 8 * i, load_int(target_record + 20 + 8 * i))
		i = i + 1
	save_int(new_type + 816, real_target) /* alias target */
	save_int(new_type + 820, type_kind_alias)
	save_int(new_type + 824, -1)
	save_int(new_type + 828, -1)
	return push(new_type)


int type_push_const(int target):
	int real_target = type_canonical(target)
	char* name = strjoin(c"const ", type_get_name(real_target))
	int new_type = malloc(type_size())
	int target_record = get(real_target)
	save_int(new_type, name)
	save_int(new_type + 4, load_int(target_record + 4))
	save_int(new_type + 8, load_int(target_record + 8))
	save_int(new_type + 12, load_int(target_record + 12))
	int i = 0
	while (i < 100):
		save_int(new_type + 16 + 8 * i, load_int(target_record + 16 + 8 * i))
		save_int(new_type + 20 + 8 * i, load_int(target_record + 20 + 8 * i))
		i = i + 1
	save_int(new_type + 816, real_target)
	save_int(new_type + 820, type_kind_const)
	save_int(new_type + 824, -1)
	save_int(new_type + 828, -1)
	return push(new_type)


int type_get_kind(int type_index):
	type_index = type_canonical(type_index)
	if (type_index < 0):
		return 0
	int t = get(type_index)
	return load_int(t + 820)


void type_set_kind(int type_index, int kind):
	type_index = type_real(type_index)
	int t = get(type_index)
	save_int(t + 820, kind)


int type_get_element_type(int type_index):
	type_index = type_canonical(type_index)
	if (type_index < 0):
		return -1
	int t = get(type_index)
	return load_int(t + 816)


int type_get_array_length(int type_index):
	type_index = type_canonical(type_index)
	int t = get(type_index)
	return load_int(t + 824)


int type_is_array(int type_index):
	return type_get_kind(type_index) == type_kind_array()


int type_is_slice(int type_index):
	int kind = type_get_kind(type_index)
	return (kind == type_kind_slice()) | (kind == type_kind_slice_value())


int type_is_string(int type_index):
	return type_get_kind(type_index) == type_kind_string()


int type_is_char_pointer(int type_index):
	type_index = type_canonical(type_index)
	if (type_index < 0):
		return 0
	if (type_get_pointer_level(type_index) != 1):
		return 0
	return strcmp(type_get_name(type_index), c"char") == 0


int type_is_map(int type_index):
	return type_get_kind(type_index) == type_kind_map()


int type_is_set(int type_index):
	return type_get_kind(type_index) == type_kind_set()


int type_is_buffer(int type_index):
	return type_is_array(type_index) | type_is_slice(type_index) | type_is_string(type_index)


int type_has_array_field(int type_index):
	type_index = type_canonical(type_index)
	if (type_index < 0):
		return 0
	if (type_get_pointer_level(type_index) > 0):
		return 0
	if (type_is_array(type_index)):
		return 1
	int count = type_num_args(type_index)
	int i = 0
	while (i < count):
		if (type_has_array_field(type_get_field_type_at(type_index, i))):
			return 1
		i = i + 1
	return 0


int type_stack_words(int type_index):
	int size = type_get_size(type_index)
	if (size <= word_size):
		return 1
	return (size + word_size - 1) >> word_size_log2


int type_is_function_signature(int type_index):
	type_index = type_canonical(type_index)
	return type_get_kind(type_index) == type_kind_function


int type_function_pointer_signature(int type_index):
	type_index = type_canonical(type_index)
	if (type_get_pointer_level(type_index) <= 0):
		return -1
	int base_type = type_lookup_previous_pointer(type_index)
	if (base_type < 0):
		return -1
	if (type_is_function_signature(base_type)):
		return base_type
	return -1


int type_is_const(int type_index):
	type_index = type_canonical(type_index)
	if (type_get_kind(type_index) == type_kind_const):
		return 1
	return 0


int type_push_function(char* name, int return_type, int param_count, int param_types):
	int new_type = malloc(type_size())
	save_int(new_type, name)
	save_int(new_type + 4, 0)
	save_int(new_type + 8, word_size)
	save_int(new_type + 12, 0)
	save_int(new_type + 816, -1)
	save_int(new_type + 820, type_kind_function)
	save_int(new_type + 824, return_type)
	save_int(new_type + 828, param_count)
	int i = 0
	while (i < 10):
		int param_type = -1
		if (i < param_count):
			param_type = load_int(param_types + (i << 2))
		save_int(new_type + 832 + (i << 2), param_type)
		i = i + 1
	return push(new_type)


int type_function_return(int type_index):
	type_index = type_canonical(type_index)
	int t = get(type_index)
	return load_int(t + 824)


int type_function_param_count(int type_index):
	type_index = type_canonical(type_index)
	int t = get(type_index)
	return load_int(t + 828)


int type_function_param_type(int type_index, int i):
	type_index = type_canonical(type_index)
	if (i >= type_function_param_count(type_index)):
		return -1
	if (i >= 10):
		return -1
	int t = get(type_index)
	return load_int(t + 832 + (i << 2))


int type_lookup_array(int element_type, int array_length):
	element_type = type_canonical(element_type)
	int i = 0
	while (i < length):
		int t = get(i)
		if ((load_int(t + 820) == type_kind_array()) &
				(type_canonical(load_int(t + 816)) == element_type) &
				(load_int(t + 824) == array_length)):
			return i
		i = i + 1
	return -1


int type_lookup_slice(int element_type):
	element_type = type_canonical(element_type)
	int i = 0
	while (i < length):
		int t = get(i)
		if ((load_int(t + 820) == type_kind_slice()) &
				(type_canonical(load_int(t + 816)) == element_type)):
			return i
		i = i + 1
	return -1


int type_lookup_slice_value(int element_type):
	element_type = type_canonical(element_type)
	int i = 0
	while (i < length):
		int t = get(i)
		if ((load_int(t + 820) == type_kind_slice_value()) &
				(type_canonical(load_int(t + 816)) == element_type)):
			return i
		i = i + 1
	return -1


int type_lookup_map(int key_type, int value_type):
	key_type = type_canonical(key_type)
	value_type = type_canonical(value_type)
	int i = 0
	while (i < length):
		int t = get(i)
		if ((load_int(t + 820) == type_kind_map()) &
				(type_canonical(load_int(t + 816)) == key_type) &
				(type_canonical(load_int(t + 824)) == value_type)):
			return i
		i = i + 1
	return -1


int type_lookup_set(int key_type):
	key_type = type_canonical(key_type)
	int i = 0
	while (i < length):
		int t = get(i)
		if ((load_int(t + 820) == type_kind_set()) &
				(type_canonical(load_int(t + 816)) == key_type)):
			return i
		i = i + 1
	return -1


int type_get_slice(int element_type):
	int slice = type_lookup_slice(element_type)
	if (slice < 0):
		slice = type_push_slice(type_canonical(element_type))
	return slice


int type_get_slice_value(int element_type):
	int slice = type_lookup_slice_value(element_type)
	if (slice < 0):
		slice = type_push_slice_value(type_canonical(element_type))
	return slice


int type_get_map(int key_type, int value_type):
	int map_type = type_lookup_map(key_type, value_type)
	if (map_type < 0):
		map_type = type_push_map(type_canonical(key_type), type_canonical(value_type))
	return map_type


int type_get_set(int key_type):
	int set_type = type_lookup_set(key_type)
	if (set_type < 0):
		set_type = type_push_set(type_canonical(key_type))
	return set_type


int type_map_key_type(int type_index):
	type_index = type_canonical(type_index)
	int t = get(type_index)
	return load_int(t + 816)


int type_map_value_type(int type_index):
	type_index = type_canonical(type_index)
	int t = get(type_index)
	return load_int(t + 824)


int type_set_key_type(int type_index):
	type_index = type_canonical(type_index)
	int t = get(type_index)
	return load_int(t + 816)


char* type_get_name(int type_index):
	type_index = type_real(type_index)
	int t = get(type_index)
	return load_int(t)


int type_num_args(int type_index):
	type_index = type_canonical(type_index)
	int t = get(type_index)
	return load_int(t + 4)


int type_get_size(int type_index):
	type_index = type_canonical(type_index)
	int t = get(type_index)
	return load_int(t + 8)


int type_get_pointer_level(int type_index):
	type_index = type_canonical(type_index)
	int t = get(type_index)
	return load_int(t + 12)


int type_lookup_pointer(char* name, int pointer_level):
	int i = 0
	while (i < length):
		int t = get(i)
		if (verbosity >= 1):
			print_hex(c"type_lookup_pointer t: ", t)
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
	want = type_unqualified(want)
	got = type_unqualified(got)
	if ((want == 3) | (want == 4) | (want == 1)):
		return 1
	if (want == got):
		return 1
	if (type_is_string(want) & type_is_string(got)):
		return 1
	if (type_is_string(want) & type_is_char_pointer(got)):
		return 1
	if (type_is_string(want) | type_is_string(got)):
		return 0
	if ((got == 3) | (got == 4) | (got == 1)):
		return 1
	if (type_is_map(want) & type_is_map(got)):
		return (type_unqualified(type_map_key_type(want)) == type_unqualified(type_map_key_type(got))) &
				(type_unqualified(type_map_value_type(want)) == type_unqualified(type_map_value_type(got)))
	if (type_is_set(want) & type_is_set(got)):
		return type_unqualified(type_set_key_type(want)) == type_unqualified(type_set_key_type(got))
	if (type_is_map(want) | type_is_map(got) | type_is_set(want) | type_is_set(got)):
		return 0
	if (type_is_slice(want) & type_is_array(got)):
		return type_unqualified(type_get_element_type(want)) == type_unqualified(type_get_element_type(got))
	if (type_is_slice(want) & type_is_slice(got)):
		return type_unqualified(type_get_element_type(want)) == type_unqualified(type_get_element_type(got))
	if (type_is_array(want) | type_is_array(got) | type_is_slice(want) | type_is_slice(got)):
		return 0
	if (type_get_pointer_level(want) != type_get_pointer_level(got)):
		return 0
	if (type_get_pointer_level(want) == 0):
		# Struct vs scalar or two different structs
		if ((type_num_args(want) > 0) | (type_num_args(got) > 0)):
			return 0
		return 1
	if (strcmp(type_get_name(want), c"void") == 0):
		return 1
	if (strcmp(type_get_name(got), c"void") == 0):
		return 1
	return strcmp(type_get_name(want), type_get_name(got)) == 0


# Float kind of an expression type, as a VALUE after promote(): 0 = not
# float, 1 = float32 bits in eax, 2 = float64 bits in rax. float16 counts
# as kind 1 because its load path widens to float32. Pointer types have
# their own indices, so float* correctly reads as kind 0.
int type_float_kind(int t):
	t = type_canonical(t)
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
	type_index = type_canonical(type_index)
	return type_lookup_pointer(type_get_name(type_index), type_get_pointer_level(type_index) + 1)


int type_get_next_pointer(int type_index):
	int pointer_type = type_lookup_next_pointer(type_index)
	if (pointer_type < 0):
		type_index = type_canonical(type_index)
		pointer_type = type_push_pointer(type_get_name(type_index), word_size, type_get_pointer_level(type_index) + 1)
	return pointer_type


int type_lookup_previous_pointer(int type_index):
	type_index = type_canonical(type_index)
	return type_lookup_pointer(type_get_name(type_index), type_get_pointer_level(type_index) - 1)


int type_add_arg(int type_index, char* field, int field_type):
	type_index = type_canonical(type_index)
	int t = get(type_index)
	int num_fields = load_int(t + 4)
	int max_fields = 100
	assert1(num_fields < max_fields)
	if (verbosity > 0):
		print_int(c"num_fields: ", num_fields)
		print2(c"adding field: ")
		print2(field)
		print2(c"(")
		print2(itoa(field_type))
		println2(c")")
	save_int(t + 16 + 8 * num_fields, field)
	save_int(t + 20 + 8 * num_fields, field_type)
	save_int(t + 4, num_fields + 1)
	# Update total size. Structs sum fields; unions take the largest field.
	int field_size = type_get_size(field_type)
	if (type_get_kind(type_index) == type_kind_union):
		if (field_size > load_int(t + 8)):
			save_int(t + 8, field_size)
	else:
		save_int(t + 8, load_int(t + 8) + field_size)


int type_get_arg(int type_index, char* field):
	type_index = type_canonical(type_index)
	if (verbosity > 0):
		print2(c"type_get_arg(")
		print2(itoa(type_index))
		print2(c", '")
		print2(field)
		println2(c"')")
	int t = get(type_index)
	int num_fields = load_int(t + 4)
	if (verbosity > 0):
		print_int(c"num_fields: ", num_fields)
	int i = 0
	while (i < num_fields):
		int f = load_int(t + 16 + 8 * i)
		if (verbosity > 0):
			print2(itoa(i))
			print2(c": ")
			print2(field)
			print2(c" ?= ")
			print2(str_from_cstr(f))
			println2(c"")
		if (strcmp(field, f) == 0):
			return i
		i = i + 1
	return -1


# from type_index, return the offset of the field
int type_get_field_offset(int type_index, char* field):
	type_index = type_canonical(type_index)
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
		if (type_get_kind(type_index) != type_kind_union):
			offset = offset + field_size
		i = i + 1
	return -1


# Field type by 0-based field index
int type_get_field_type_at(int type_index, int i):
	type_index = type_canonical(type_index)
	int t = get(type_index)
	return load_int(t + 20 + 8 * i)


# Byte offset of the field at 0-based index i
int type_get_field_offset_at(int type_index, int i):
	type_index = type_canonical(type_index)
	int t = get(type_index)
	int offset = 0
	int j = 0
	if (type_get_kind(type_index) == type_kind_union):
		return 0
	while (j < i):
		offset = offset + type_get_size(load_int(t + 20 + 8 * j))
		j = j + 1
	return offset


# return type.field.type
int type_get_field_type(int type_index, char* field):
	type_index = type_canonical(type_index)
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
	type_index = type_real(type_index)
	# print_int("type_print: ", type_index)
	int t = get(type_index)
	int i = 0
	int num_fields = load_int(t + 4)
	print2((itoa(type_index)))
	print2(c":")
	if (num_fields > 0):
		print2(c"struct ")
		print2(str_from_cstr(load_int(t)))
		print2(c": ")
	else:
		print2(str_from_cstr(load_int(t)))
	# print_int("num_fields: ", num_fields)
	if (num_fields <= 0):
		println2(c"")
		return;
	print2(c"(")
	while (i < num_fields):
		int field_name = load_int(t + 16 + 8 * i)
		int field_type = load_int(t + 20 + 8 * i)
		int field_type_name = get(field_type)

		if (i > 0):
			print2(c"; ")

		print2(str_from_cstr(load_int(field_type_name)))
		print2(c" ")
		print2(str_from_cstr(field_name))

		i = i + 1

	println2(c"")


void type_print_all():
	println2(c"all types:")
	int i = 0
	while (i < length):
		int type = get(i)
		print_error(itoa(i))
		print_error(c": ")
		print_error(str_from_cstr(load_int(type)))
		for int j in range(type_get_pointer_level(i)):
			print_error(c"*")
		print_error(c"\x0a")
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
	type_kind_alias = 1
	type_kind_function = 2
	type_kind_union = 3
	type_kind_enum = 4
	type_kind_const = 5
	type_push_size(c"void", 0)
	type_push_size(c"int", word_size)
	type_push_size(c"char", 1)
	type_push_size(c"constant", 0)
	type_push_size(c"function", 0)
	bool_type = type_push_size(c"bool", 1)

	# newer types, use these for now until void/int/char are fixed:
	type_push_size(c"byte", 1)
	type_push_size(c"int16", 2)
	type_push_size(c"int32", 4)
	int64_type = type_push_size(c"int64", 8)
	type_push_size(c"pointer", word_size)
	type_push_size(c"int8", 1)

	type_push_size(c"uint", word_size)
	type_push_size(c"uint32", 4)
	type_push_size(c"uint16", 2)
	type_push_size(c"uint8", 1)
	uint64_type = type_push_size(c"uint64", 8)

	# IEEE-754 floating point. 'float' is an alias of float32 by kind (see
	# type_float_kind); float16 is storage-only (all math in float32).
	float32_type = type_push_size(c"float32", 4)
	float64_type = type_push_size(c"float64", 8)
	float16_type = type_push_size(c"float16", 2)
	float_type = type_push_size(c"float", 4)
	float32_value_type = type_push_size(c"float32 value", 0)
	float64_value_type = type_push_size(c"float64 value", 0)
	string_type = type_push_size(c"string", word_size)
	type_set_kind(string_type, type_kind_string())
	string_value_type = type_push_size(c"string value", 0)
	type_set_kind(string_value_type, type_kind_string())

	# Common pointer types; type_name() creates any others on demand
	type_push_pointer(c"int", word_size, 1)
	type_push_pointer(c"int", word_size, 2)
	type_push_pointer(c"char", word_size, 1)
	type_push_pointer(c"char", word_size, 2)
	type_push_pointer(c"byte", word_size, 1)
	type_push_pointer(c"byte", word_size, 2)
	type_push_pointer(c"void", word_size, 1)
	type_push_pointer(c"void", word_size, 2)
	type_push_pointer(c"int32", word_size, 1)
	type_push_pointer(c"int64", word_size, 1)
	type_push_pointer(c"uint", word_size, 1)
	type_push_pointer(c"uint64", word_size, 1)
	type_push_pointer(c"bool", word_size, 1)
	type_push_pointer(c"function", word_size, 1)
	type_push_pointer(c"float", word_size, 1)
	type_push_pointer(c"float32", word_size, 1)
