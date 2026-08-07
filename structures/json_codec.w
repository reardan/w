/*
Runtime for the compiler-generated to_json/from_json builtins.

The compiler monomorphizes a codec per struct type: at the first use site
it emits a static descriptor blob (behind an unconditional jump in the
code stream; into the data segment on wasm) and lowers the builtin to a
call into this module.
This file is only imported into programs that actually use the builtins
(the driver injects the import on demand), so ordinary programs pay
nothing for it.

Descriptor layout (target-word entries, absolute addresses):

struct descriptor:
	word 0: field count
	word 1: struct size in bytes
	5 words per field:
		name    char* address of the field name
		offset  byte offset of the field inside the struct
		kind    value kind, see below
		size    int/bool: storage width in bytes (1/2/4/8)
		        list: element slot size in bytes
		        map: value size in bytes (what __w_map_new takes)
		        otherwise unused
		aux     struct: nested struct descriptor address
		        list: element value-descriptor address
		        map: map-descriptor address
		        otherwise 0

value descriptor (list elements): 3 words: kind, size, aux (same meaning).

map descriptor (map fields): 4 words: key kind (the __w_hash_key_*
constant __w_map_new expects: 2 char*, 3 string), then value kind,
value size, value aux with the same meaning as a value descriptor.

Kinds: 1 int (signed), 2 bool, 3 char*, 4 string, 5 struct, 6 list,
7 float (float32), 8 map (char* or string keys), 9 float64
(8-byte-word targets only; the compiler rejects the type elsewhere).

Encoding notes:
- null char*, string, list, and map fields encode as JSON null and
  decode back to 0 (an empty map encodes as {} and decodes to an empty
  map).
- string fields are copied through a NUL-terminated buffer, so embedded
  NUL bytes truncate (structures/json.w strings are C strings). The
  same applies to string-typed map keys.
- float fields are float32 or, on 8-byte-word targets, float64 (their
  json_value carries the raw float64 bits, see structures/json.w, so
  encode -> decode round trips are bit-exact); decode also accepts a
  JSON integer for either (JavaScript's JSON.stringify writes whole
  doubles with no fraction part) and converts it, and a float64 field
  additionally accepts a float32-only value (e.g. one built with
  json_float) by widening. float16 fields — and float64 fields on
  4-byte-word targets, where the type itself is a compile error — are
  rejected at compile time.
- map fields encode as JSON objects in insertion order and decode in
  the source object's member order.
- decode is strict: a missing member or a type mismatch fails the whole
  decode and __w_json_decode returns 0 so callers can report bad input
  (e.g. respond with JSON-RPC -32602 invalid params). Interior
  allocations made before the failing field are not individually freed
  (a failing map decode frees the map's own keys and storage, but not
  values decoded into it before the failure).
*/
import lib.lib
import structures.json
# The list codec walks __w_list directly and the map codec walks
# __w_hash_table. The compiler auto-imports both modules into every
# batch-compiled program (the imports de-duplicate), but the REPL does
# not preload them.
import structures.w_list
import structures.hash_table


json_value* __w_json_encode_field(int kind, int size, int aux, char* addr);
int __w_json_decode_field(int kind, int size, int aux, json_value* v, char* addr);
int __w_json_decode_into(int desc, json_value* value, char* out);


int __w_json_desc_word(int desc, int i):
	int* d = cast(int*, desc)
	return d[i]


int __w_json_load_pointer(char* addr):
	int* p = cast(int*, addr)
	return p[0]


void __w_json_store_pointer(char* addr, int value):
	int* p = cast(int*, addr)
	p[0] = value


# Encode the struct bytes at addr as a JSON object.
json_value* __w_json_encode(int desc, char* addr):
	json_value* obj = json_object()
	int n = __w_json_desc_word(desc, 0)
	int i = 0
	while (i < n):
		int f = 2 + 5 * i
		char* name = cast(char*, __w_json_desc_word(desc, f))
		int offset = __w_json_desc_word(desc, f + 1)
		int kind = __w_json_desc_word(desc, f + 2)
		int size = __w_json_desc_word(desc, f + 3)
		int aux = __w_json_desc_word(desc, f + 4)
		json_object_set(obj, name, __w_json_encode_field(kind, size, aux, addr + offset))
		i = i + 1
	return obj


# NUL-terminated copy of a length-prefixed string descriptor's bytes
# (embedded NUL bytes truncate; the caller owns the copy).
char* __w_json_cstr_from_string(int s):
	char* descriptor = cast(char*, s)
	char* data = cast(char*, __w_json_load_pointer(descriptor))
	int length = __w_json_load_pointer(descriptor + __word_size__)
	char* copy = malloc(length + 1)
	int i = 0
	while (i < length):
		copy[i] = data[i]
		i = i + 1
	copy[length] = 0
	return copy


json_value* __w_json_encode_string(char* addr):
	int s = __w_json_load_pointer(addr)
	if (s == 0):
		return json_null()
	return json_string_take(__w_json_cstr_from_string(s))


json_value* __w_json_encode_list(int aux, char* addr):
	int raw = __w_json_load_pointer(addr)
	if (raw == 0):
		return json_null()
	__w_list* list = cast(__w_list*, raw)
	int ekind = __w_json_desc_word(aux, 0)
	int esize = __w_json_desc_word(aux, 1)
	int eaux = __w_json_desc_word(aux, 2)
	json_value* array = json_array()
	int i = 0
	while (i < list.length):
		json_array_push(array, __w_json_encode_field(ekind, esize, eaux, list.items + i * list.element_size))
		i = i + 1
	return array


# Encode a map field (key kind 2 or 3, see the map descriptor) as a
# JSON object in insertion order. char* keys pass straight through
# (json_object_set clones them); string keys go through a NUL-terminated
# copy.
json_value* __w_json_encode_map(int aux, char* addr):
	int raw = __w_json_load_pointer(addr)
	if (raw == 0):
		return json_null()
	__w_hash_table* table = cast(__w_hash_table*, raw)
	int vkind = __w_json_desc_word(aux, 1)
	int vsize = __w_json_desc_word(aux, 2)
	int vaux = __w_json_desc_word(aux, 3)
	json_value* obj = json_object()
	int cursor = __w_map_iter_begin(table)
	while (__w_map_iter_done(table, cursor) == 0):
		int key = __w_map_iter_key(table, cursor)
		json_value* member = __w_json_encode_field(vkind, vsize, vaux, __w_map_iter_value_addr(table, cursor))
		if (table.key_kind == __w_hash_key_string()):
			char* copy = __w_json_cstr_from_string(key)
			json_object_set(obj, copy, member)
			free(copy)
		else:
			json_object_set(obj, cast(char*, key), member)
		cursor = __w_map_iter_next(table, cursor)
	return obj


json_value* __w_json_encode_field(int kind, int size, int aux, char* addr):
	if (kind == 1):
		return json_int(__w_list_load_word(addr, size))
	if (kind == 2):
		return json_bool(__w_list_load_word(addr, size))
	if (kind == 3):
		char* text = cast(char*, __w_json_load_pointer(addr))
		if (text == 0):
			return json_null()
		return json_string(text)
	if (kind == 4):
		return __w_json_encode_string(addr)
	if (kind == 5):
		return __w_json_encode(aux, addr)
	if (kind == 6):
		return __w_json_encode_list(aux, addr)
	if (kind == 7):
		float* f = cast(float*, addr)
		return json_float(f[0])
	if (kind == 8):
		return __w_json_encode_map(aux, addr)
	if (kind == 9):
		# float64 (8-byte-word targets only): the slot word is the
		# value's raw bit pattern, carried into the json_value as-is
		return json_float64_from_bits(__w_list_load_word(addr, size))
	return json_null()


# Decode a JSON object into a freshly allocated, zeroed struct.
# Returns the struct bytes, or 0 when the value does not match.
char* __w_json_decode(int desc, json_value* value):
	if (value == 0):
		return 0
	if (value.type != json_type_object()):
		return 0
	int struct_size = __w_json_desc_word(desc, 1)
	char* out = malloc(struct_size)
	int i = 0
	while (i < struct_size):
		out[i] = 0
		i = i + 1
	if (__w_json_decode_into(desc, value, out) == 0):
		free(out)
		return 0
	return out


int __w_json_decode_into(int desc, json_value* value, char* out):
	if (value == 0):
		return 0
	if (value.type != json_type_object()):
		return 0
	int n = __w_json_desc_word(desc, 0)
	int i = 0
	while (i < n):
		int f = 2 + 5 * i
		char* name = cast(char*, __w_json_desc_word(desc, f))
		int offset = __w_json_desc_word(desc, f + 1)
		int kind = __w_json_desc_word(desc, f + 2)
		int size = __w_json_desc_word(desc, f + 3)
		int aux = __w_json_desc_word(desc, f + 4)
		if (json_object_has(value, name) == 0):
			return 0
		json_value* member = json_object_get(value, name)
		if (__w_json_decode_field(kind, size, aux, member, out + offset) == 0):
			return 0
		i = i + 1
	return 1


int __w_json_decode_list(int size, int aux, json_value* v, char* addr):
	if (v.type == json_type_null()):
		__w_json_store_pointer(addr, 0)
		return 1
	if (v.type != json_type_array()):
		return 0
	int ekind = __w_json_desc_word(aux, 0)
	int esize = __w_json_desc_word(aux, 1)
	int eaux = __w_json_desc_word(aux, 2)
	__w_list* list = __w_list_new(size)
	char* slot = malloc(size)
	int n = json_array_length(v)
	int i = 0
	while (i < n):
		int j = 0
		while (j < size):
			slot[j] = 0
			j = j + 1
		if (__w_json_decode_field(ekind, esize, eaux, json_array_get(v, i), slot) == 0):
			free(slot)
			__w_list_free(list)
			return 0
		__w_list_push_bytes(list, slot)
		i = i + 1
	free(slot)
	__w_json_store_pointer(addr, cast(int, list))
	return 1


# Store a decoded value slot into a map. Scalar values live in the slot
# as full words the way __w_map_set stores them (m[k] reads load the
# whole word back), so narrow ints re-load sign-extended from the slot
# the decoder narrowed them into; struct values copy their slot bytes.
void __w_json_map_store(__w_hash_table* table, int key, int vkind, int vsize, char* slot):
	if (vkind == 5):
		__w_map_set_bytes(table, key, slot)
	else if ((vkind == 1) || (vkind == 2) || (vkind == 7) || (vkind == 9)):
		__w_map_set(table, key, __w_list_load_word(slot, vsize))
	else:
		__w_map_set(table, key, __w_json_load_pointer(slot))


int __w_json_decode_map(int size, int aux, json_value* v, char* addr):
	if (v.type == json_type_null()):
		__w_json_store_pointer(addr, 0)
		return 1
	if (v.type != json_type_object()):
		return 0
	int key_kind = __w_json_desc_word(aux, 0)
	int vkind = __w_json_desc_word(aux, 1)
	int vsize = __w_json_desc_word(aux, 2)
	int vaux = __w_json_desc_word(aux, 3)
	__w_hash_table* table = __w_map_new(key_kind, size)
	int slot_size = __w_hash_slot_size(table)
	char* slot = malloc(slot_size)
	int ok = 1
	for char* member_key, json_value* member in v.object_values:
		if (ok):
			int j = 0
			while (j < slot_size):
				slot[j] = 0
				j = j + 1
			if (__w_json_decode_field(vkind, vsize, vaux, member, slot) == 0):
				ok = 0
			else if (key_kind == __w_hash_key_string()):
				# Temporary descriptor over the JSON key's bytes; the
				# map clones descriptor and bytes on insert.
				string skey = str_from_cstr(member_key)
				__w_json_map_store(table, cast(int, skey), vkind, vsize, slot)
				free(cast(char*, cast(int, skey)))
			else:
				__w_json_map_store(table, cast(int, member_key), vkind, vsize, slot)
	free(slot)
	if (ok == 0):
		__w_map_free(table)
		return 0
	__w_json_store_pointer(addr, cast(int, table))
	return 1


int __w_json_decode_field(int kind, int size, int aux, json_value* v, char* addr):
	if (v == 0):
		return 0
	if (kind == 1):
		if (v.type != json_type_int()):
			return 0
		__w_list_store_word(addr, size, v.int_value)
		return 1
	if (kind == 2):
		if (v.type != json_type_bool()):
			return 0
		__w_list_store_word(addr, size, v.int_value)
		return 1
	if (kind == 3):
		if (v.type == json_type_null()):
			__w_json_store_pointer(addr, 0)
			return 1
		if (v.type != json_type_string()):
			return 0
		__w_json_store_pointer(addr, cast(int, strclone(v.string_value)))
		return 1
	if (kind == 4):
		if (v.type == json_type_null()):
			__w_json_store_pointer(addr, 0)
			return 1
		if (v.type != json_type_string()):
			return 0
		__w_json_store_pointer(addr, cast(int, str_from_cstr(strclone(v.string_value))))
		return 1
	if (kind == 5):
		if (v.type != json_type_object()):
			return 0
		return __w_json_decode_into(aux, v, addr)
	if (kind == 6):
		return __w_json_decode_list(size, aux, v, addr)
	if (kind == 7):
		float* f = cast(float*, addr)
		if (v.type == json_type_float()):
			f[0] = v.float_value
			return 1
		if (v.type == json_type_int()):
			float converted = v.int_value
			f[0] = converted
			return 1
		return 0
	if (kind == 8):
		return __w_json_decode_map(size, aux, v, addr)
	if (kind == 9):
		# float64 (8-byte-word targets only): store the raw bit
		# pattern; a float32-only value widens and a JSON integer
		# converts, through the per-target helpers
		if (v.type == json_type_float()):
			if (v.has_float64):
				__w_list_store_word(addr, size, v.float64_bits)
			else:
				__w_list_store_word(addr, size, json_f64_from_float32(v.float_value))
			return 1
		if (v.type == json_type_int()):
			__w_list_store_word(addr, size, json_f64_from_int(v.int_value))
			return 1
		return 0
	return 0
