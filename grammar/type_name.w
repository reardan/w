# Import-alias support lives in grammar/import_statement.w, which is
# compiled after this file; see the definitions there.
int import_alias_lookup(char* name);
int import_alias_type_member(int alias_index);


# Built-in list[T] elements are stored by value in byte-addressed slots.
# Reject element types the runtime cannot copy: void, and fixed arrays
# (their descriptors point into the enclosing object, so a byte copy
# would corrupt them). Scalars must fit in a word; structs may span
# several words but must not contain fixed-array fields.
void list_element_type_check(int element_type):
	int checked = type_unqualified(element_type)
	if (type_is_array(checked)): error(c"list element type cannot be a fixed-size array")
	if (type_get_size(checked) <= 0): error(c"list element type must have a size")
	if (type_has_array_field(checked)):
		error(c"list element type cannot contain fixed-size array fields")
	if (type_num_args(checked) == 0):
		if (type_stack_words(checked) != 1): error(c"list element type must be word-sized")


# Map values share the list element storage rules, except that scalar
# values may be any word-or-narrower type (stored in a word slot).
void map_value_type_check(int value_type):
	int checked = type_unqualified(value_type)
	if (type_is_array(checked)): error(c"map value type cannot be a fixed-size array")
	if (type_has_array_field(checked)):
		error(c"map value type cannot contain fixed-size array fields")
	if (type_num_args(checked) == 0):
		if (type_stack_words(checked) != 1): error(c"map value type must be word-sized")


# The '[...]' suffix of a type: '[]' wraps the type in a slice, '[n]'
# in a fixed array. Shared with grammar/generic.w, whose declaration
# scan re-builds a type after looking ahead past it.
int type_name_array_suffix(int type):
	while (accept(c"[")):
		if (accept(c"]")):
			int slice_type = type_lookup_slice(type)
			if (slice_type < 0): slice_type = type_push_slice(type)
			type = slice_type
		else:
			int array_length = atoi(token)
			if (array_length <= 0): error(c"array length must be positive")
			get_token()
			expect(c"]")
			int array_type = type_lookup_array(type, array_length)
			if (array_type < 0): array_type = type_push_array(type, array_length)
			type = array_type
	return type


# 1 when the current token is the 'gpu' pointer qualifier ('gpu float32*
# p'): 'gpu' directly followed by a type name. 'gpu for' and a user type
# or symbol named 'gpu' keep their meaning. The one-token lookahead uses
# the reparse save/seek/restore trick (grammar/gpu_for.w precedent).
int gpu_qualifier_ahead():
	if (peek(c"gpu") == 0): return 0
	if ((type_lookup(c"gpu") >= 0) || (sym_lookup(c"gpu") >= 0)): return 0
	char* save = generic_reparse_save()
	get_token()
	int is_type = 0
	if (peek(c"const") || (type_lookup(token) >= 0) || (generic_subst_lookup(token) >= 0)):
		is_type = 1
	getchar_seek(file, load_ptr(save + 7 * __word_size__))
	generic_reparse_restore(save)
	return is_type


int type_name():
	int type = 0
	int is_const = 0
	int is_gpu = 0
	pointer_indirection = 0
	if (accept(c"const")): is_const = 1
	if (gpu_qualifier_ahead()):
		get_token()
		is_gpu = 1
		if (accept(c"const")): is_const = 1
	if (peek(c"map") & (nextc == '[')):
		get_token()
		expect(c"[")
		int key_type = type_name()
		expect(c",")
		int value_type = type_name()
		expect(c"]")
		map_value_type_check(value_type)
		type = type_get_map(key_type, value_type)
	else if (peek(c"set") & (nextc == '[')):
		get_token()
		expect(c"[")
		int set_key_type = type_name()
		expect(c"]")
		type = type_get_set(set_key_type)
	else if (peek(c"list") & (nextc == '[')):
		get_token()
		expect(c"[")
		int list_element = type_name()
		expect(c"]")
		list_element_type_check(list_element)
		type = type_get_list(list_element)
	# A bound type parameter of the generic instantiation being compiled
	else if (generic_subst_lookup(token) >= 0):
		type = generic_subst_lookup(token)
		get_token()
	# A generic struct instantiation: 'pair[int]'
	else if ((nextc == '[') & (generic_def_lookup(token, 1) >= 0)):
		type = generic_struct_type()
		# A pointer type argument ('wresult[char*]') leaves its star
		# count behind; reset so the instance's own stars count from 0
		pointer_indirection = 0
	else:
		type = -1
		# Qualified type through an import alias: 'alias.TypeName'. The
		# dot must follow immediately, and the alias shadows any type
		# with the same name in this position (mirroring identifier()).
		if (nextc == '.'):
			int alias_index = import_alias_lookup(token)
			if (alias_index >= 0): type = import_alias_type_member(alias_index)
		if (type < 0):
			type = type_lookup(token)
			if (type < 0):
				type_suggest_names(token)
				error3(c"unknown type name: '", token, c"'")
		int checked_type = type_unqualified(type)
		if ((checked_type == float64_type) && (word_size != 8)):
			error(c"float64 requires the x64 target")
		if (((checked_type == int64_type) || (checked_type == uint64_type)) && (word_size != 8)):
			error(c"int64 requires the x64 target")

		get_token()

	if (is_const): type = type_push_const(type)

	# 'gpu T*': the stars below build pointers over the gpu-object
	# record G(T) (compiler/type_table.w, type_get_gpu), so the element
	# lvalue of the pointer carries the device-memory qualifier.
	if (is_gpu):
		if (type_get_pointer_level(type) > 0):
			error(c"the gpu qualifier applies to the pointee type: write 'gpu T*' with a non-pointer T")
		if (peek(c"*") == 0): error(c"the gpu qualifier requires a pointer type: 'gpu T*'")
		type = type_get_gpu(type)

	# Each '*' wraps the base type in a pointer type, created on demand.
	# The new level stacks on the type's OWN pointer level, not the star
	# count: a substituted type parameter may already be a pointer, so
	# 'T*' with T = char* must build char**, not char* (pointer records
	# store the base type's name, so base_name is stable across levels).
	char* base_name = type_get_name(type)
	while (accept(c"*")):
		pointer_indirection = pointer_indirection + 1
		int next_level = type_get_pointer_level(type) + 1
		int pointer_type = type_lookup_pointer(base_name, next_level)
		if (pointer_type < 0): pointer_type = type_push_pointer(base_name, word_size, next_level)
		type = pointer_type

	type = type_name_array_suffix(type)

	return type
