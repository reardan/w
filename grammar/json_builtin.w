/*
Compiler lowering for the to_json/from_json builtins ("type <=> json").

to_json(expr) encodes a struct value (or struct pointer) into a
json_value* object tree; from_json(T, value) decodes a json_value* back
into a freshly allocated T*, returning 0 when the value does not match.

There is no runtime reflection: at the first use site per struct type the
compiler walks the type table and emits a static descriptor blob into the
code stream behind an unconditional jump, then lowers the builtin to
__w_json_encode(desc, addr) / __w_json_decode(desc, value) calls into
structures/json_codec.w (see that file for the descriptor layout). The
runtime module is only imported into programs that use the builtins: the
driver calls json_codec_finish_import() at a top-level boundary, because
importing mid-expression would splice module code into the current
function.

Supported field types: int and fixed-width ints (signed), bool, char*,
string, nested structs (by value), and list[T] of the above. Floats,
maps, sets, arrays, slices, unions, and pointer fields are rejected at
compile time (structures/json.w has no float support yet).

Call sites must have 'import structures.json' in scope: the builtins
produce and consume json_value*, and the struct type must exist at parse
time for the result type to be well formed.
*/
int expression();
int json_codec_descriptor(int struct_type);
int import_module(char* dotted);


int json_codec_needed

# Emitted struct descriptor address per canonical type index, so every
# use of the same struct shares one blob.
char* json_codec_types
char* json_codec_addresses
int json_codec_count


int json_codec_cache_lookup(int type_index):
	int i = 0
	while (i < json_codec_count):
		if (load_int(json_codec_types + i * 4) == type_index):
			return load_int(json_codec_addresses + i * 4)
		i = i + 1
	return 0


void json_codec_cache_store(int type_index, int address):
	int max_types = 200
	if (json_codec_types == 0):
		json_codec_types = malloc(max_types * 4)
		json_codec_addresses = malloc(max_types * 4)
	assert1(json_codec_count < max_types)
	save_int(json_codec_types + json_codec_count * 4, type_index)
	save_int(json_codec_addresses + json_codec_count * 4, address)
	json_codec_count = json_codec_count + 1


void json_codec_unsupported(int t):
	diag_part(c"unsupported to_json/from_json field type: '")
	diag_part(type_get_name(t))
	int level = type_get_pointer_level(t)
	while (level > 0):
		diag_part(c"*")
		level = level - 1
	error(c"'")


# Value kind for the descriptor; errors out on unsupported types.
# 1 int (signed), 2 bool, 3 char*, 4 string, 5 struct, 6 list.
int json_codec_kind(int t):
	t = type_unqualified(t)
	if (type_is_string(t)):
		return 4
	if (type_is_char_pointer(t)):
		return 3
	if (type_is_list(t)):
		json_codec_kind(type_list_element_type(t))
		return 6
	if (type_is_map(t) | type_is_set(t)):
		json_codec_unsupported(t)
	if (type_is_array(t) | type_is_slice(t)):
		json_codec_unsupported(t)
	if (type_get_pointer_level(t) > 0):
		json_codec_unsupported(t)
	if (type_float_kind(t)):
		json_codec_unsupported(t)
	if (type_get_kind(t) == type_kind_union):
		json_codec_unsupported(t)
	if (type_num_args(t) > 0):
		return 5
	if (t == type_unqualified(bool_type)):
		return 2
	int size = type_get_size(t)
	if ((size == 1) | (size == 2) | (size == 4) | (size == 8)):
		return 1
	json_codec_unsupported(t)
	return 0


# Descriptor 'size' word: storage width for ints/bools, element slot size
# for lists (mirrors list_element_slot_size so decode can rebuild lists).
int json_codec_size(int t, int kind):
	t = type_unqualified(t)
	if (kind == 6):
		return list_element_slot_size(type_list_element_type(t))
	if ((kind == 3) | (kind == 4)):
		return word_size
	return type_get_size(t)


# Emit descriptors for any struct types nested under t (each in its own
# jumped-over blob) so the enclosing descriptor can reference them.
void json_codec_ensure_nested(int t):
	t = type_unqualified(t)
	int kind = json_codec_kind(t)
	if (kind == 5):
		json_codec_descriptor(t)
	if (kind == 6):
		json_codec_ensure_nested(type_list_element_type(t))


# Emit a 3-word value descriptor (kind, size, aux) inside the current
# blob and return its absolute address. List elements recurse.
int json_codec_emit_value_desc(int t):
	t = type_unqualified(t)
	int kind = json_codec_kind(t)
	int aux = 0
	if (kind == 5):
		aux = json_codec_cache_lookup(type_canonical(t))
	if (kind == 6):
		aux = json_codec_emit_value_desc(type_list_element_type(t))
	int address = code_offset + codepos
	emit_target_word(kind)
	emit_target_word(json_codec_size(t, kind))
	emit_target_word(aux)
	return address


# Emit (or reuse) the descriptor blob for a struct type and return its
# absolute address. The blob sits in the instruction stream behind an
# unconditional jump, so emitting mid-expression is safe.
int json_codec_descriptor(int struct_type):
	struct_type = type_canonical(type_unqualified(struct_type))
	int cached = json_codec_cache_lookup(struct_type)
	if (cached):
		return cached
	int n = type_num_args(struct_type)

	# Nested struct descriptors first, each in its own blob, so this
	# blob can embed their addresses
	int i = 0
	while (i < n):
		json_codec_ensure_nested(type_get_field_type_at(struct_type, i))
		i = i + 1

	jmp_int32(1337030)
	int p = codepos

	# Field name strings
	char* name_addresses = malloc(n * 4)
	i = 0
	while (i < n):
		char* name = type_get_field_name_at(struct_type, i)
		save_int(name_addresses + i * 4, code_offset + codepos)
		emit(strlen(name) + 1, name)
		i = i + 1

	# Value descriptors for list fields
	char* aux_addresses = malloc(n * 4)
	i = 0
	while (i < n):
		int field_type = type_unqualified(type_get_field_type_at(struct_type, i))
		int kind = json_codec_kind(field_type)
		int aux = 0
		if (kind == 5):
			aux = json_codec_cache_lookup(type_canonical(field_type))
		if (kind == 6):
			aux = json_codec_emit_value_desc(type_list_element_type(field_type))
		save_int(aux_addresses + i * 4, aux)
		i = i + 1

	# The struct descriptor itself
	int desc_address = code_offset + codepos
	emit_target_word(n)
	emit_target_word(type_get_size(struct_type))
	i = 0
	while (i < n):
		int field_type = type_unqualified(type_get_field_type_at(struct_type, i))
		int kind = json_codec_kind(field_type)
		emit_target_word(load_int(name_addresses + i * 4))
		emit_target_word(type_get_field_offset_at(struct_type, i))
		emit_target_word(kind)
		emit_target_word(json_codec_size(field_type, kind))
		emit_target_word(load_int(aux_addresses + i * 4))
		i = i + 1

	# The descriptor blob holds unaligned strings; realign so the jump lands
	# on an instruction boundary (a no-op on x86).
	be_align_code()
	be_branch_patch(p, codepos)
	free(name_addresses)
	free(aux_addresses)
	json_codec_cache_store(struct_type, desc_address)
	return desc_address


void json_codec_require_json_import(char* builtin_name):
	if (type_lookup(c"json_value") < 0):
		diag_part(builtin_name)
		error(c" requires 'import structures.json'")


# Backpatch chains for call sites emitted before structures/json_codec.w
# is imported. A symbol-table forward declaration would not survive
# function_definition's scope truncation (table_pos = n), so the chains
# live here and json_codec_finish_import() patches them once the module
# has defined the runtime symbols. Encoding matches the 'U' symbol
# chains: each mov-imm slot holds the previous slot's absolute address,
# code_offset ends the chain.
int json_codec_encode_chain
int json_codec_decode_chain


int json_codec_emit_chained_call_target(int head):
	if (head == 0):
		head = code_offset
	be_addr_slot_emit() /* mov $n,%eax (x86) / ldr-literal cell (arm64) */
	save_int(code + codepos - 4, head)
	return codepos + code_offset - 4


void json_codec_patch_chain(int head, char* fn_name):
	int v = sym_address(fn_name)
	if (head == 0):
		return;
	int i = head - code_offset
	while (i):
		int j = load_int(code + i) - code_offset
		save_int(code + i, v)
		i = j


# Call fn_name(descriptor, arg) with the argument already pushed at
# arg_slot; the json_value*/struct pointer result stays in eax.
void json_codec_emit_call(char* fn_name, int desc_address, int arg_slot):
	if (sym_lookup(fn_name) >= 0):
		sym_get_value(fn_name)
	else if (strcmp(fn_name, c"__w_json_encode") == 0):
		json_codec_encode_chain = json_codec_emit_chained_call_target(json_codec_encode_chain)
	else:
		json_codec_decode_chain = json_codec_emit_chained_call_target(json_codec_decode_chain)
	int s = stack_pos
	push_eax()
	stack_pos = stack_pos + 1
	mov_eax_int(desc_address)
	push_eax()
	stack_pos = stack_pos + 1
	hash_push_stack_slot(arg_slot)
	hash_call_finish(s)


# to_json(expr): 'to_json' is the current token. Leaves ')' current for
# primary_expr's trailing get_token(). Returns the json_value* type.
int json_to_json_expr():
	get_token()
	expect(c"(")
	int got = expression()
	if (peek(c")") == 0):
		error(c"')' expected in to_json")
	json_codec_require_json_import(c"to_json")
	got = promote(got)
	int t = type_unqualified(got)
	# A single-level struct pointer encodes what it points at
	if (type_get_pointer_level(t) == 1):
		int base = type_lookup_previous_pointer(t)
		if (base >= 0):
			if (type_num_args(base) > 0):
				t = type_unqualified(base)
	if (type_num_args(t) == 0):
		error(c"to_json argument must be a struct value or struct pointer")
	if (type_get_kind(t) == type_kind_union):
		error(c"to_json does not support unions")
	json_codec_needed = 1
	int base_stack = stack_pos
	push_eax()
	stack_pos = stack_pos + 1
	int arg_slot = stack_pos
	int desc_address = json_codec_descriptor(t)
	json_codec_emit_call(c"__w_json_encode", desc_address, arg_slot)
	be_pop(stack_pos - base_stack)
	stack_pos = base_stack
	return type_value(type_get_next_pointer(type_lookup(c"json_value")))


# from_json(T, expr): 'from_json' is the current token. Leaves ')'
# current for primary_expr's trailing get_token(). Returns T* (0 at
# runtime when the value does not decode).
int json_from_json_expr():
	get_token()
	expect(c"(")
	json_codec_require_json_import(c"from_json")
	int target_type = type_name()
	int t = type_unqualified(target_type)
	if ((type_num_args(t) == 0) | (type_get_pointer_level(t) > 0)):
		error(c"from_json target must be a struct type")
	if (type_get_kind(t) == type_kind_union):
		error(c"from_json does not support unions")
	expect(c",")
	json_codec_needed = 1
	int desc_address = json_codec_descriptor(t)
	int got = expression()
	if (peek(c")") == 0):
		error(c"')' expected in from_json")
	got = promote(got)
	int want = type_get_next_pointer(type_lookup(c"json_value"))
	if (types_compatible_with_expression(want, got) == 0):
		warn_type_mismatch(c"from_json value", want, got)
	int base_stack = stack_pos
	push_eax()
	stack_pos = stack_pos + 1
	int arg_slot = stack_pos
	json_codec_emit_call(c"__w_json_decode", desc_address, arg_slot)
	be_pop(stack_pos - base_stack)
	stack_pos = base_stack
	return type_value(type_get_next_pointer(t))


# Deferred on-demand import of the codec runtime. Called by the drivers
# (link_impl, the REPL) at a top-level boundary once compilation of the
# user's files is done; import_module de-duplicates repeat calls. After
# the module has defined the runtime symbols, resolve the call sites
# that were emitted before the import.
void json_codec_finish_import():
	if (json_codec_needed == 0):
		return;
	import_module(c"structures.json_codec")
	json_codec_patch_chain(json_codec_encode_chain, c"__w_json_encode")
	json_codec_patch_chain(json_codec_decode_chain, c"__w_json_decode")
	json_codec_encode_chain = 0
	json_codec_decode_chain = 0
