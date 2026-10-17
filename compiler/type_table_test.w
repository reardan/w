import lib.testing
import compiler.tokenizer
import codegen
# codegen's backends reach the symbol table and grammar through
# prototypes, and a full compile rejects a called prototype that never
# gets a body, so link the rest of the compiler rather than half of it.
import compiler.compiler

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


# Contract spelling is semantic metadata: no representation change, and
# aliases/const wrappers must preserve it until the safety pass binds it.
void test_checked_lifetime_types():
	push_basic_types()
	int pointer_type = type_lookup_pointer(c"int", 1)
	int shared = type_get_safe(pointer_type, 2)
	int first = type_get_safe_lifetime(pointer_type, 2, c"first")
	int second = type_get_safe_lifetime(pointer_type, 2, c"second")
	int mutable = type_get_safe_lifetime(pointer_type, 3, c"first")
	assert1(first != shared)
	assert1(first != second)
	assert1(first != mutable)
	assert_equal(first, type_get_safe_lifetime(pointer_type, 2, c"first"))
	assert_equal(0, strcmp(type_record(first).safe_lifetime, c"first"))
	assert_equal(0, strcmp(type_get_name(first), c"ref[first] int"))
	assert_equal(0, strcmp(type_get_name(mutable), c"refmut[first] int"))
	assert_equal(pointer_type, type_safe_target(first))
	assert_equal(__word_size__, type_get_size(first))
	assert1(types_compatible(first, second))
	assert1(types_compatible(first, shared))
	int alias = type_push_alias(c"borrowed_int", first)
	assert_equal(first, type_unqualified(type_push_const(alias)))
	int snapshot = retained_type_note(first)
	assert_equal(0, strcmp(retained_types[snapshot].lifetime, c"first"))
	assert_equal(snapshot, retained_type_note(first))
	int alias_snapshot = retained_type_note(alias)
	assert_equal(snapshot, retained_types[alias_snapshot].target)
	assert1(retained_types[retained_type_note(shared)].lifetime == 0)


void test_optional_reference_types():
	push_basic_types()
	int pointer_type = type_lookup_pointer(c"int", 1)
	for kind in range(6, 8):
		int optional = type_get_safe_lifetime(pointer_type, kind, c"a")
		int unnamed = type_get_safe(pointer_type, kind)
		assert_equal(optional, type_get_safe_lifetime(pointer_type, kind, c"a"))
		assert_equal(unnamed, type_get_safe(pointer_type, kind))
		assert1(optional != unnamed)
		assert_equal(kind - 4, type_safe_kind(optional))
		assert_equal(pointer_type, type_safe_target(optional))
		assert_equal(__word_size__, type_get_size(optional))
		assert_equal(1, type_get_pointer_level(optional))
		int alias = type_push_alias(c"MaybeReference", optional)
		assert_equal(kind - 4, type_safe_kind(alias))
		int snapshot = retained_type_note(alias)
		int target = retained_types[snapshot].target
		assert_equal(kind + 20, retained_types[target].kind)
		assert_equal(0, strcmp(retained_types[target].lifetime, c"a"))
		assert1(types_compatible(optional, pointer_type))
	assert_equal(0, strcmp(type_get_name(type_get_safe(pointer_type, 6)), c"optref int"))
	assert_equal(0, strcmp(type_get_name(type_get_safe_lifetime(pointer_type, 7, c"a")), c"optrefmut[a] int"))


void test_optional_owner_type():
	push_basic_types()
	int pointer = type_lookup_pointer(c"int", 1)
	int optional = type_get_safe(pointer, 9)
	assert_equal(optional, type_get_safe(pointer, 9))
	assert1(optional != type_get_safe(pointer, 1))
	assert_equal(1, type_safe_kind(optional))
	assert_equal(pointer, type_safe_target(optional))
	assert_equal(__word_size__, type_get_size(optional))
	assert_equal(0, strcmp(type_get_name(optional), c"optown int"))
	int alias = type_push_alias(c"OptionalOwner", optional)
	assert_equal(1, type_safe_kind(alias))
	int snapshot = retained_type_note(alias)
	assert_equal(type_kind_optown, retained_types[retained_types[snapshot].target].kind)
	assert1(types_compatible(optional, pointer))


void test_checked_slice_types():
	push_basic_types()
	int element = type_lookup(c"int")
	int view = type_get_safe_slice(element, c"data")
	int plain_view = type_get_safe_slice(element, 0)
	assert_equal(view, type_get_safe_slice(element, c"data"))
	assert_equal(plain_view, type_get_safe_slice(element, 0))
	assert1(view != plain_view)
	assert1(type_is_safe_slice(view))
	assert1(type_is_slice(view))
	assert_equal(2, type_safe_kind(view))
	assert_equal(view, type_safe_target(view))
	assert_equal(element, type_get_element_type(view))
	assert_equal(2 * __word_size__, type_get_size(view))
	assert_equal(2, type_stack_words(view))
	assert_equal(2, type_num_args(view))
	assert_equal(0, type_get_field_offset(view, c"data"))
	assert_equal(__word_size__, type_get_field_offset(view, c"length"))
	assert_equal(0, strcmp(type_get_name(view), c"ref[data] int[]"))
	int alias = type_push_alias(c"checked_slice", view)
	assert1(type_is_safe_slice(alias))
	assert_equal(view, type_unqualified(alias))
	int snapshot = retained_type_note(view)
	assert_equal(type_kind_safe_slice, retained_types[snapshot].kind)
	assert_equal(0, strcmp(retained_types[snapshot].lifetime, c"data"))
	assert_equal(element, retained_types[retained_types[snapshot].target].origin)


void test_checked_record_types():
	push_basic_types()
	int pointer_type = type_lookup_pointer(c"int", 1)
	int field_type = type_get_safe_lifetime(pointer_type, 2, c"inner")
	int base = type_push(c"Holder")
	type_add_arg(base, c"item", field_type)
	type_add_arg(base, c"tag", type_lookup(c"int"))
	int view = type_get_safe_record(base, c"outer")
	assert_equal(view, type_get_safe_record(base, c"outer"))
	assert1(type_is_safe_record(view))
	assert_equal(2, type_safe_kind(view))
	assert_equal(view, type_safe_target(view))
	assert_equal(base, type_record(view).alias_target)
	assert_equal(type_get_size(base), type_get_size(view))
	assert_equal(type_num_args(base), type_num_args(view))
	int field = type_get_field_type(view, c"item")
	assert_equal(0, strcmp(type_record(field).safe_lifetime, c"outer"))
	assert_equal(0, strcmp(type_record(type_get_field_type(base, c"item")).safe_lifetime, c"inner"))
	assert_equal(0, strcmp(type_get_name(view), c"ref[outer] Holder"))
	assert1(types_compatible(view, base))
	assert1(types_compatible(view, type_get_safe_record(base, c"other")))
	assert_equal(0, types_compatible(view, type_push(c"Unrelated")))
	int plain_view = type_get_safe_record(base, 0)
	assert_equal(plain_view, type_get_safe_record(base, 0))
	assert1(type_record(type_get_field_type(plain_view, c"item")).safe_lifetime == 0)
	int snapshot = retained_type_note(view)
	assert_equal(type_kind_safe_record, retained_types[snapshot].kind)
	assert_equal(base, retained_types[retained_types[snapshot].target].origin)
	assert_equal(0, strcmp(retained_types[snapshot].lifetime, c"outer"))

	int slice_base = type_push(c"SliceHolder")
	type_add_arg(slice_base, c"items", type_get_safe_slice(type_lookup(c"int"), c"inside"))
	int slice_view = type_get_safe_record(slice_base, c"outside")
	int slice_field = type_get_field_type(slice_view, c"items")
	assert1(type_is_safe_slice(slice_field))
	assert_equal(type_get_size(slice_base), type_get_size(slice_view))
	assert_equal(0, strcmp(type_record(slice_field).safe_lifetime, c"outside"))


# wbuild: target=type_table_test tag=tests dep=wv2
# wbuild: step="bin/wv2 compiler/type_table_test.w -o bin/type_table_test"
# wbuild: step="bin/type_table_test"


void test_mutable_record_types():
	push_basic_types()
	int pointer_type = type_lookup_pointer(c"int", 1)
	int base = type_push(c"MutableView")
	type_add_arg(base, c"item", type_get_safe_lifetime(pointer_type, 3, c"inside"))
	type_add_arg(base, c"tag", type_lookup(c"int"))
	int view = type_get_safe_record_kind(base, c"outside", 3)
	assert1(type_is_safe_record(view))
	assert_equal(view, type_safe_target(view))
	assert_equal(3, type_safe_kind(view))
	assert_equal(type_get_size(base), type_get_size(view))
	assert_equal(view, type_get_safe_record_kind(base, c"outside", 3))
	assert_equal(0, strcmp(type_get_name(view), c"refmut[outside] MutableView"))
	assert_equal(3, type_safe_kind(type_get_field_type(view, c"item")))
	assert_equal(0, strcmp(type_record(type_get_field_type(view, c"item")).safe_lifetime, c"outside"))
	assert1(view != type_get_safe_record(base, c"outside"))
	int unnamed = type_get_safe_record_kind(base, 0, 3)
	assert_equal(unnamed, type_get_safe_record_kind(base, 0, 3))
	assert1(type_record(type_get_field_type(unnamed, c"item")).safe_lifetime == 0)
	int alias = type_push_alias(c"ExclusiveView", view)
	assert_equal(3, type_safe_kind(alias))
	int snapshot = retained_type_note(view)
	assert_equal(type_kind_safe_recordmut, retained_types[snapshot].kind)
	assert_equal(0, strcmp(retained_types[snapshot].lifetime, c"outside"))


void test_generic_contract_snapshot_survives_rollback():
	push_basic_types()
	retained_clear()
	retained_init()
	int pointer_type = type_lookup_pointer(c"int", 1)
	if (pointer_type < 0): pointer_type = type_push_pointer(c"int", word_size, 1)
	int parameter = type_get_safe_lifetime(pointer_type, 2, c"a")
	int result = type_get_safe_lifetime(pointer_type, 2, c"b")
	int signature = type_push_function(c"contract snapshot", result, 1, cast(int, &parameter))
	int* rows = cast(int*, malloc(2 * __word_size__))
	rows[0] = 3
	rows[1] = 2
	type_record(signature).fn_lifetime_order = rows
	retained_checkpoint checkpoint
	retained_capture(&checkpoint)
	int first = retained_type_note(signature)
	assert1(retained_types[first].lifetime_order != rows)
	assert_equal(3, retained_types[first].lifetime_order[0])
	assert_equal(first, retained_type_note(signature))
	# Mutating raw metadata must neither rewrite nor reuse an old snapshot.
	rows[0] = 1
	int second = retained_type_note(signature)
	assert1(first != second)
	assert_equal(3, retained_types[first].lifetime_order[0])
	assert_equal(1, retained_types[second].lifetime_order[0])
	retained_rollback(&checkpoint)
	# Reuse the reclaimed arena before taking another snapshot. The raw
	# relation must still exist independently of the discarded snapshots.
	int* reused = cast(int*, retained_arena_alloc(2 * __word_size__))
	reused[0] = 0
	reused[1] = 0
	int restored = retained_type_note(signature)
	assert_equal(1, retained_types[restored].lifetime_order[0])
	assert_equal(2, retained_types[restored].lifetime_order[1])
	type_record(signature).fn_lifetime_order = 0
	int plain = retained_type_note(signature)
	assert1(plain != restored)
	assert1(retained_types[plain].lifetime_order == 0)
	free(rows)
	retained_clear()


void test_mixed_owner_snapshot_survives_rollback():
	push_basic_types()
	retained_clear()
	retained_init()
	int pointer = type_lookup_pointer(c"int", 1)
	int base = type_push(c"OwnedGroupedPair")
	type_add_arg(base, c"stored", type_get_safe(pointer, 1))
	type_add_arg(base, c"left", type_get_safe_lifetime(pointer, 2, c"left"))
	type_add_arg(base, c"right", type_get_safe_lifetime(pointer, 2, c"right"))
	int raw = type_push_pointer(c"OwnedGroupedPair", word_size, 1)
	int input = type_get_safe_lifetime(raw, 1, c"a,b")
	int output = type_get_safe_lifetime(raw, 1, c"c,d")
	assert_equal(input, type_get_safe_lifetime(raw, 1, c"a,b"))
	assert_equal(2, type_lifetime_count(input))
	assert_equal(0, strcmp(type_lifetime_at(input, 1), c"b"))
	assert_equal(4, type_contract_slots(&input, output, 1))
	retained_checkpoint checkpoint
	retained_capture(&checkpoint)
	int first = retained_type_note(input)
	assert1(retained_types[first].lifetime_labels != type_record(input).safe_labels)
	assert_equal(type_kind_own, retained_types[first].kind)
	assert_equal(0, strcmp(retained_types[first].lifetime_labels[1], c"b"))
	retained_rollback(&checkpoint)
	int* reused = cast(int*, retained_arena_alloc(128))
	for i in range(128 / __word_size__): reused[i] = 0
	int restored = retained_type_note(input)
	int result = retained_type_note(output)
	assert_equal(0, strcmp(retained_types[restored].lifetime_labels[0], c"a"))
	assert_equal(0, strcmp(retained_types[restored].lifetime_labels[1], c"b"))
	assert_equal(0, strcmp(retained_types[result].lifetime_labels[0], c"c"))
	assert_equal(0, strcmp(type_lifetime_at(input, 1), c"b"))
	retained_clear()


void test_aggregate_group_snapshot_survives_rollback():
	push_basic_types()
	retained_clear()
	retained_init()
	int pointer = type_lookup_pointer(c"int", 1)
	int base = type_push(c"GroupedPair")
	type_add_arg(base, c"left", type_get_safe_lifetime(pointer, 2, c"left"))
	type_add_arg(base, c"right", type_get_safe_lifetime(pointer, 2, c"right"))
	int input = type_get_safe_record(base, c"a,b")
	int output = type_get_safe_record(base, c"c,d")
	assert_equal(2, type_lifetime_count(input))
	assert_equal(0, strcmp(type_lifetime_at(input, 1), c"b"))
	assert_equal(0, strcmp(type_record(type_get_field_type(input, c"right")).safe_lifetime, c"b"))
	assert_equal(0, strcmp(type_record(type_get_field_type(base, c"right")).safe_lifetime, c"right"))
	assert_equal(input, type_get_safe_record(base, c"a,b"))
	assert_equal(4, type_contract_slots(&input, output, 1))
	int signature = type_push_function(c"group snapshot", output, 1, cast(int, &input))
	int* rows = cast(int*, malloc(4 * __word_size__))
	for i in range(4): rows[i] = 1 << i
	rows[0] = rows[0] | 4
	rows[1] = rows[1] | 8
	type_record(signature).fn_lifetime_order = rows
	retained_checkpoint checkpoint
	retained_capture(&checkpoint)
	int first = retained_type_note(signature)
	int argument = retained_types[first].parameters[0]
	assert1(retained_types[argument].lifetime_labels != type_record(input).safe_labels)
	assert_equal(0, strcmp(retained_types[argument].lifetime_labels[1], c"b"))
	assert_equal(8, retained_types[first].lifetime_order[3])
	rows[3] = 12
	int second = retained_type_note(signature)
	assert1(first != second)
	assert_equal(8, retained_types[first].lifetime_order[3])
	assert_equal(12, retained_types[second].lifetime_order[3])
	retained_rollback(&checkpoint)
	int* reused = cast(int*, retained_arena_alloc(128))
	for i in range(128 / __word_size__): reused[i] = 0
	int restored = retained_type_note(signature)
	assert_equal(12, retained_types[restored].lifetime_order[3])
	int result = retained_types[restored].return_type
	assert_equal(0, strcmp(retained_types[result].lifetime_labels[0], c"c"))
	assert_equal(0, strcmp(retained_types[result].lifetime_labels[1], c"d"))
	type_record(signature).fn_lifetime_order = 0
	free(rows)
	retained_clear()


void test_owner_group_access_resets_with_retained_types():
	# Reuse retained type identities with a different field-access contract.
	# A prior compilation's cached group kinds must not survive the reset.
	int previous = -1
	for exclusive_group in range(2):
		safe_reset()
		retained_clear()
		retained_init()
		push_basic_types()
		int pointer = type_lookup_pointer(c"int", 1)
		int base = type_push(c"AccessPair")
		int first = 2
		int second = 3
		if (exclusive_group == 0):
			first = 3
			second = 2
		type_add_arg(base, c"first", type_get_safe_lifetime(pointer, first, c"first"))
		type_add_arg(base, c"second", type_get_safe_lifetime(pointer, second, c"second"))
		int raw = type_push_pointer(c"AccessPair", word_size, 1)
		int owner = retained_type_note(type_get_safe_lifetime(raw, 1, c"a,b"))
		if (previous >= 0): assert_equal(previous, owner)
		previous = owner
		assert_equal(1, safe_group_exclusive(owner, exclusive_group))
		assert_equal(0, safe_group_exclusive(owner, 1 - exclusive_group))
	safe_reset()
	retained_clear()
