import lib.testing
import compiler.tokenizer
import codegen

/*
todo: fix this so that it can use self directory
and it changes the directory then backs out
*/
import compiler.type_table


void push_advanced_types():
	# these pointer types are deprecated, use * instead
	type_push(c"void*")
	type_push(c"char**")
	type_push(c"int(int,int)")


void test_type_push():
	push_basic_types()


void test_type_lookup():
	push_basic_types()
	assert_equal(0, type_lookup(c"void"))
	assert_equal(1, type_lookup(c"int"))
	assert_equal(2, type_lookup(c"char"))


void test_extra_types():
	push_basic_types()
	push_advanced_types()
	assert_equal(type_count() - 1, type_lookup(c"int(int,int)"))


void test_add_get_print_2_fields():
	push_basic_types()
	int type_index = type_push(c"point")
	char* field = c"x"
	int int_type = type_lookup(c"int")
	print_int(c"type_index: ", type_index)
	type_add_arg(type_index, field, int_type)

	int arg_index = type_get_arg(type_index, field)
	assert_equal(0, arg_index)

	char* field2 = c"y"
	type_add_arg(type_index, field2, int_type)

	type_print(type_index)

	int arg_index2 = type_get_arg(type_index, field2)
	assert_equal(1, arg_index2)


void test_add_get_50_fields():
	push_basic_types()
	int type_index = type_push(c"massive_struct")
	# Build the field names in a heap buffer: string literals live in the
	# read-execute text segment (W^X, docs/projects/wx_split.md), so
	# writing into one faults.
	char* field = cast(char*, malloc(16))
	strcpy(field, c"field")
	int i = 0
	int count = 50
	while (i < count):
		strcpy(field + 5, itoa(i))
		int int_type = type_lookup(c"int")
		type_add_arg(type_index, strclone(field), int_type)
		i = i + 1
	free(field)

	type_rec* t = type_record(type_index)
	assert_equal(count, t.num_fields)


void test_type_push_size():
	push_basic_types()


void test_array_and_slice_types():
	push_basic_types()
	int int_type = type_lookup(c"int")
	int array_type = type_push_array(int_type, 4)
	int slice_type = type_get_slice(int_type)
	assert1(type_is_array(array_type))
	assert1(type_is_slice(slice_type))
	assert_equal(int_type, type_get_element_type(array_type))
	assert_equal(int_type, type_get_element_type(slice_type))
	assert_equal(4, type_get_array_length(array_type))
	assert1(types_compatible(slice_type, array_type))
	assert1(types_compatible(slice_type, type_get_slice_value(int_type)))


void test_map_and_set_types():
	push_basic_types()
	int int_type = type_lookup(c"int")
	int char_type = type_lookup(c"char")
	int char_ptr_type = type_lookup_pointer(c"char", 1)
	int map_type = type_get_map(char_ptr_type, int_type)
	int same_map = type_get_map(char_ptr_type, int_type)
	int other_map = type_get_map(int_type, int_type)
	int set_type = type_get_set(int_type)
	int same_set = type_get_set(int_type)
	int other_set = type_get_set(char_type)
	assert_equal(map_type, same_map)
	assert1(type_is_map(map_type))
	assert_equal(char_ptr_type, type_map_key_type(map_type))
	assert_equal(int_type, type_map_value_type(map_type))
	assert_equal(__word_size__, type_get_size(map_type))
	assert1(types_compatible(map_type, same_map))
	assert_equal(0, types_compatible(map_type, other_map))
	assert_equal(set_type, same_set)
	assert1(type_is_set(set_type))
	assert_equal(int_type, type_set_key_type(set_type))
	assert1(types_compatible(set_type, same_set))
	assert_equal(0, types_compatible(set_type, other_set))


# simulating:
#
# struct mixed:
#	int32 a   # [0] offset
#	int16 b   # [4]
#	int32 c   # [6]
# type_get_field_offset("c") == 6
void test_type_get_field_offset():
	push_basic_types()
	int type_index = type_push(c"mixed")
	int int_type = type_lookup(c"int")
	int int16_type = type_push_size(c"int16", 2)
	type_add_arg(type_index, c"a", int_type)
	type_get_field_offset(type_index, c"a")
	type_add_arg(type_index, c"b", int16_type)
	type_add_arg(type_index, c"c", int_type)
	type_print(type_index)
	assert_equal(0, type_get_field_offset(type_index, c"a"))
	assert_equal(4, type_get_field_offset(type_index, c"b"))
	assert_equal(6, type_get_field_offset(type_index, c"c"))


void test_type_with_fields_total_size():
	push_basic_types()
	int type_index = type_push_size(c"mixed", 0)
	int int_type = type_lookup(c"int")
	int int16_type = type_push_size(c"int16", 2)
	type_add_arg(type_index, c"a", int16_type)
	type_add_arg(type_index, c"b", int_type)
	type_add_arg(type_index, c"c", int16_type)
	type_add_arg(type_index, c"d", int_type)
	assert_equal(12, type_get_size(type_index))



# Test pointer level
void test_pointer_level():
	push_basic_types()
	int first_pointer = type_lookup_pointer(c"int", 1)
	assert1(first_pointer > 0)
	assert_equal(first_pointer+1, type_lookup_pointer(c"int", 2))
	assert_equal(first_pointer+2, type_lookup_pointer(c"char", 1))
	assert_equal(first_pointer+3, type_lookup_pointer(c"char", 2))


# The former wildcards: 'int' no longer converts to or from pointers and
# 'function' values only convert through a signature match or a cast.
# Only 'constant' (3) stays compatible with everything until typed
# literals land.
void test_types_compatible_strictness():
	push_basic_types()
	int int_type = type_lookup(c"int")
	int char_type = type_lookup(c"char")
	int char_ptr = type_lookup_pointer(c"char", 1)
	int int_ptr = type_lookup_pointer(c"int", 1)
	int void_ptr = type_lookup_pointer(c"void", 1)
	int char_ptr_ptr = type_lookup_pointer(c"char", 2)

	# int <-> pointer requires an explicit cast now
	assert_equal(0, types_compatible(char_ptr, int_type))
	assert_equal(0, types_compatible(int_type, char_ptr))

	# constants (integer/char literals, &x) remain untyped for now
	assert_equal(1, types_compatible(int_type, 3))
	assert_equal(1, types_compatible(char_ptr, 3))

	# function values only convert via signature match or cast
	assert_equal(0, types_compatible(int_type, 4))
	assert_equal(0, types_compatible(char_ptr, 4))

	# scalar widths still convert implicitly; void* still bridges pointers
	assert_equal(1, types_compatible(int_type, char_type))
	assert_equal(1, types_compatible(char_ptr, void_ptr))
	assert_equal(1, types_compatible(void_ptr, int_ptr))

	# pointer depth and base type still matter
	assert_equal(0, types_compatible(char_ptr, char_ptr_ptr))
	assert_equal(0, types_compatible(char_ptr, int_ptr))
	assert_equal(0, types_compatible(void_ptr, char_ptr_ptr))


# The 'gpu' pointer qualifier: 'gpu float32*' points at a gpu-object
# record that canonicalizes to float32 (sizes, float kind, element
# lookup unchanged) while pointer compatibility keeps the host and
# device domains apart.
void test_gpu_qualifier_types():
	push_basic_types()
	int f32 = type_lookup(c"float32")
	int g = type_get_gpu(f32)
	assert_equal(g, type_get_gpu(f32))
	assert1(type_is_gpu_object(g))
	assert_equal(0, type_is_gpu_object(f32))
	assert_equal(f32, type_canonical(g))
	assert_equal(f32, type_strip_gpu(g))
	assert_equal(4, type_get_size(g))
	assert_equal(1, type_float_kind(g))
	int gptr = type_push_pointer(type_get_name(g), word_size, 1)
	assert_equal(g, type_lookup_previous_pointer(gptr))
	assert1(type_is_gpu_pointer(gptr))
	int hptr = type_lookup_pointer(c"float32", 1)
	assert_equal(0, type_is_gpu_pointer(hptr))
	assert_equal(hptr, type_gpu_pointer_host_twin(gptr))
	assert_equal(0, types_compatible(hptr, gptr))
	assert_equal(0, types_compatible(gptr, hptr))
	assert1(types_gpu_domain_mismatch(hptr, gptr))
	assert_equal(0, types_gpu_domain_mismatch(hptr, 3))
	assert_equal(1, types_compatible(gptr, gptr))
	assert_equal(1, types_compatible(gptr, 3))
	int void_ptr = type_lookup_pointer(c"void", 1)
	assert_equal(0, types_compatible(void_ptr, gptr))
	int gvoid = type_get_gpu(type_lookup(c"void"))
	int gvoid_ptr = type_push_pointer(type_get_name(gvoid), word_size, 1)
	assert_equal(1, types_compatible(gvoid_ptr, gptr))
	assert_equal(1, types_compatible(gptr, gvoid_ptr))

# Checked pointer identities survive aliases and value promotion while
# keeping the raw pointer ABI. Shared dereference produces a const lvalue.
void test_checked_pointer_types():
	push_basic_types()
	assert_equal(0, type_safe_used)
	int pointer_type = type_lookup_pointer(c"int", 1)
	int owner = type_get_safe(pointer_type, 1)
	int shared = type_get_safe(pointer_type, 2)
	int exclusive = type_get_safe(pointer_type, 3)
	assert_equal(1, type_safe_used)
	assert_equal(owner, type_get_safe(pointer_type, 1))
	assert_equal(1, type_safe_kind(owner))
	assert_equal(2, type_safe_kind(type_value(shared)))
	assert_equal(3, type_safe_kind(exclusive))
	assert_equal(0, type_safe_kind(pointer_type))
	assert_equal(0, type_safe_kind(-1))
	assert_equal(pointer_type, type_safe_target(owner))
	assert_equal(pointer_type, type_safe_target(pointer_type))
	assert_equal(owner, type_canonical(owner))
	assert_equal(owner, type_unqualified(type_push_const(owner)))
	int alias = type_push_alias(c"owned_int", owner)
	assert_equal(1, type_safe_kind(alias))
	assert_equal(pointer_type, type_safe_target(alias))
	assert_equal(__word_size__, type_get_size(owner))
	assert_equal(1, type_get_pointer_level(shared))
	assert_equal(type_lookup(c"int"), type_lookup_previous_pointer(owner))
	assert_equal(type_lookup(c"int"), type_lookup_previous_pointer(exclusive))
	int read_only = type_lookup_previous_pointer(shared)
	assert1(type_is_const(read_only))
	assert_equal(read_only, type_lookup_previous_pointer(shared))
	assert_equal(type_lookup(c"int"), type_unqualified(read_only))
	assert1(types_compatible(owner, pointer_type))
	assert1(types_compatible(shared, owner))
	assert_equal(0, types_compatible(owner, type_lookup_pointer(c"char", 1)))


# wbuild: target=type_table_test tag=tests dep=wv2
# wbuild: step="bin/wv2 compiler/type_table_test.w -o bin/type_table_test"
# wbuild: step="bin/type_table_test"
