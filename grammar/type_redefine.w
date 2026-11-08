# In-place type redefinition and its undo journal (REPL, engine).
#
# A struct, union, enum or message declaration whose name already exists
# resets the existing type record in place (type_reset_for_redefinition)
# instead of pushing a second record, so a rollback that truncates the type
# table by count cannot undo it. type_redefine journals the layout it is
# about to clear; a rollback (repl/core.w repl_state_restore: a failed
# entry, :reset, an engine reload or generation rollback, a checked-session
# transcript replay) undoes the journal back to the length it captured,
# newest first, so the record gets its earlier layout back.
#
# The to_json/from_json and protobuf descriptor caches (grammar/json_builtin.w,
# grammar/protobuf_builtin.w) hold one blob per type index. A blob emitted
# for the old layout must not serve the new one, nor a blob emitted for the
# new layout the restored old one, so both the redefinition and its undo
# drop that type's entries; the next use emits a fresh descriptor. An
# enum's constants (enum_name's registry, grammar/print_builtin.w) are put
# back with its layout.
struct type_redefine_saved:
	int index
	int num_fields
	int total_size
	int pointer_level
	int kind
	int decl_file_index
	int decl_line
	int decl_column
	list[char*] names
	list[int] types
	# enum_constants as it was before the redefinition (enums only); the
	# live registry continues in a copy, so this one stays as saved
	list[enum_constant_record] enum_registry


list[type_redefine_saved*] type_redefine_journal


int type_redefine_count():
	if (type_redefine_journal == 0): return 0
	return type_redefine_journal.length


# Drop every json and protobuf descriptor-cache entry for type_index.
void codec_cache_drop_type(int type_index):
	int kept = 0
	for i in range(json_codec_count):
		int type = load_int(json_codec_types + i * 4)
		if (type != type_index):
			save_int(json_codec_types + kept * 4, type)
			save_ptr(json_codec_addresses + kept * __word_size__, load_ptr(json_codec_addresses + i * __word_size__))
			kept = kept + 1
	json_codec_count = kept
	kept = 0
	for i in range(protobuf_desc_count):
		int type = load_int(protobuf_desc_types + i * 4)
		if (type != type_index):
			save_int(protobuf_desc_types + kept * 4, type)
			save_ptr(protobuf_desc_addresses + kept * __word_size__, load_ptr(protobuf_desc_addresses + i * __word_size__))
			kept = kept + 1
	protobuf_desc_count = kept


# Every in-place redefinition goes through here: journal the record, drop
# its cached descriptors, then clear it for the new fields.
void type_redefine(int type_index, int size):
	type_rec* t = cast(type_rec*, type_records[type_index])
	type_redefine_saved* e = new type_redefine_saved
	e.index = type_index
	e.num_fields = t.num_fields
	e.total_size = t.total_size
	e.pointer_level = t.pointer_level
	e.kind = t.kind
	e.decl_file_index = t.decl_file_index
	e.decl_line = t.decl_line
	e.decl_column = t.decl_column
	e.names = new list[char*]
	e.types = new list[int]
	for k in range(t.field_names.length): e.names.push(t.field_names[k])
	for k in range(t.field_types.length): e.types.push(t.field_types[k])
	e.enum_registry = 0
	if ((t.kind == type_kind_enum) && (cast(int, enum_constants) != 0)):
		e.enum_registry = enum_constants
		list[enum_constant_record] copy = new list[enum_constant_record]
		for k in range(enum_constants.length): enum_register_into(copy, enum_constants[k].type, enum_constants[k].name, enum_constants[k].value)
		enum_constants = copy
	if (type_redefine_journal == 0): type_redefine_journal = new list[type_redefine_saved*]
	type_redefine_journal.push(e)
	codec_cache_drop_type(type_index)
	type_reset_for_redefinition(type_index, size)


# Undo the redefinitions journaled since the journal had n entries, newest
# first. Call before the type table is truncated: a record pushed after the
# checkpoint is restored and then discarded with the rest.
void type_redefine_undo(int n):
	if (type_redefine_journal == 0): return;
	while (type_redefine_journal.length > n):
		type_redefine_saved* e = type_redefine_journal.pop()
		if (e.index < type_count()):
			type_rec* t = cast(type_rec*, type_records[e.index])
			t.num_fields = e.num_fields
			t.total_size = e.total_size
			t.pointer_level = e.pointer_level
			t.kind = e.kind
			t.decl_file_index = e.decl_file_index
			t.decl_line = e.decl_line
			t.decl_column = e.decl_column
			t.field_names.clear()
			t.field_types.clear()
			for k in range(e.names.length): t.field_names.push(e.names[k])
			for k in range(e.types.length): t.field_types.push(e.types[k])
			codec_cache_drop_type(e.index)
		if (e.enum_registry != 0): enum_constants = e.enum_registry
		e.names.free()
		e.types.free()
		free(cast(char*, e))
