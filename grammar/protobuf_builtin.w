/*
Compiler support for protobuf messages (issue #16 stage 3,
docs/projects/protobuf.md §4.4 / §9): the contextual 'message'
declaration and the to_proto/from_proto/proto_descriptor builtins.

	import libs.extras.protobuf.message

	message Address:
		string city = 1

	message Person:
		string name = 1
		int32 id = 2
		Address home = 3
		repeated int32 scores = 4

	pb_bytes* wire = to_proto(p)
	Person* q = from_proto(Person, wire)        # 0 on malformed input
	Person* r = from_proto(Person, data, length)
	pb_message_desc* d = proto_descriptor(Person)

A message is an ordinary W struct (the type table records it like any
struct, so field access, sizeof, pointers and lists all work) plus a
side table holding each field's wire number and protobuf kind. Field
types use the proto3 scalar spellings and map to W storage the stage-1
runtime (libs/extras/protobuf/message.w) already reads:

	int32, sint32          int32
	uint32, fixed32        uint32
	sfixed32               int32
	float                  float32
	int64, sint64, sfixed64  int64 (8-byte-word targets only)
	uint64, fixed64        uint64  (8-byte-word targets only)
	double                 float64 (8-byte-word targets only)
	bool                   bool
	string, bytes          pb_bytes (explicit length: bytes may hold NULs)
	an enum type           the enum (encoded as int32)
	another message M      M*      (null = absent)
	repeated T             list[storage of T]; message elements by value

A message may refer to itself. Two messages that refer to each other
need a forward declaration, 'message Name' with no body, ahead of the
first. Each protobuf_descriptor call emits the descriptors of every
message it reaches in one blob with precomputed addresses, so cycles
resolve.

Like to_json (grammar/json_builtin.w) there is no per-message code: the
first to_proto/from_proto/proto_descriptor use of a message type emits
a static pb_message_desc blob behind a be_blob region, laid out exactly
like the runtime's pb_message_desc / pb_field_desc / pb_value_desc
structs, and the builtins lower to calls into the runtime
(pb_to_bytes / pb_from_bytes / pb_from_data). Decode is permissive
(proto3): absent fields keep their zero value and unknown field numbers
are skipped.

Unlike to_json the runtime is not imported on demand: a message
declaration needs the pb_bytes type at parse time, so 'import
libs.extras.protobuf.message' must already be in scope, and by then the
runtime functions are defined.

'message' is contextual (a user type or symbol named 'message' keeps
the identifier meaning), as are the field words inside a message body.

This file is compiled by the committed seed: only seed-understood syntax.
*/
void defhash_note(char* name, char* kind, int file_index, int line, int column, int start_offset, int end_offset);


# Side table: per message type, a malloc'd int block
# [field count, then per field: wire number, kind, element kind].
# Field order matches the struct's declaration order.
char* protobuf_message_types
char* protobuf_message_infos
int protobuf_message_count

# Emitted descriptor address per canonical message type index.
char* protobuf_desc_types
char* protobuf_desc_addresses
int protobuf_desc_count


# PB_KIND_* values (libs/extras/protobuf/message.w)
int protobuf_kind_int32():
	return 1


int protobuf_kind_int64():
	return 2


int protobuf_kind_uint32():
	return 3


int protobuf_kind_uint64():
	return 4


int protobuf_kind_sint32():
	return 5


int protobuf_kind_sint64():
	return 6


int protobuf_kind_bool():
	return 7


int protobuf_kind_fixed32():
	return 8


int protobuf_kind_fixed64():
	return 9


int protobuf_kind_string():
	return 10


int protobuf_kind_bytes():
	return 11


int protobuf_kind_message():
	return 12


int protobuf_kind_repeated():
	return 13


int protobuf_message_index(int type_index):
	type_index = type_canonical(type_unqualified(type_index))
	int i = 0
	while (i < protobuf_message_count):
		if (load_int(protobuf_message_types + i * 4) == type_index):
			return i
		i = i + 1
	return 0 - 1


int protobuf_is_message(int type_index):
	if (type_index < 0):
		return 0
	if (type_get_pointer_level(type_unqualified(type_index)) != 0):
		return 0
	return protobuf_message_index(type_index) >= 0


char* protobuf_message_info(int type_index):
	int i = protobuf_message_index(type_index)
	if (i < 0):
		return 0
	return cast(char*, load_ptr(protobuf_message_infos + i * __word_size__))


void protobuf_message_store(int type_index, char* info):
	int max_messages = 400
	if (protobuf_message_types == 0):
		protobuf_message_types = malloc(max_messages * 4)
		protobuf_message_infos = malloc(max_messages * __word_size__)
	type_index = type_canonical(type_index)
	int i = protobuf_message_index(type_index)
	if (i < 0):
		assert1(protobuf_message_count < max_messages)
		i = protobuf_message_count
		protobuf_message_count = protobuf_message_count + 1
	save_int(protobuf_message_types + i * 4, type_index)
	save_ptr(protobuf_message_infos + i * __word_size__, cast(int, info))


int protobuf_require_runtime(char* what):
	int t = type_lookup(c"pb_bytes")
	if ((t < 0) || (type_lookup(c"pb_message_desc") < 0)):
		error2(what, c" requires 'import libs.extras.protobuf.message'")
	return t


int protobuf_lookup_builtin_type(char* name):
	int t = type_lookup(name)
	assert1(t >= 0)
	return t


void protobuf_require_wide_word(char* name):
	if (word_size != 8):
		error3(c"protobuf field type '", name, c"' needs a 64-bit target (x64 or arm64)")


# Scalar protobuf kind for a field type word, or 0 when the word is not
# a scalar spelling (it may still name an enum or another message).
int protobuf_scalar_kind(char* name):
	if (strcmp(name, c"int32") == 0):
		return protobuf_kind_int32()
	if (strcmp(name, c"sint32") == 0):
		return protobuf_kind_sint32()
	if (strcmp(name, c"uint32") == 0):
		return protobuf_kind_uint32()
	if (strcmp(name, c"fixed32") == 0):
		return protobuf_kind_fixed32()
	if (strcmp(name, c"int64") == 0):
		return protobuf_kind_int64()
	if (strcmp(name, c"sint64") == 0):
		return protobuf_kind_sint64()
	if (strcmp(name, c"uint64") == 0):
		return protobuf_kind_uint64()
	if (strcmp(name, c"fixed64") == 0):
		return protobuf_kind_fixed64()
	if (strcmp(name, c"bool") == 0):
		return protobuf_kind_bool()
	if (strcmp(name, c"string") == 0):
		return protobuf_kind_string()
	if (strcmp(name, c"bytes") == 0):
		return protobuf_kind_bytes()
	# float/sfixed32 and double/sfixed64 share FIXED32/FIXED64's wire
	# form (raw little-endian bits); only the W storage type differs.
	if ((strcmp(name, c"float") == 0) || (strcmp(name, c"sfixed32") == 0)):
		return protobuf_kind_fixed32()
	if ((strcmp(name, c"double") == 0) || (strcmp(name, c"sfixed64") == 0)):
		return protobuf_kind_fixed64()
	return 0


# W storage type for a scalar protobuf kind.
int protobuf_scalar_storage(int kind, char* name):
	if (strcmp(name, c"float") == 0):
		return protobuf_lookup_builtin_type(c"float32")
	if (strcmp(name, c"double") == 0):
		protobuf_require_wide_word(name)
		return protobuf_lookup_builtin_type(c"float64")
	if (strcmp(name, c"sfixed32") == 0):
		return protobuf_lookup_builtin_type(c"int32")
	if (strcmp(name, c"sfixed64") == 0):
		protobuf_require_wide_word(name)
		return protobuf_lookup_builtin_type(c"int64")
	if ((kind == protobuf_kind_int32()) || (kind == protobuf_kind_sint32())):
		return protobuf_lookup_builtin_type(c"int32")
	if ((kind == protobuf_kind_uint32()) || (kind == protobuf_kind_fixed32())):
		return protobuf_lookup_builtin_type(c"uint32")
	if ((kind == protobuf_kind_int64()) || (kind == protobuf_kind_sint64())):
		protobuf_require_wide_word(name)
		return protobuf_lookup_builtin_type(c"int64")
	if ((kind == protobuf_kind_uint64()) || (kind == protobuf_kind_fixed64())):
		protobuf_require_wide_word(name)
		return protobuf_lookup_builtin_type(c"uint64")
	if (kind == protobuf_kind_bool()):
		return bool_type
	return protobuf_lookup_builtin_type(c"pb_bytes")


# Parses one field line of a message body (the field-type word is the
# current token) and appends it to the struct and to info. Returns the
# wire number.
int protobuf_message_field(int message_type, char* info, int field_index):
	int repeated = 0
	if (peek(c"repeated") && (nextc == ' ')):
		get_token()
		repeated = 1
	char* type_word = strclone(token)
	int kind = protobuf_scalar_kind(type_word)
	int elem_kind = 0
	int storage = 0
	if (kind):
		storage = protobuf_scalar_storage(kind, type_word)
	else:
		int named = type_lookup(type_word)
		if (named < 0):
			error3(c"unknown protobuf field type '", type_word, c"'")
		# The message being declared may refer to itself (a tree
		# node's children): the singular form is a pointer, the
		# repeated form a list, so neither needs the finished size.
		int is_self = type_canonical(named) == type_canonical(message_type)
		if (type_get_kind(named) == type_kind_enum):
			kind = protobuf_kind_int32()
			storage = named
		else if (is_self || protobuf_is_message(named)):
			kind = protobuf_kind_message()
			storage = type_get_next_pointer(named)
			if (repeated):
				storage = named
		else:
			error3(c"unsupported protobuf field type '", type_word, c"'")
	if (repeated):
		elem_kind = kind
		kind = protobuf_kind_repeated()
		storage = type_get_list(storage)
	get_token()
	char* field_name = strclone(token)
	get_token()
	if (accept(c"=") == 0):
		error3(c"protobuf field '", field_name, c"' needs a field number: '= N'")
	int number = 0
	if ((token[0] == '0') && (token[1] == 'x')):
		int_literal_width_check()
		number = from_hex(token + 2)
	else:
		if ((token[0] < '0') || (token[0] > '9')):
			error(c"protobuf field number must be an integer literal")
		int_literal_decimal_check()
		number = atoi(token)
	if ((number < 1) || (number > 536870911)):
		error(c"protobuf field number must be between 1 and 536870911")
	if ((number >= 19000) && (number <= 19999)):
		error(c"protobuf field numbers 19000-19999 are reserved")
	int i = 0
	while (i < field_index):
		if (load_int(info + 4 + i * 12) == number):
			error3(c"duplicate protobuf field number in message '", type_get_name(message_type), c"'")
		i = i + 1
	get_token()
	type_add_arg(message_type, field_name, storage)
	save_int(info + 4 + field_index * 12, number)
	save_int(info + 8 + field_index * 12, kind)
	save_int(info + 12 + field_index * 12, elem_kind)
	return number


# 'message Name:' followed by an indented field list. Returns 1 when a
# message declaration was parsed.
int message_declaration():
	if (peek(c"message") == 0):
		return 0
	if ((type_lookup(token) >= 0) || (sym_lookup(token) >= 0)):
		return 0
	if (nextc != ' '):
		return 0
	int defhash_start = token_start_offset
	get_token()
	protobuf_require_runtime(c"message declaration")
	int start_tab_level = tab_level
	char* defhash_name = strclone(token)
	int defhash_line = diag_token_line
	int defhash_column = diag_token_column
	int type_index = type_lookup(token)
	int forward_declared = 0
	if (type_index >= 0):
		char* existing = protobuf_message_info(type_index)
		if (existing != 0):
			forward_declared = load_int(existing) < 0
	if (type_index < 0):
		type_index = type_push_size(strclone(token), 0)
	else if (forward_declared == 0):
		type_reset_for_redefinition(type_index, 0)
	type_set_decl_location(type_index, decl_file_index(), diag_token_line, diag_token_column)
	if (forward_declared == 0):
		sym_declare_global(token, type_index, 1)
	get_token()
	# 'message Name' alone is a forward declaration, so two messages
	# can refer to each other: fields of a forward-declared message
	# type are pointers or lists, which need no size yet.
	if (accept(c":") == 0):
		if (forward_declared == 0):
			char* forward = malloc(4)
			save_int(forward, 0 - 1)
			protobuf_message_store(type_index, forward)
		return 1
	int max_fields = 256
	char* info = malloc(4 + max_fields * 12)
	int n = 0
	while (tab_level > start_tab_level):
		if (n >= max_fields):
			error(c"too many fields in protobuf message")
		protobuf_message_field(type_index, info, n)
		n = n + 1
		pointer_indirection = 0
	save_int(info, n)
	protobuf_message_store(type_index, info)
	defhash_note(defhash_name, c"message", decl_file_index(), defhash_line, defhash_column, defhash_start, token_start_offset)
	return 1


int protobuf_desc_lookup(int type_index):
	int i = 0
	while (i < protobuf_desc_count):
		if (load_int(protobuf_desc_types + i * 4) == type_index):
			return load_int(protobuf_desc_addresses + i * 4)
		i = i + 1
	return 0


void protobuf_desc_store(int type_index, int address):
	int max_types = 400
	if (protobuf_desc_types == 0):
		protobuf_desc_types = malloc(max_types * 4)
		protobuf_desc_addresses = malloc(max_types * 4)
	assert1(protobuf_desc_count < max_types)
	save_int(protobuf_desc_types + protobuf_desc_count * 4, type_index)
	save_int(protobuf_desc_addresses + protobuf_desc_count * 4, address)
	protobuf_desc_count = protobuf_desc_count + 1


# The message type a MESSAGE or repeated-MESSAGE field refers to.
int protobuf_field_message_type(int field_type, int kind):
	field_type = type_unqualified(field_type)
	if (kind == protobuf_kind_repeated()):
		return type_list_element_type(field_type)
	return type_lookup_previous_pointer(field_type)


# Messages whose descriptors the current protobuf_descriptor call will
# emit, in emission order.
char* protobuf_pending_types
int protobuf_pending_count


int protobuf_is_pending(int type_index):
	int i = 0
	while (i < protobuf_pending_count):
		if (load_int(protobuf_pending_types + i * 4) == type_index):
			return 1
		i = i + 1
	return 0


# Adds message_type and every message it reaches that has no descriptor
# yet (a message may reach itself, directly or through others).
void protobuf_collect_pending(int message_type):
	message_type = type_canonical(type_unqualified(message_type))
	if (protobuf_desc_lookup(message_type)):
		return;
	if (protobuf_is_pending(message_type)):
		return;
	char* info = protobuf_message_info(message_type)
	if (info == 0):
		error3(c"'", type_get_name(message_type), c"' is not a protobuf message")
	if (load_int(info) < 0):
		error3(c"protobuf message '", type_get_name(message_type), c"' is declared but never defined")
	assert1(protobuf_pending_count < 400)
	save_int(protobuf_pending_types + protobuf_pending_count * 4, message_type)
	protobuf_pending_count = protobuf_pending_count + 1
	int n = load_int(info)
	int i = 0
	while (i < n):
		int kind = load_int(info + 8 + i * 12)
		int elem_kind = load_int(info + 12 + i * 12)
		if ((kind == protobuf_kind_message()) || (elem_kind == protobuf_kind_message())):
			protobuf_collect_pending(protobuf_field_message_type(type_get_field_type_at(message_type, i), kind))
		i = i + 1


int protobuf_repeated_count(char* info):
	int n = load_int(info)
	int r = 0
	int i = 0
	while (i < n):
		if (load_int(info + 8 + i * 12) == protobuf_kind_repeated()):
			r = r + 1
		i = i + 1
	return r


# Words before a message's pb_message_desc header inside its section:
# one pb_value_desc per repeated field, then the pb_field_desc array.
int protobuf_section_prefix_words(char* info):
	return protobuf_repeated_count(info) * 2 + load_int(info) * 4


# Emits one message's section; every descriptor it references already
# has its (possibly not yet emitted) address in the cache. Layout
# (target words), matching the runtime structs: pb_value_desc {kind,
# aux} per repeated field, then the pb_field_desc {number, kind, offset,
# aux} array sorted by wire number (deterministic encode order), then
# pb_message_desc {field_count, fields, struct_size}.
void protobuf_emit_section(int message_type):
	char* info = protobuf_message_info(message_type)
	int n = load_int(info)

	# Per-field aux words: nested descriptor for MESSAGE, a value
	# descriptor for REPEATED (its aux is the nested descriptor for
	# message elements, or the element width for bool, whose W storage
	# is one byte).
	char* aux_words = malloc(n * 4 + 4)
	int i = 0
	while (i < n):
		int field_type = type_get_field_type_at(message_type, i)
		int kind = load_int(info + 8 + i * 12)
		int elem_kind = load_int(info + 12 + i * 12)
		int aux = 0
		if (kind == protobuf_kind_message()):
			aux = protobuf_desc_lookup(type_canonical(protobuf_field_message_type(field_type, kind)))
		if (kind == protobuf_kind_repeated()):
			int elem_aux = 0
			if (elem_kind == protobuf_kind_message()):
				elem_aux = protobuf_desc_lookup(type_canonical(protobuf_field_message_type(field_type, kind)))
			if (elem_kind == protobuf_kind_bool()):
				elem_aux = type_get_size(bool_type)
			aux = code_offset + codepos
			emit_target_word(elem_kind)
			emit_target_word(elem_aux)
		save_int(aux_words + i * 4, aux)
		i = i + 1

	# Field array, ascending wire number (selection over the unsorted
	# declaration order; n is small).
	int fields_address = code_offset + codepos
	int last = 0
	int emitted = 0
	while (emitted < n):
		int best = 0 - 1
		int best_number = 0
		i = 0
		while (i < n):
			int number = load_int(info + 4 + i * 12)
			if (number > last):
				if ((best < 0) || (number < best_number)):
					best = i
					best_number = number
			i = i + 1
		emit_target_word(best_number)
		emit_target_word(load_int(info + 8 + best * 12))
		emit_target_word(type_get_field_offset_at(message_type, best))
		emit_target_word(load_int(aux_words + best * 4))
		last = best_number
		emitted = emitted + 1

	# struct_size is rounded up to whole words: repeated message
	# elements live by value in list slots of that size
	# (list_element_slot_size), and the runtime sizes them from here.
	assert1(protobuf_desc_lookup(message_type) == code_offset + codepos)
	emit_target_word(n)
	emit_target_word(fields_address)
	emit_target_word(type_stack_words(message_type) << word_size_log2)
	free(aux_words)


# Emit (or reuse) the descriptor for a message type and return its
# absolute address. Every message it reaches that has no descriptor yet
# goes into the same be_blob region (jumped over on the native targets,
# data segment on wasm, so emitting mid-expression is safe). Section
# sizes are known up front, so each descriptor's address is cached
# before any section is written, which is what lets messages refer to
# themselves or to each other.
int protobuf_descriptor(int message_type):
	message_type = type_canonical(type_unqualified(message_type))
	int cached = protobuf_desc_lookup(message_type)
	if (cached):
		return cached
	if (protobuf_pending_types == 0):
		protobuf_pending_types = malloc(400 * 4)
	protobuf_pending_count = 0
	protobuf_collect_pending(message_type)

	int p = be_blob_begin()
	int address = code_offset + codepos
	int i = 0
	while (i < protobuf_pending_count):
		int t = load_int(protobuf_pending_types + i * 4)
		char* info = protobuf_message_info(t)
		int prefix = protobuf_section_prefix_words(info) * word_size
		protobuf_desc_store(t, address + prefix)
		address = address + prefix + 3 * word_size
		i = i + 1
	i = 0
	while (i < protobuf_pending_count):
		protobuf_emit_section(load_int(protobuf_pending_types + i * 4))
		i = i + 1
	be_blob_end(p)
	protobuf_pending_count = 0
	return protobuf_desc_lookup(message_type)


# Call fn_name(descriptor, stacked args...) : the arguments are already
# pushed at arg_slot .. arg_slot + arg_count - 1; the result stays in eax.
void protobuf_emit_call(char* fn_name, int desc_address, int arg_slot, int arg_count):
	if (sym_lookup(fn_name) < 0):
		error3(c"protobuf runtime function '", fn_name, c"' is not defined; import libs.extras.protobuf.message")
	int s = rt_call_begin(fn_name)
	push_slot_int(desc_address)
	int i = 0
	while (i < arg_count):
		push_slot_copy(arg_slot + i)
		i = i + 1
	rt_call_end(s)


# The message type named by a message value or single-level pointer
# expression type, or an error.
int protobuf_message_of_expression(int t):
	t = type_unqualified(t)
	if (type_get_pointer_level(t) == 1):
		int base = type_lookup_previous_pointer(t)
		if (base >= 0):
			if (protobuf_is_message(base)):
				return base
	if (protobuf_is_message(t)):
		return t
	error(c"to_proto argument must be a protobuf message value or message pointer")
	return 0


# to_proto(expr): 'to_proto' is the current token. Leaves ')' current
# for primary_expr's trailing get_token(). Returns pb_bytes*.
int protobuf_to_proto_expr():
	get_token()
	expect(c"(")
	int got = expression()
	if (peek(c")") == 0):
		error(c"')' expected in to_proto")
	int bytes_type = protobuf_require_runtime(c"to_proto")
	got = promote(got)
	int t = protobuf_message_of_expression(got)
	int base_stack = stack_pos
	int arg_slot = push_slot()
	int desc_address = protobuf_descriptor(t)
	protobuf_emit_call(c"pb_to_bytes", desc_address, arg_slot, 1)
	pop_to(base_stack)
	return type_value(type_get_next_pointer(bytes_type))


# from_proto(T, bytes) / from_proto(T, data, length): 'from_proto' is
# the current token. Leaves ')' current. Returns T* (0 at runtime when
# the input is malformed).
int protobuf_from_proto_expr():
	get_token()
	expect(c"(")
	int bytes_type = protobuf_require_runtime(c"from_proto")
	int target_type = type_name()
	int t = type_unqualified(target_type)
	if (protobuf_is_message(t) == 0):
		error(c"from_proto target must be a protobuf message type")
	expect(c",")
	int desc_address = protobuf_descriptor(t)
	int base_stack = stack_pos
	int got = promote(expression())
	int arg_slot = push_slot()
	char* fn_name = c"pb_from_bytes"
	int arg_count = 1
	if (accept(c",")):
		int want_data = type_get_next_pointer(protobuf_lookup_builtin_type(c"char"))
		if (types_compatible_with_expression(want_data, got) == 0):
			warn_type_mismatch(c"from_proto data", want_data, got)
		promote(expression())
		push_slot()
		fn_name = c"pb_from_data"
		arg_count = 2
	else:
		int want = type_get_next_pointer(bytes_type)
		if (types_compatible_with_expression(want, got) == 0):
			warn_type_mismatch(c"from_proto value", want, got)
	if (peek(c")") == 0):
		error(c"')' expected in from_proto")
	protobuf_emit_call(fn_name, desc_address, arg_slot, arg_count)
	pop_to(base_stack)
	return type_value(type_get_next_pointer(t))


# proto_descriptor(T): the message's pb_message_desc*, for the runtime's
# lower-level API (pb_decode's wresult errors, pb_free_message, ...).
int protobuf_descriptor_expr():
	get_token()
	expect(c"(")
	protobuf_require_runtime(c"proto_descriptor")
	int t = type_unqualified(type_name())
	if (protobuf_is_message(t) == 0):
		error(c"proto_descriptor argument must be a protobuf message type")
	if (peek(c")") == 0):
		error(c"')' expected in proto_descriptor")
	int desc_address = protobuf_descriptor(t)
	mov_eax_int(desc_address)
	return type_value(type_get_next_pointer(type_lookup(c"pb_message_desc")))
