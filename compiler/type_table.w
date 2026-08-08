# One type-table record. Every slot is a full host word: pointers must
# be, since the heap sits above 4 GB on arm64 macOS, and keeping the rest
# uniform costs nothing. Records are allocated individually (type_alloc)
# and never moved -- type_records holds their addresses as untyped words,
# which is the one word -> pointer boundary in this file.
#
# The array fields carry W's 2-word {data, length} descriptors, which
# point into the record itself. That is why type_alloc uses 'new' rather
# than malloc (only 'new' initializes them) and why a record must never
# be byte-copied or stored in a list[type_rec] -- the copy's descriptors
# would still address the original. Copying happens field by field, in
# type_alias_record and type_const_record.
#
# Named 'type_rec' rather than 'type_record' because type_record() below
# is the accessor function external callers use.
struct type_rec:
	char* name
	int num_fields
	int total_size
	int pointer_level
	int alias_target        # alias/const/element/key type
	int kind                # type_kind_*; 0 for a plain struct
	int fn_return_type      # also the map value type
	int fn_param_count      # also the array length
	int decl_file_index     # -1 when unrecorded (dwarf.w debug_files)
	int decl_line           # 1-based
	int decl_column         # 1-based
	char*[100] field_names
	int[100] field_types
	int[10] fn_param_types


list[int] type_records

# Name -> index of the FIRST record carrying that name, which is what
# type_lookup returns. Names are not unique here: pointer records store
# their base type's name, 'const T' is pushed unconditionally, and an
# alias can collide with an existing type, so oldest-wins is load-bearing
# -- type_reset_for_redefinition's comment records that derived and
# memoized type records depend on it.
#
# Filled lazily from type_index_indexed up to type_records.length at
# lookup time, rather than at each of the eleven push sites: the table is
# append-only during a compile, so one watermark covers all of them.
# type_table_truncate (wdbg/REPL rollback) and a re-run of
# push_basic_types both leave the watermark above the live length, which
# is the rebuild signal.
map[char*, int] type_name_index
int type_index_indexed


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
int uint8_type
int uint16_type
int uint32_type
int type_kind_alias
int type_kind_function
int type_kind_union
int type_kind_enum
int type_kind_const
int string_type
int string_value_type
int var_type
int var_value_type


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
int type_float_kind(int t);


# A type-table record by index; the list stores record addresses as
# untyped words, so this is the one word -> pointer boundary. Callers
# inside this file inline the cast instead, to save the call on paths the
# compiler walks millions of times per build.
type_rec* type_record(int type_index):
	return cast(type_rec*, type_records[type_index])


# Number of live type-table records, for callers outside this file that
# used to read the transitively-imported structures/list.w 'length' global.
int type_count():
	return type_records.length


# Discards every record pushed since the table had n live records, without
# touching the backing capacity or storage. Used by wdbg's expression
# evaluator (debugger/eval.w) to roll back types pushed while compiling an
# expression that later failed to parse/typecheck. list[T]'s '.length' is
# read-only at the language level, so this reaches through to the runtime
# struct directly (structures/w_list.w, auto-imported into every program).
void type_table_truncate(int n):
	__w_list* raw = cast(__w_list*, type_records)
	raw.length = n


# Allocate a record with the declaration-location fields cleared; the
# type_push_* constructors fill in everything else. Locations are recorded
# by the grammar for user-declared types via type_set_decl_location().
type_rec* type_alloc():
	# 'new' (not malloc) because the record's array fields carry
	# descriptors that only 'new' initializes; it also zeroes the record.
	type_rec* new_type = new type_rec
	new_type.decl_file_index = -1
	return new_type


# These take plain (non-negative) type-table indexes, as returned by the
# type_push_* constructors.
void type_set_decl_location(int type_index, int file_index, int line, int column):
	type_rec* t = cast(type_rec*, type_records[type_index])
	t.decl_file_index = file_index
	t.decl_line = line
	t.decl_column = column


int type_decl_file_index(int type_index):
	type_rec* t = cast(type_rec*, type_records[type_index])
	return t.decl_file_index


int type_decl_line(int type_index):
	type_rec* t = cast(type_rec*, type_records[type_index])
	return t.decl_line


int type_decl_column(int type_index):
	type_rec* t = cast(type_rec*, type_records[type_index])
	return t.decl_column


int type_push_pointer(char* name, int size, int pointer_level):
	type_rec* new_type = type_alloc()
	new_type.name = name
	new_type.num_fields = 0
	new_type.total_size = size
	new_type.pointer_level = pointer_level
	new_type.alias_target = -1
	new_type.kind = 0
	new_type.fn_return_type = -1
	new_type.fn_param_count = -1
	int new_type_index = type_records.length
	type_records.push(cast(int, new_type))
	return new_type_index


int type_push_size(char* name, int size):
	type_rec* new_type = type_alloc()
	new_type.name = name
	new_type.num_fields = 0
	new_type.total_size = size
	new_type.pointer_level = 0
	new_type.alias_target = -1
	new_type.kind = 0
	new_type.fn_return_type = -1
	new_type.fn_param_count = -1
	int new_type_index = type_records.length
	type_records.push(cast(int, new_type))
	return new_type_index


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


int type_kind_list():
	return 12


int type_kind_var():
	return 13


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


# Pointer records store the base name without stars, so append them here
# to keep list[char*] distinguishable from list[char] in diagnostics.
char* type_make_list_name(int element_type):
	char* open = strjoin(c"list[", type_get_name(element_type))
	int stars = type_get_pointer_level(element_type)
	while (stars > 0):
		char* with_star = strjoin(open, c"*")
		free(open)
		open = with_star
		stars = stars - 1
	char* name = strjoin(open, c"]")
	free(open)
	return name


# A T[N] array is NOT flat element storage: type_push_array's size
# formula below, (2 * word_size) + (length * element_size), prepends a
# 2-word runtime descriptor header -- a data-pointer word (doubling as
# capacity bookkeeping) followed by a length word -- and only then the
# N inline elements. The array's lvalue address (and any struct field's
# offset for a T[N] field) is the HEADER's address; the element data
# starts this many bytes later. Reflection-style code that walks struct
# bytes via type_get_size/offset arithmetic must add this offset to
# reach a T[N] field's elements (ordinary indexing and decay already
# do).
int type_array_element_offset():
	return 2 * word_size


int type_push_array(int element_type, int length):
	type_rec* new_type = type_alloc()
	new_type.name = type_make_array_name(element_type, length)
	new_type.num_fields = 0
	new_type.total_size = (2 * word_size) + (length * type_get_size(element_type))
	new_type.pointer_level = 0
	new_type.alias_target = element_type
	new_type.kind = type_kind_array()
	new_type.fn_return_type = length
	new_type.fn_param_count = -1
	int new_type_index = type_records.length
	type_records.push(cast(int, new_type))
	return new_type_index


int type_push_slice(int element_type):
	type_rec* new_type = type_alloc()
	new_type.name = type_make_slice_name(element_type)
	new_type.num_fields = 0
	new_type.total_size = word_size
	new_type.pointer_level = 0
	new_type.alias_target = element_type
	new_type.kind = type_kind_slice()
	new_type.fn_return_type = -1
	new_type.fn_param_count = -1
	int new_type_index = type_records.length
	type_records.push(cast(int, new_type))
	return new_type_index


int type_push_slice_value(int element_type):
	type_rec* new_type = type_alloc()
	char* storage_name = type_make_slice_name(element_type)
	char* name = strjoin(storage_name, c" value")
	free(storage_name)
	new_type.name = name
	new_type.num_fields = 0
	new_type.total_size = 0
	new_type.pointer_level = 0
	new_type.alias_target = element_type
	new_type.kind = type_kind_slice_value()
	new_type.fn_return_type = -1
	new_type.fn_param_count = -1
	int new_type_index = type_records.length
	type_records.push(cast(int, new_type))
	return new_type_index


int type_push_map(int key_type, int value_type):
	type_rec* new_type = type_alloc()
	new_type.name = type_make_map_name(key_type, value_type)
	new_type.num_fields = 0
	new_type.total_size = word_size
	new_type.pointer_level = 0
	new_type.alias_target = type_canonical(key_type)
	new_type.kind = type_kind_map()
	new_type.fn_return_type = type_canonical(value_type)
	new_type.fn_param_count = -1
	int new_type_index = type_records.length
	type_records.push(cast(int, new_type))
	return new_type_index


int type_push_set(int key_type):
	type_rec* new_type = type_alloc()
	new_type.name = type_make_set_name(key_type)
	new_type.num_fields = 0
	new_type.total_size = word_size
	new_type.pointer_level = 0
	new_type.alias_target = type_canonical(key_type)
	new_type.kind = type_kind_set()
	new_type.fn_return_type = -1
	new_type.fn_param_count = -1
	int new_type_index = type_records.length
	type_records.push(cast(int, new_type))
	return new_type_index


int type_push_list(int element_type):
	type_rec* new_type = type_alloc()
	new_type.name = type_make_list_name(element_type)
	new_type.num_fields = 0
	new_type.total_size = word_size
	new_type.pointer_level = 0
	new_type.alias_target = type_canonical(element_type)
	new_type.kind = type_kind_list()
	new_type.fn_return_type = -1
	new_type.fn_param_count = -1
	int new_type_index = type_records.length
	type_records.push(cast(int, new_type))
	return new_type_index


int type_push(char* name):
	return type_push_size(name, 4)


int type_lookup(char* name):
	if (type_name_index == 0):
		type_name_index = new map[char*, int]
	if (type_index_indexed > type_records.length):
		# Records were discarded (type_table_truncate) or the whole list
		# replaced (push_basic_types re-run). Indices below the new
		# length keep their meaning, but entries above it are stale and
		# there is no cheap way to tell which, so start over.
		type_name_index = new map[char*, int]
		type_index_indexed = 0
	while (type_index_indexed < type_records.length):
		# load_ptr, not *type: the name pointer occupies one pointer slot; a
		# wider load would drag in the neighboring num_fields field
		char* pushed = cast(char*, type_record(type_index_indexed).name)
		# First writer wins, so the map answers with the oldest record
		# carrying the name -- what the linear scan this replaced did by
		# returning on its first hit.
		if ((pushed in type_name_index) == 0):
			type_name_index[pushed] = type_index_indexed
		type_index_indexed = type_index_indexed + 1
	if (name in type_name_index):
		return type_name_index[name]
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
	type_rec* t = cast(type_rec*, type_records[type_index])
	if (t.kind != type_kind_alias):
		return -1
	return t.alias_target


int type_canonical(int type_index):
	type_index = type_real(type_index)
	if (type_index < 0):
		return type_index
	int guard = 0
	# One type_get_alias_target() per hop: the condition used to call it
	# and then the body called it again for the same index.
	int target = type_get_alias_target(type_index)
	while ((target >= 0) && (guard < 100)):
		type_index = target
		target = type_get_alias_target(type_index)
		guard = guard + 1
	return type_index


int type_get_const_target(int type_index):
	type_index = type_real(type_index)
	if (type_index < 0):
		return -1
	type_rec* t = cast(type_rec*, type_records[type_index])
	if (t.kind != type_kind_const):
		return -1
	return t.alias_target


int type_unqualified(int type_index):
	type_index = type_canonical(type_index)
	if (type_index < 0):
		return type_index
	int guard = 0
	# As in type_canonical: one type_get_const_target() per hop instead
	# of one in the condition and another in the body.
	int target = type_get_const_target(type_index)
	while ((target >= 0) && (guard < 100)):
		type_index = type_canonical(target)
		if (type_index < 0):
			return type_index
		target = type_get_const_target(type_index)
		guard = guard + 1
	return type_index


int type_push_alias(char* name, int target):
	int real_target = type_canonical(target)
	type_rec* new_type = type_alloc()
	type_rec* target_record = type_record(real_target)
	new_type.name = name
	new_type.num_fields = target_record.num_fields
	new_type.total_size = target_record.total_size
	new_type.pointer_level = target_record.pointer_level
	int i = 0
	while (i < 100):
		new_type.field_names[i] = target_record.field_names[i]
		new_type.field_types[i] = target_record.field_types[i]
		i = i + 1
	new_type.alias_target = real_target
	new_type.kind = type_kind_alias
	new_type.fn_return_type = -1
	new_type.fn_param_count = -1
	int new_type_index = type_records.length
	type_records.push(cast(int, new_type))
	return new_type_index


int type_push_const(int target):
	int real_target = type_canonical(target)
	char* name = strjoin(c"const ", type_get_name(real_target))
	type_rec* new_type = type_alloc()
	type_rec* target_record = type_record(real_target)
	new_type.name = name
	new_type.num_fields = target_record.num_fields
	new_type.total_size = target_record.total_size
	new_type.pointer_level = target_record.pointer_level
	int i = 0
	while (i < 100):
		new_type.field_names[i] = target_record.field_names[i]
		new_type.field_types[i] = target_record.field_types[i]
		i = i + 1
	new_type.alias_target = real_target
	new_type.kind = type_kind_const
	new_type.fn_return_type = -1
	new_type.fn_param_count = -1
	int new_type_index = type_records.length
	type_records.push(cast(int, new_type))
	return new_type_index


# Existing const wrapper over `target`, or -1 when none was pushed yet.
# The gpu capture path (grammar/kernel_decl.w) memoizes its const wrap
# through this instead of pushing a fresh record per reference.
int type_lookup_const(int target):
	int real_target = type_canonical(target)
	int i = 0
	while (i < type_records.length):
		type_rec* t = cast(type_rec*, type_records[i])
		if (t.kind == type_kind_const):
			if (t.alias_target == real_target):
				return i
		i = i + 1
	return -1


int type_get_kind(int type_index):
	type_index = type_canonical(type_index)
	if (type_index < 0):
		return 0
	type_rec* t = cast(type_rec*, type_records[type_index])
	return t.kind


void type_set_kind(int type_index, int kind):
	type_index = type_real(type_index)
	type_rec* t = cast(type_rec*, type_records[type_index])
	t.kind = kind


int type_get_element_type(int type_index):
	type_index = type_canonical(type_index)
	if (type_index < 0):
		return -1
	type_rec* t = cast(type_rec*, type_records[type_index])
	return t.alias_target


int type_get_array_length(int type_index):
	type_index = type_canonical(type_index)
	type_rec* t = cast(type_rec*, type_records[type_index])
	return t.fn_return_type


int type_is_array(int type_index):
	return type_get_kind(type_index) == type_kind_array()


int type_is_slice(int type_index):
	int kind = type_get_kind(type_index)
	return (kind == type_kind_slice()) | (kind == type_kind_slice_value())


int type_is_string(int type_index):
	return type_get_kind(type_index) == type_kind_string()


int type_is_char(int type_index):
	type_index = type_canonical(type_index)
	if (type_index < 0):
		return 0
	if (type_get_pointer_level(type_index) != 0):
		return 0
	return strcmp(type_get_name(type_index), c"char") == 0


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


int type_is_list(int type_index):
	return type_get_kind(type_index) == type_kind_list()


int type_is_var(int type_index):
	return type_get_kind(type_index) == type_kind_var()


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
	type_rec* new_type = type_alloc()
	new_type.name = name
	new_type.num_fields = 0
	new_type.total_size = word_size
	new_type.pointer_level = 0
	new_type.alias_target = -1
	new_type.kind = type_kind_function
	new_type.fn_return_type = return_type
	new_type.fn_param_count = param_count
	int i = 0
	while (i < 10):
		int param_type = -1
		if (i < param_count):
			param_type = load_ptr(param_types + i * __word_size__)
		new_type.fn_param_types[i] = param_type
		i = i + 1
	int new_type_index = type_records.length
	type_records.push(cast(int, new_type))
	return new_type_index


int type_function_return(int type_index):
	type_index = type_canonical(type_index)
	type_rec* t = cast(type_rec*, type_records[type_index])
	return t.fn_return_type


int type_function_param_count(int type_index):
	type_index = type_canonical(type_index)
	type_rec* t = cast(type_rec*, type_records[type_index])
	return t.fn_param_count


int type_function_param_type(int type_index, int i):
	type_index = type_canonical(type_index)
	if (i >= type_function_param_count(type_index)):
		return -1
	if (i >= 10):
		return -1
	type_rec* t = cast(type_rec*, type_records[type_index])
	return t.fn_param_types[i]


int type_lookup_array(int element_type, int array_length):
	element_type = type_canonical(element_type)
	int i = 0
	while (i < type_records.length):
		type_rec* t = cast(type_rec*, type_records[i])
		# Kind first, in its own test, exactly as type_lookup_slice below
		# explains: '&' does not short-circuit, so the original reached
		# type_canonical() with slot 204 of every record whatever its
		# kind -- the very thing that comment warns must never happen.
		if (t.kind == type_kind_array()):
			if (t.fn_return_type == array_length):
				if (type_canonical(t.alias_target) == element_type):
					return i
		i = i + 1
	return -1


int type_lookup_slice(int element_type):
	element_type = type_canonical(element_type)
	int i = 0
	while (i < type_records.length):
		type_rec* t = cast(type_rec*, type_records[i])
		# Check the kind alone first: '&' does not short-circuit, and for
		# other kinds slot 204/206 may hold a non-type value (an array
		# entry keeps its length in slot 206), which must never reach
		# type_canonical() as a type index.
		if (t.kind == type_kind_slice()):
			if (type_canonical(t.alias_target) == element_type):
				return i
		i = i + 1
	return -1


int type_lookup_slice_value(int element_type):
	element_type = type_canonical(element_type)
	int i = 0
	while (i < type_records.length):
		type_rec* t = cast(type_rec*, type_records[i])
		if (t.kind == type_kind_slice_value()):
			if (type_canonical(t.alias_target) == element_type):
				return i
		i = i + 1
	return -1


int type_lookup_map(int key_type, int value_type):
	key_type = type_canonical(key_type)
	value_type = type_canonical(value_type)
	int i = 0
	while (i < type_records.length):
		type_rec* t = cast(type_rec*, type_records[i])
		if (t.kind == type_kind_map()):
			if ((type_canonical(t.alias_target) == key_type) &
					(type_canonical(t.fn_return_type) == value_type)):
				return i
		i = i + 1
	return -1


int type_lookup_set(int key_type):
	key_type = type_canonical(key_type)
	int i = 0
	while (i < type_records.length):
		type_rec* t = cast(type_rec*, type_records[i])
		if (t.kind == type_kind_set()):
			if (type_canonical(t.alias_target) == key_type):
				return i
		i = i + 1
	return -1


int type_lookup_list(int element_type):
	element_type = type_canonical(element_type)
	int i = 0
	while (i < type_records.length):
		type_rec* t = cast(type_rec*, type_records[i])
		if (t.kind == type_kind_list()):
			if (type_canonical(t.alias_target) == element_type):
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


int type_get_list(int element_type):
	int list_type = type_lookup_list(element_type)
	if (list_type < 0):
		list_type = type_push_list(type_canonical(element_type))
	return list_type


int type_map_key_type(int type_index):
	type_index = type_canonical(type_index)
	type_rec* t = cast(type_rec*, type_records[type_index])
	return t.alias_target


int type_map_value_type(int type_index):
	type_index = type_canonical(type_index)
	type_rec* t = cast(type_rec*, type_records[type_index])
	return t.fn_return_type


int type_set_key_type(int type_index):
	type_index = type_canonical(type_index)
	type_rec* t = cast(type_rec*, type_records[type_index])
	return t.alias_target


int type_list_element_type(int type_index):
	type_index = type_canonical(type_index)
	type_rec* t = cast(type_rec*, type_records[type_index])
	return t.alias_target


char* type_get_name(int type_index):
	type_index = type_real(type_index)
	type_rec* t = type_record(type_index)
	return t.name


int type_num_args(int type_index):
	type_index = type_canonical(type_index)
	type_rec* t = cast(type_rec*, type_records[type_index])
	return t.num_fields


int type_get_size(int type_index):
	type_index = type_canonical(type_index)
	type_rec* t = cast(type_rec*, type_records[type_index])
	return t.total_size


int type_get_pointer_level(int type_index):
	type_index = type_canonical(type_index)
	type_rec* t = cast(type_rec*, type_records[type_index])
	return t.pointer_level


int type_lookup_pointer(char* name, int pointer_level):
	int i = 0
	int trace = verbosity >= 1
	while (i < type_records.length):
		type_rec* t = type_record(i)
		if (trace):
			print_hex(c"type_lookup_pointer t: ", cast(int, t))
		# Pointer level first, and as a nested test rather than one '&'
		# chain: '&' does not short-circuit, so the original ran a strcmp
		# against every record in the table on every call. The level is a
		# word compare and rejects almost all of them.
		if (pointer_level == t.pointer_level):
			if (strcmp(name, t.name) == 0):
				return i
		i = i + 1
	return -1


# 1 when t is exactly void* (one pointer level over void)
int type_is_void_pointer(int t):
	t = type_unqualified(t)
	if (type_get_pointer_level(t) != 1):
		return 0
	return strcmp(type_get_name(t), c"void") == 0


# 1 when values of type t convert to and from var: string, char*, and
# the word-or-narrower int-likes (int, fixed-width ints, char, bool,
# enums). Floats, structs, containers, and other pointers do not box.
int type_var_boxable(int t):
	t = type_unqualified(t)
	if (type_is_string(t)):
		return 1
	if (type_is_char_pointer(t)):
		return 1
	if (type_float_kind(t)):
		return 0
	if (type_get_pointer_level(t) > 0):
		return 0
	if (type_num_args(t) > 0):
		return 0
	if (type_is_map(t) | type_is_set(t) | type_is_list(t)):
		return 0
	if (type_is_array(t) | type_is_slice(t)):
		return 0
	int size = type_get_size(t)
	return (size == 1) | (size == 2) | (size == 4) | (size == 8)


# Unboxing additionally allows void*: the raw box pointer escape hatch
# used by seed-safe runtime helpers such as print_var.
int type_var_unboxable(int t):
	if (type_is_void_pointer(t)):
		return 1
	return type_var_boxable(t)


# 1 for the fixed-width unsigned integer types narrower than a 64-bit
# word (uint8/uint16/uint32). Their loads must zero-extend into the
# word-sized register (promote(), grammar/promote.w): the sign-extending
# subword loads the signed types use would hand every later compare,
# divide, modulo, shift and widening a negative word for a stored
# high-bit value. uint64 and word-sized uint load at full width already.
int type_is_unsigned_fixed(int type_index):
	type_index = type_unqualified(type_index)
	if (type_index == uint8_type):
		return 1
	if (type_index == uint16_type):
		return 1
	if (type_index == uint32_type):
		return 1
	return 0


# Return 1 when a value of type 'got' can be stored where 'want' is expected.
# "constant" (3) results (integer/char/string literals, addresses from '&',
# untyped call results) carry no type information yet, so they remain
# compatible with everything until typed literals land. Everything else is
# checked: "function" (4) values only convert to a matching typed function
# pointer (see types_compatible_with_expression), scalars convert between
# widths silently, and pointers must agree on depth and base type, except
# that void* converts to and from any same-depth pointer. Plain 'int' is a
# word-sized scalar, not an untyped word: int <-> pointer conversions need
# an explicit cast(). Distinct struct types never convert.
int types_compatible(int want, int got):
	want = type_unqualified(want)
	got = type_unqualified(got)
	if (got == 3):
		return 1
	if (got == 4):
		return 0
	if (want == got):
		return 1
	if (type_is_var(want) & type_is_var(got)):
		return 1
	if (type_is_var(want)):
		return type_var_boxable(got)
	if (type_is_var(got)):
		return type_var_unboxable(want)
	if (type_is_string(want) & type_is_string(got)):
		return 1
	if (type_is_string(want) & type_is_char_pointer(got)):
		return 1
	if (type_is_string(want) | type_is_string(got)):
		return 0
	if (type_is_map(want) & type_is_map(got)):
		return (type_unqualified(type_map_key_type(want)) == type_unqualified(type_map_key_type(got))) &
				(type_unqualified(type_map_value_type(want)) == type_unqualified(type_map_value_type(got)))
	if (type_is_set(want) & type_is_set(got)):
		return type_unqualified(type_set_key_type(want)) == type_unqualified(type_set_key_type(got))
	if (type_is_map(want) | type_is_map(got) | type_is_set(want) | type_is_set(got)):
		return 0
	if (type_is_list(want) & type_is_list(got)):
		return type_unqualified(type_list_element_type(want)) == type_unqualified(type_list_element_type(got))
	if (type_is_list(want) | type_is_list(got)):
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
	if (strcmp(type_get_name(want), type_get_name(got)) == 0):
		return 1
	# Pointer entries store the base type's name; aliases of the same base
	# (e.g. FILE* vs _IO_FILE*) must stay interchangeable.
	int want_base = type_lookup(type_get_name(want))
	int got_base = type_lookup(type_get_name(got))
	if ((want_base < 0) || (got_base < 0)):
		return 0
	return type_canonical(want_base) == type_canonical(got_base)


# Return 1 when 'got' is a slice VALUE (a promoted array or slice
# expression: eax holds the {data, length} descriptor's address) that
# decays to the pointer type 'want'. Decay targets are the element type's
# own pointer (char[] -> char*, char*[] -> char**) and void*. coerce()
# performs the decay by loading the descriptor's first word, turning the
# descriptor address into the data pointer.
int type_decays_to_pointer(int want, int got):
	got = type_unqualified(got)
	if (type_get_kind(got) != type_kind_slice_value()):
		return 0
	want = type_unqualified(want)
	if (want < 0):
		return 0
	int want_level = type_get_pointer_level(want)
	if (want_level < 1):
		return 0
	if (type_is_void_pointer(want)):
		return 1
	int element = type_unqualified(type_get_element_type(got))
	if (element < 0):
		return 0
	if (want_level != type_get_pointer_level(element) + 1):
		return 0
	if (strcmp(type_get_name(want), type_get_name(element)) == 0):
		return 1
	# Pointer entries store the base type's name; decay through an alias
	# of the element's base (e.g. FILE* from _IO_FILE[]) stays valid.
	int want_base = type_lookup(type_get_name(want))
	int element_base = type_lookup(type_get_name(element))
	if ((want_base < 0) || (element_base < 0)):
		return 0
	return type_canonical(want_base) == type_canonical(element_base)


# Float kind of an expression type, as a VALUE after promote(): 0 = not
# float, 1 = float32 bits in eax, 2 = float64 bits in rax. float16 counts
# as kind 1 because its load path widens to float32. Pointer types have
# their own indices, so float* correctly reads as kind 0.
int type_float_kind(int t):
	# Unqualified, not just canonical: a const-wrapped float (e.g. a
	# 'gpu for' scalar capture) must still read as a float so promote()
	# routes its loads through the float pipeline.
	t = type_unqualified(t)
	if ((t == float32_type) || (t == float_type) ||
			(t == float16_type) || (t == float32_value_type)):
		return 1
	if ((t == float64_type) || (t == float64_value_type)):
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


# Clears an existing struct/union/enum's field list so a redeclaration at
# the REPL prompt (struct_declaration.w et al.) can re-add fields from
# scratch under the SAME type_index, instead of pushing a second, later
# record that type_lookup's first-match scan would never find — type_lookup
# scans oldest-first everywhere else (derived/memoized type names, e.g.
# pointer/array records, rely on that), so redefinition reuses the
# existing record in place rather than changing that scan order.
void type_reset_for_redefinition(int type_index, int size):
	type_rec* t = cast(type_rec*, type_records[type_index])
	t.num_fields = 0
	t.total_size = size
	t.pointer_level = 0


int type_add_arg(int type_index, char* field, int field_type):
	type_index = type_canonical(type_index)
	type_rec* t = cast(type_rec*, type_records[type_index])
	int num_fields = t.num_fields
	int max_fields = 100
	assert1(num_fields < max_fields)
	if (verbosity > 0):
		print_int(c"num_fields: ", num_fields)
		print2(c"adding field: ")
		print2(field)
		print2(c"(")
		print2(itoa(field_type))
		println2(c")")
	t.field_names[num_fields] = field
	t.field_types[num_fields] = field_type
	t.num_fields = num_fields + 1
	# Update total size. Structs sum fields; unions take the largest field.
	int field_size = type_get_size(field_type)
	if (type_get_kind(type_index) == type_kind_union):
		if (field_size > t.total_size):
			t.total_size = field_size
	else:
		t.total_size = t.total_size + field_size


int type_get_arg(int type_index, char* field):
	type_index = type_canonical(type_index)
	if (verbosity > 0):
		print2(c"type_get_arg(")
		print2(itoa(type_index))
		print2(c", '")
		print2(field)
		println2(c"')")
	type_rec* t = cast(type_rec*, type_records[type_index])
	int num_fields = t.num_fields
	if (verbosity > 0):
		print_int(c"num_fields: ", num_fields)
	int i = 0
	while (i < num_fields):
		char* f = t.field_names[i]
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
	type_rec* t = cast(type_rec*, type_records[type_index])
	int num_fields = t.num_fields
	int offset = 0
	int i = 0
	while (i < num_fields):
		char* f = t.field_names[i]
		if (strcmp(field, f) == 0):
			return offset
		int field_type = t.field_types[i]
		int field_size = type_get_size(field_type)
		if (type_get_kind(type_index) != type_kind_union):
			offset = offset + field_size
		i = i + 1
	return -1


# Field name by 0-based field index
char* type_get_field_name_at(int type_index, int i):
	type_index = type_canonical(type_index)
	type_rec* t = cast(type_rec*, type_records[type_index])
	return t.field_names[i]


# Field type by 0-based field index
int type_get_field_type_at(int type_index, int i):
	type_index = type_canonical(type_index)
	type_rec* t = cast(type_rec*, type_records[type_index])
	return t.field_types[i]


# Byte offset of the field at 0-based index i
int type_get_field_offset_at(int type_index, int i):
	type_index = type_canonical(type_index)
	type_rec* t = cast(type_rec*, type_records[type_index])
	int offset = 0
	int j = 0
	if (type_get_kind(type_index) == type_kind_union):
		return 0
	while (j < i):
		offset = offset + type_get_size(t.field_types[j])
		j = j + 1
	return offset


# return type.field.type
int type_get_field_type(int type_index, char* field):
	type_index = type_canonical(type_index)
	type_rec* t = cast(type_rec*, type_records[type_index])
	int num_fields = t.num_fields
	int i = 0
	while (i < num_fields):
		char* f = t.field_names[i]
		int field_type = t.field_types[i]
		if (strcmp(field, f) == 0):
			return field_type
		i = i + 1
	return -1


void type_print(int type_index):
	type_index = type_real(type_index)
	# print_int("type_print: ", type_index)
	type_rec* t = type_record(type_index)
	int i = 0
	int num_fields = t.num_fields
	print2((itoa(type_index)))
	print2(c":")
	if (num_fields > 0):
		print2(c"struct ")
		char* type_name = t.name
		print_n(type_name, strlen(type_name))
		print2(c": ")
	else:
		char* type_name = t.name
		print_n(type_name, strlen(type_name))
	# print_int("num_fields: ", num_fields)
	if (num_fields <= 0):
		println2(c"")
		return;
	print2(c"(")
	while (i < num_fields):
		char* field_name = t.field_names[i]
		int field_type = t.field_types[i]
		type_rec* field_type_name = type_record(field_type)

		if (i > 0):
			print2(c"; ")

		char* printed_field_type = field_type_name.name
		print_n(printed_field_type, strlen(printed_field_type))
		print2(c" ")
		print_n(field_name, strlen(field_name))

		i = i + 1

	println2(c"")


void type_print_all():
	println2(c"all types:")
	int i = 0
	while (i < type_records.length):
		type_rec* type = type_record(i)
		print_error(itoa(i))
		print_error(c": ")
		print_error(str_from_cstr(type.name))
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

	type_records = new list[int]
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
	uint32_type = type_push_size(c"uint32", 4)
	uint16_type = type_push_size(c"uint16", 2)
	uint8_type = type_push_size(c"uint8", 1)
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

	# Dynamic 'var': one word holding a pointer to a heap-allocated
	# tagged box (structures/w_dynamic.w). The value pseudo-type follows
	# the string convention: eax already holds the box pointer.
	var_type = type_push_size(c"var", word_size)
	type_set_kind(var_type, type_kind_var())
	var_value_type = type_push_size(c"var value", 0)
	type_set_kind(var_value_type, type_kind_var())

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
