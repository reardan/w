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


# Only globals and externs live in a segment address space: 'what' (a
# local variable, a parameter, a field) may point into one but not be
# in one itself.
void seg_storage_check(int type, char* what):
	if (type_seg_prefix(type) == 0): return
	diag_part(what)
	error(c" cannot live in a segment address space; declare a __seg_gs/__seg_fs global or use a pointer")


# The segment address-space qualifier ahead ('__seg_gs T', '__seg_fs
# T', compiler/type_table.w's segment records): its record kind, or 0.
# A type or symbol spelled the same keeps its meaning.
int seg_qualifier_ahead():
	int kind = 0
	if (peek(c"__seg_gs")): kind = type_kind_seg_gs
	if (peek(c"__seg_fs")): kind = type_kind_seg_fs
	if (kind == 0): return 0
	if ((type_lookup(token) >= 0) || (sym_lookup(token) >= 0)): return 0
	return kind


void seg_buffer_error():
	error(c"a segment address space holds scalars, pointers and structs, not W arrays, slices, strings or containers")


# '__seg_gs T' / '__seg_gs(T)' after the qualifier token: the segment
# record over the base type (the parenthesized form takes a whole type,
# pointers included: '__seg_gs(task*)' is a task* object in the gs
# space). Then type_name's stars build pointers over that record.
int seg_qualified_type(int kind):
	if (target_isa != 0):
		error(c"segment address spaces (__seg_gs, __seg_fs) need the x86 or x64 target")
	get_token()
	int target = 0
	if (accept(c"(")):
		target = type_name()
		expect(c")")
	else:
		int is_const = accept(c"const")
		target = type_lookup(token)
		if (target < 0):
			type_suggest_names(token)
			error3(c"unknown type name: '", token, c"'")
		get_token()
		if (is_const): target = type_push_const(target)
	if (type_is_buffer(type_unqualified(target)) || (type_get_kind(target) == type_kind_map) || (type_get_kind(target) == type_kind_set) || (type_get_kind(target) == type_kind_list)):
		seg_buffer_error()
	pointer_indirection = 0
	return type_get_seg(target, kind)


# Contextual checked-pointer qualifiers preserve ordinary identifiers with
# these spellings. A qualifier is recognized only before a known type.
int safe_qualifier_ahead():
	int kind = 0
	if (peek(c"own")): kind = 1
	if (peek(c"optown")): kind = 9
	if (peek(c"ref")): kind = 2
	if (peek(c"refmut")): kind = 3
	if (peek(c"optref")): kind = 6
	if (peek(c"optrefmut")): kind = 7
	if (kind == 0): return 0
	if ((type_lookup(token) >= 0) || (sym_lookup(token) >= 0)): return 0
	char* save = generic_reparse_save()
	get_token()
	int is_type = peek(c"[") || peek(c"const") || (type_lookup(token) >= 0) || (generic_subst_lookup(token) >= 0)
	# A generic struct application: 'own WSafeMutex[int]*'.
	if ((is_type == 0) && (nextc == '[') && (generic_def_lookup(token, 1) >= 0)): is_type = 1
	getchar_seek(file, load_ptr(save + 7 * __word_size__))
	generic_reparse_restore(save)
	if (is_type): return kind
	return 0


int type_name():
	int type = 0
	int is_const = 0
	int is_gpu = 0
	int safe_kind = safe_qualifier_ahead()
	char* lifetime = 0
	if (safe_kind):
		get_token()
		if (accept(c"[")):
			if (is_ident_start_byte(token[0]) == 0): error(c"lifetime label must be an identifier")
			lifetime = strclone(token)
			get_token()
			while (accept(c",")):
				if (is_ident_start_byte(token[0]) == 0): error(c"lifetime label must be an identifier")
				char* prefix = strjoin(lifetime, c",")
				free(lifetime)
				lifetime = strjoin(prefix, token)
				free(prefix)
				get_token()
			expect(c"]")
	pointer_indirection = 0
	if (accept(c"const")): is_const = 1
	int seg_kind = seg_qualifier_ahead()
	if (seg_kind):
		type = seg_qualified_type(seg_kind)
		if (is_const): type = type_get_seg(type_push_const(type_strip_seg(type)), seg_kind)
		is_const = 0
	else if (gpu_qualifier_ahead()):
		get_token()
		is_gpu = 1
		if (accept(c"const")): is_const = 1
	if (freestanding_mode && (peek(c"map") | peek(c"set") | peek(c"list")) && (nextc == '[')):
		error3(c"'", token, c"' types need the W container runtime, which --freestanding excludes")
	if (seg_kind): pass
	else if (peek(c"map") & (nextc == '[')):
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
	if (peek(c"*")): type = type_pointer_base(type)
	char* base_name = type_get_name(type)
	while (accept(c"*")):
		pointer_indirection = pointer_indirection + 1
		int next_level = type_get_pointer_level(type) + 1
		int pointer_type = type_lookup_pointer(base_name, next_level)
		if (pointer_type < 0): pointer_type = type_push_pointer(base_name, word_size, next_level)
		type = pointer_type

	type = type_name_array_suffix(type)
	if (seg_kind && type_is_buffer(type)): seg_buffer_error()
	if (safe_kind):
		if (type_safe_entrypoint == 0): error(c"checked pointers are not supported by in-process sessions")
		if (ast_retain_mode == 0): error(c"checked pointers require the retained frontend")
		if (type_is_slice(type)):
			if ((safe_kind != 2) && (safe_kind != 3)): error(c"checked slices require ref or refmut")
			int element = type_get_element_type(type)
			if ((element < 0) || (type_get_size(element) <= 0)):
				error(c"checked slices require a sized element")
			type = type_get_safe_slice(element, lifetime, safe_kind)
		else if ((type_get_pointer_level(type) == 0) && (type_num_args(type) > 0) && (type_is_array(type) == 0)):
			if ((safe_kind != 2) && (safe_kind != 3)): error(c"borrowed structs require ref or refmut")
			if (type_safe_kind(type)): error(c"borrowed struct qualifier requires a plain struct template")
			type = type_get_safe_record_kind(type, lifetime, safe_kind)
		else:
			if ((type_get_pointer_level(type) != 1) || type_is_array(type)):
				error(c"checked pointers require a single pointer: own T*, ref T*, or refmut T*")
			if (is_gpu || type_is_gpu_pointer(type)): error(c"checked GPU pointers are not supported")
			int element = type_lookup_previous_pointer(type)
			if ((element < 0) || (type_get_size(element) <= 0)):
				error(c"checked pointers require a sized pointee")
			type = type_get_safe_lifetime(type, safe_kind, lifetime)
		if (lifetime != 0): free(lifetime)

	return type
