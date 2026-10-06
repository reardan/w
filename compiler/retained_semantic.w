# Independently owned semantic records. IDs are session-local, append-only,
# and survive compiler symbol/type table reuse until checkpoint rollback.
import lib.lib

struct retained_field:
	char* name
	int type
	int offset

struct retained_constant:
	char* name
	int value

struct retained_type:
	int source
	char* name
	char* file
	int line
	int column
	int kind
	int size
	int pointer_level
	int target
	int return_type
	int array_length
	list[retained_field*] fields
	list[int] parameters
	list[retained_constant*] constants
	int origin
	int origin_target
	int origin_return
	int origin_parameters
	int building
	# Debug file index of file; equal indices name equal paths.
	int file_index

struct retained_binding:
	char* key
	char* name
	char* file
	int line
	int column
	int scope
	int slot
	int source
	int owner
	int type
	int return_type
	int origin
	int linkage
	list[int] parameters
	# Previous binding with the same raw symbol offset, newest first. The
	# chain replaces a scan of every earlier binding when a definition
	# looks for the forward declaration it completes; rollback pops LIFO.
	int origin_previous

list[retained_type*] retained_types
list[retained_binding*] retained_bindings
map[int, int] retained_type_cache
map[char*, int] retained_binding_cache
# Newest binding per raw symbol offset; heads of origin_previous chains.
map[int, int] retained_binding_origins

# Scratch lookup key for retained_binding_note; a new binding owns a copy.
char* retained_key_buffer
int retained_key_capacity

# Session-owned interned spellings. Names, files and type spellings repeat
# across hundreds of thousands of records; each record borrows one copy.
# Interned text is never retracted by rollback (no ID refers to it), so a
# rolled-back record needs no string frees; retained_semantic_clear frees it.
map[char*, int] retained_intern_index
list[char*] retained_interned
# Direct-mapped front cache: caller pointer -> interned copy. A hit is
# confirmed by comparing the text, so a recycled caller pointer is harmless.
const int retained_intern_slots = 1024
int* retained_intern_callers
int* retained_intern_copies


char* retained_intern(char* text):
	if (text == 0): return 0
	if (retained_intern_index == 0):
		retained_intern_index = new map[char*, int]
		retained_interned = new list[char*]
		retained_intern_callers = cast(int*, malloc(retained_intern_slots * __word_size__))
		retained_intern_copies = cast(int*, malloc(retained_intern_slots * __word_size__))
		for i in range(retained_intern_slots):
			retained_intern_callers[i] = 0
			retained_intern_copies[i] = 0
	int slot = (cast(int, text) >> 3) & (retained_intern_slots - 1)
	char* cached = cast(char*, retained_intern_copies[slot])
	if ((retained_intern_callers[slot] == cast(int, text)) && (strcmp(cached, text) == 0)): return cached
	char* copy = 0
	int id = retained_intern_index.get(text, -1)
	if (id >= 0): copy = retained_interned[id]
	else:
		copy = strclone(text)
		retained_intern_index[text] = retained_interned.length
		retained_interned.push(copy)
	retained_intern_callers[slot] = cast(int, text)
	retained_intern_copies[slot] = cast(int, copy)
	return copy


void retained_semantic_invalidate():
	if (retained_type_cache != 0): retained_type_cache.free()
	retained_type_cache = 0


void retained_semantic_rollback(int types, int bindings):
	retained_semantic_invalidate()
	# Remove retracted names from the canonical index; surviving bindings
	# retain their IDs. The map owns its own copies of the lookup keys.
	if (retained_bindings != 0):
		while (retained_bindings.length > bindings):
			retained_binding* binding = retained_bindings.pop()
			retained_binding_cache.remove(binding.key)
			if (binding.origin_previous >= 0): retained_binding_origins[binding.origin] = binding.origin_previous
			else: retained_binding_origins.remove(binding.origin)
			free(binding.key)
			binding.parameters.free()
			free(binding)
	if (retained_types != 0):
		while (retained_types.length > types):
			retained_type* type = retained_types.pop()
			for i in range(type.fields.length): free(type.fields[i])
			for i in range(type.constants.length): free(type.constants[i])
			type.constants.free()
			type.fields.free()
			type.parameters.free()
			free(type)


void retained_semantic_clear():
	retained_semantic_rollback(0, 0)
	if (retained_types != 0): retained_types.free()
	if (retained_bindings != 0): retained_bindings.free()
	if (retained_binding_cache != 0): retained_binding_cache.free()
	if (retained_binding_origins != 0): retained_binding_origins.free()
	retained_types = 0
	retained_bindings = 0
	retained_binding_cache = 0
	retained_binding_origins = 0
	if (retained_interned != 0):
		for i in range(retained_interned.length): free(retained_interned[i])
		retained_interned.free()
		retained_intern_index.free()
		free(cast(char*, retained_intern_callers))
		free(cast(char*, retained_intern_copies))
	retained_interned = 0
	retained_intern_index = 0
	retained_intern_callers = 0
	retained_intern_copies = 0
	if (retained_key_buffer != 0): free(retained_key_buffer)
	retained_key_buffer = 0
	retained_key_capacity = 0
