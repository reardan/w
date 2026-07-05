/*
Runtime for the compiler-generated to_json/from_json builtins.

The compiler monomorphizes a codec per struct type: at the first use site
it emits a static descriptor blob into the code stream (behind an
unconditional jump) and lowers the builtin to a call into this module.
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
		        otherwise unused
		aux     struct: nested struct descriptor address
		        list: element value-descriptor address
		        otherwise 0

value descriptor (list elements): 3 words: kind, size, aux (same meaning).

Kinds: 1 int (signed), 2 bool, 3 char*, 4 string, 5 struct, 6 list.

Encoding notes:
- null char*, string, and list fields encode as JSON null and decode
  back to 0.
- string fields are copied through a NUL-terminated buffer, so embedded
  NUL bytes truncate (structures/json.w strings are C strings).
- decode is strict: a missing member or a type mismatch fails the whole
  decode and __w_json_decode returns 0 so callers can report bad input
  (e.g. respond with JSON-RPC -32602 invalid params). Interior
  allocations made before the failing field are not individually freed.
*/
import lib.lib
import structures.json
# The list codec walks __w_list directly. The compiler auto-imports this
# module into every batch-compiled program (the import de-duplicates),
# but the REPL does not preload it.
import structures.w_list


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


json_value* __w_json_encode_string(char* addr):
	int s = __w_json_load_pointer(addr)
	if (s == 0):
		return json_null()
	char* descriptor = cast(char*, s)
	char* data = cast(char*, __w_json_load_pointer(descriptor))
	int length = __w_json_load_pointer(descriptor + __word_size__)
	char* copy = malloc(length + 1)
	int i = 0
	while (i < length):
		copy[i] = data[i]
		i = i + 1
	copy[length] = 0
	return json_string_take(copy)


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
	return 0
