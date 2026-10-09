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
	# S2.5: the raw symbol location in this binding's lookup key (line and
	# column above may name the declaration instead), so a lookup can
	# confirm a candidate without spelling the key.
	int key_line
	int key_column
	int key_file_index

list[retained_type*] retained_types
list[retained_binding*] retained_bindings
# S2.5: type-table index -> retained type ID, valid while its stamp equals
# retained_type_generation. Invalidation runs at every declaration, so it
# bumps the generation instead of freeing and rebuilding a map.
int* retained_type_cache_ids
int* retained_type_cache_stamps
int retained_type_cache_capacity
int retained_type_generation = 1
map[char*, int] retained_binding_cache
# Newest binding per raw symbol offset; heads of origin_previous chains.
map[int, int] retained_binding_origins

# S2.5: direct-mapped front cache for retained_binding_note, raw symbol
# offset -> binding ID. A hit is confirmed against the binding's key fields.
const int retained_binding_slots = 4096
int* retained_binding_front

# Scratch lookup key for retained_binding_note; a new binding owns a copy.
char* retained_key_buffer
int retained_key_capacity

# Session-owned interned spellings. Names, files and type spellings repeat
# across hundreds of thousands of records; each record borrows one copy.
# Interned text is never retracted by rollback (no ID refers to it), so a
# rolled-back record needs no string frees; retained_semantic_clear frees it.
list[char*] retained_interned
# S2.5: open-addressed table of the interned copies (as ints, 0 = empty),
# keyed by a multiplicative hash of the text. Cheaper than a SipHash map for
# the short spellings interned here. P1.2b: each slot keeps its copy's hash,
# so a probe compares text only when the hashes agree.
int* retained_intern_table
int* retained_intern_hashes
int retained_intern_table_capacity
# S2.5: the interned empty spelling (most nodes have no name).
char* retained_intern_empty

# P1.2b: 1 when the session keeps semantic snapshot records (types and
# bindings) for its nodes: a tree query, an explicit --ast-retain, or an
# in-process compiler API (the default here; the driver and the REPL reset
# it). A plain compile's forest keeps the raw table identities it lowers.
int retained_semantic_mode = 1


int retained_intern_hash(char* text):
	int h = 0
	int i = 0
	while (text[i] != 0):
		h = h * 31 + (text[i] & 255)
		i = i + 1
	return h


void retained_intern_place(char* copy, int h):
	int mask = retained_intern_table_capacity - 1
	int i = h & mask
	while (retained_intern_table[i] != 0): i = (i + 1) & mask
	retained_intern_table[i] = cast(int, copy)
	retained_intern_hashes[i] = h


# Make room for one more copy, growing the table at half load.
void retained_intern_reserve():
	if ((retained_interned.length + 1) * 2 <= retained_intern_table_capacity): return
	int capacity = retained_intern_table_capacity * 2
	if (capacity < 4096): capacity = 4096
	if (retained_intern_table != 0):
		free(cast(char*, retained_intern_table))
		free(cast(char*, retained_intern_hashes))
	retained_intern_table = cast(int*, malloc(capacity * __word_size__))
	retained_intern_hashes = cast(int*, malloc(capacity * __word_size__))
	retained_intern_table_capacity = capacity
	for i in range(capacity): retained_intern_table[i] = 0
	for i in range(retained_interned.length):
		char* copy = retained_interned[i]
		retained_intern_place(copy, retained_intern_hash(copy))


char* retained_intern(char* text):
	if (text == 0): return 0
	if ((text[0] == 0) && (retained_intern_empty != 0)): return retained_intern_empty
	if (retained_interned == 0): retained_interned = new list[char*]
	retained_intern_reserve()
	int h = retained_intern_hash(text)
	int mask = retained_intern_table_capacity - 1
	int i = h & mask
	while (retained_intern_table[i] != 0):
		if (retained_intern_hashes[i] == h):
			char* found = cast(char*, retained_intern_table[i])
			if (strcmp(found, text) == 0): return found
		i = (i + 1) & mask
	char* copy = strclone(text)
	retained_intern_table[i] = cast(int, copy)
	retained_intern_hashes[i] = h
	retained_interned.push(copy)
	if (text[0] == 0): retained_intern_empty = copy
	return copy


# The retained type cached for a type-table index, or -1.
int retained_type_cached(int index):
	if (index >= retained_type_cache_capacity): return -1
	if (retained_type_cache_stamps[index] != retained_type_generation): return -1
	return retained_type_cache_ids[index]


void retained_type_cache_set(int index, int id):
	if (index >= retained_type_cache_capacity):
		int capacity = retained_type_cache_capacity * 2
		if (capacity < 1024): capacity = 1024
		while (capacity <= index): capacity = capacity * 2
		int* ids = cast(int*, malloc(capacity * __word_size__))
		int* stamps = cast(int*, malloc(capacity * __word_size__))
		for i in range(capacity):
			if (i < retained_type_cache_capacity):
				ids[i] = retained_type_cache_ids[i]
				stamps[i] = retained_type_cache_stamps[i]
			else:
				ids[i] = -1
				stamps[i] = 0
		if (retained_type_cache_ids != 0):
			free(cast(char*, retained_type_cache_ids))
			free(cast(char*, retained_type_cache_stamps))
		retained_type_cache_ids = ids
		retained_type_cache_stamps = stamps
		retained_type_cache_capacity = capacity
	retained_type_cache_ids[index] = id
	retained_type_cache_stamps[index] = retained_type_generation


void retained_semantic_invalidate():
	retained_type_generation = retained_type_generation + 1


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
	if (retained_type_cache_ids != 0):
		free(cast(char*, retained_type_cache_ids))
		free(cast(char*, retained_type_cache_stamps))
	retained_type_cache_ids = 0
	retained_type_cache_stamps = 0
	retained_type_cache_capacity = 0
	if (retained_binding_front != 0): free(cast(char*, retained_binding_front))
	retained_binding_front = 0
	retained_types = 0
	retained_bindings = 0
	retained_binding_cache = 0
	retained_binding_origins = 0
	if (retained_interned != 0):
		for i in range(retained_interned.length): free(retained_interned[i])
		retained_interned.free()
		if (retained_intern_table != 0):
			free(cast(char*, retained_intern_table))
			free(cast(char*, retained_intern_hashes))
	retained_interned = 0
	retained_intern_table = 0
	retained_intern_hashes = 0
	retained_intern_table_capacity = 0
	retained_intern_empty = 0
	if (retained_key_buffer != 0): free(retained_key_buffer)
	retained_key_buffer = 0
	retained_key_capacity = 0
