/*
Shared runtime for built-in map[K, V] and set[K].

The compiler lowers built-in syntax to these helpers. Keys and values are
stored as words in the MVP; small scalar values occupy the low bits. String
keys are cloned so map/set ownership does not depend on literal or stack
lifetimes.

Layout (a "compact dict", as in CPython 3.6+):
the entries live in one dense array in INSERTION ORDER, each entry
[hash][key][value slot] interleaved, and a separate open-addressing
index maps a hash to an entry. An index slot is two int32s, the entry
word (0 = empty, -1 = tombstone, k > 0 = entry k - 1) and the entry's
31-bit hash, so linear probing (power-of-two size) compares hashes
inside the index and reads an entry only on a full hash match: a lookup
touches one index line and one entry, where the old five parallel
arrays (keys, values, states and two order links) touched five lines
per probe. Insertion order costs nothing: iteration walks the entries
array and skips the dead ones. Removing marks the entry dead (hash -1)
and tombstones its index slot; re-inserting appends a fresh entry at
the end; updating an existing key keeps its position. The entries array
holds half as many entries as the index has slots; when it fills up the
table is rebuilt (doubled, or at the same size when at least half the
entries are dead), compacting live entries in order, so growth
preserves insertion order and, when nothing was removed, keeps every
entry index (an iteration cursor) valid.

Hashing is keyed (issue #528) under a per-process random 64-bit seed
drawn from getrandom(2) when the first table is created; each table
copies the seed at creation, so __w_hash_set_seed only affects tables
created after it. String keys (char* and string) go through
HalfSipHash-1-3, so keys cannot be chosen in advance to collide (hash
flooding). Word keys (integers, bools, other pointers) use a keyed
murmur3-style finalizer, __w_hash_word: a few multiplies instead of a
SipHash per operation, which made map[int, V] several times faster
(docs/projects/scripting.md, Phase R1). It is a bijection of the key
mixed with the seed and has good avalanche, but it is not a PRF, so an
attacker who can measure timing has more leverage than against
SipHash; a program that keys a map by attacker-chosen integers and
needs SipHash's guarantee can key it by their decimal strings instead.
Nothing observable depends on the seed: iteration walks the entries
array, never index order, and __w_map_free releases keys in insertion
order, so allocation patterns (and therefore the compiler's own output)
stay deterministic run to run.
*/
import lib.memory
import structures.w_list


int __w_strlen(char* c):
	int length = 0
	while(c[length]): length = length + 1
	return length


char* __w_strcpy(char *dst, char *src):
	while (src[0]):
		dst[0] = src[0]
		src = src + 1
		dst = dst + 1
	dst[0] = 0
	return dst


int __w_strcmp(char* s1, char* s2):
	int i = 0
	while (s1[i] == s2[i]):
		if (s1[i] == 0): return 0
		i = i + 1
	return s1[i] - s2[i]


char* __w_strclone(char *c):
	char *clone = cast(char*, __w_alloc(__w_strlen(c) + 1))
	__w_strcpy(clone, c)
	return clone


struct __w_hash_table:
	int capacity      # index slots, a power of two
	int count         # live entries
	int key_kind
	int value_size
	int32* index      # capacity slots of (entry word, hash): see the header
	char* entries     # entry_cap entries in insertion order, entry_size bytes each
	int used          # entries appended so far, live and dead
	int entry_cap     # entries allocated: capacity / 2
	int entry_size    # 2 words (hash, key) + the value slot
	int default_kind  # missing-key policy: __w_hash_default_* (0 = trap)
	int default_value # stored word / factory address / container descriptor
	int seed0         # hash key words, copied from the process seed
	int seed1


# Bytes per value slot. Scalar values (value_size <= word) keep the
# original one-word-per-slot layout; aggregate values get value_size
# bytes rounded up to a word multiple, matching W's word-granular
# struct copies, so structs are stored by value.
int __w_hash_slot_size(__w_hash_table* table):
	if (table.value_size < __word_size__):
		return __word_size__
	return ((table.value_size + __word_size__ - 1) / __word_size__) * __word_size__


# Entry i: word 0 is its 31-bit hash (-1 once removed), word 1 its key,
# then the value slot.
int* __w_hash_entry(__w_hash_table* table, int i):
	return cast(int*, table.entries + i * table.entry_size)


char* __w_hash_value_addr(__w_hash_table* table, int i):
	return table.entries + i * table.entry_size + 2 * __word_size__


void __w_hash_value_copy(char* dst, char* src, int count):
	for i in range(count): dst[i] = src[i]


const int __w_hash_key_word = 1
const int __w_hash_key_cstr = 2
const int __w_hash_key_string = 3


# Missing-key policies for maps built with 'new map[K, V](...)' (issue
# #327). 0 (none) keeps the documented trap; the other kinds make a
# missing read INSERT a freshly-materialized default and return it.
const int __w_hash_default_none = 0


# default_value is the value word itself, copied into every missing slot.
const int __w_hash_default_value = 1


# default_value is a zero-argument factory's address, called per missing
# key so vivified values never alias each other.
const int __w_hash_default_factory = 2


# default_value is a packed descriptor for an empty inner container,
# synthesized by the compiler for 'new map[K, container](...)' with the
# argument omitted. Layout (mirrored by hash_default_container_descriptor
# in grammar/hash_builtin.w):
#   bits 0-1  container code: 1 = map, 2 = set, 3 = list
#   bits 2-3  inner key kind (__w_hash_key_*; map and set only)
#   bit 4     inner map's scalar values default to a zero word, so
#             outer[a][b] += 1 works on a completely fresh 'a'
#   bits 5+   inner value_size (map) / element slot size (list)
const int __w_hash_default_container = 3


# Missing-key trap (issue #188): says which key was missing before
# exiting. char* and string keys print their contents; scalar keys print
# as integers. The trap helpers live in structures/w_list.w.
void __w_map_missing_key(__w_hash_table* table, int key):
	__w_trap_cstr(c"map key not found: ")
	if (table.key_kind == __w_hash_key_cstr): __w_trap_cstr(cast(char*, key))
	else if (table.key_kind == __w_hash_key_string):
		write(2, cast(char*, load_ptr(cast(char*, key))), load_ptr(key + __word_size__))
	else: __w_trap_int(key)
	__w_trap_cstr(c"\n")
	print_stack_trace()
	exit(1)


# Process hash seed (see the header). __w_hash_seed_state is 0 until the
# first table is created (or __w_hash_set_seed is called), then 1.
int __w_hash_seed_state
int __w_hash_seed0
int __w_hash_seed1


# Override the process seed for tables created from now on (tests, or
# a program that wants reproducible probe sequences). Existing tables
# keep the seed they were created with.
void __w_hash_set_seed(int k0, int k1):
	__w_hash_seed0 = k0
	__w_hash_seed1 = k1
	__w_hash_seed_state = 1


# Draws the process seed from getrandom(2) (GRND_NONBLOCK, so early boot
# never blocks). Targets without the syscall (arm64_darwin, wasm, win64
# stubs) or a failing call fall back to mixing ASLR-dependent addresses,
# which is weaker but still unknown to an attacker who cannot read the
# process's memory layout.
void __w_hash_seed_init(int salt):
	int k0 = 0
	int k1 = 0
	int got0 = sys_getrandom(cast(char*, &k0), 4, 1)
	int got1 = sys_getrandom(cast(char*, &k1), 4, 1)
	if ((got0 != 4) || (got1 != 4)):
		k0 = rotl(cast(int, &k0), 13) ^ salt
		k1 = rotl(salt, 7) ^ rotl(cast(int, &k1), 21) ^ 0x2545f491
	__w_hash_set_seed(k0, k1)


# HalfSipHash-1-3 (Aumasson & Bernstein's 32-bit SipHash, one compression
# and three finalization rounds) keyed by the table's seed, over the
# masked-32-bit-word convention so x86, x64 and arm64 compute the same
# value. lib/byte_map.w's bytes_hash_seeded is the 2-4 variant of the
# same construction. The result is a masked 32-bit word.
int __w_hash_sip(__w_hash_table* table, int data, int length):
	# The state words are uint32 (unit A8, docs/projects/
	# codegen_gap_plan.md §2.7): the 32-bit word on a 32-bit host, a
	# zero-extended 32-bit register on x64, so every store truncates
	# and no '& mask' is needed; rotl is defined on the low 32 bits.
	char* p = cast(char*, data)
	uint32 v0 = table.seed0
	uint32 v1 = table.seed1
	uint32 v2 = 0x6c796765 ^ v0
	uint32 v3 = 0x74656462 ^ v1
	int i = 0
	int done = 0
	while (done == 0):
		uint32 m = 0
		if (length - i >= 4):
			int32* word = cast(int32*, p + i)
			m = word[0]
			i = i + 4
		else:
			m = length << 24
			int shift = 0
			while (i < length):
				m = m | ((p[i] & 255) << shift)
				shift = shift + 8
				i = i + 1
			done = 1
		v3 = v3 ^ m
		v0 = v0 + v1
		v1 = rotl(v1, 5) ^ v0
		v0 = rotl(v0, 16)
		v2 = v2 + v3
		v3 = rotl(v3, 8) ^ v2
		v0 = v0 + v3
		v3 = rotl(v3, 7) ^ v0
		v2 = v2 + v1
		v1 = rotl(v1, 13) ^ v2
		v2 = rotl(v2, 16)
		v0 = v0 ^ m
	v2 = v2 ^ 255
	int r = 0
	while (r < 3):
		v0 = v0 + v1
		v1 = rotl(v1, 5) ^ v0
		v0 = rotl(v0, 16)
		v2 = v2 + v3
		v3 = rotl(v3, 8) ^ v2
		v0 = v0 + v3
		v3 = rotl(v3, 7) ^ v0
		v2 = v2 + v1
		v1 = rotl(v1, 13) ^ v2
		v2 = rotl(v2, 16)
		r = r + 1
	return v1 ^ v3


# Keyed hash for word keys (see the header): the murmur3 fmix32 rounds
# over the key's low 32 bits xor seed0. On 64-bit targets the high half
# is added after a first multiply-xorshift of the low half, so the two
# halves cannot cancel each other independently of the seed. uint32
# arithmetic keeps every step a masked 32-bit word on each target (the
# multipliers are murmur3's and the golden ratio's, spelled negative to
# avoid bit-31 literals). Returns 31 bits, like __w_hash_key_hash.
int __w_hash_word(__w_hash_table* table, int key):
	uint32 h = key ^ table.seed0
	if (__word_size__ == 8):
		h = h * (0 - 1640531535)
		h = h ^ (h >> 15)
		h = h + ((key >> 16) >> 16)
	h = h + table.seed1
	h = h ^ (h >> 16)
	h = h * (0 - 2048144789)
	h = h ^ (h >> 13)
	h = h * (0 - 1028477387)
	h = h ^ (h >> 16)
	return h & 0x7fffffff


# The key's 31-bit hash: non-negative, so an entry's hash word can
# double as its live flag (-1 marks a removed entry).
int __w_hash_key_hash(__w_hash_table* table, int key):
	int kind = table.key_kind
	if (kind == __w_hash_key_cstr): return __w_hash_sip(table, key, __w_strlen(cast(char*, key))) & 0x7fffffff
	if (kind == __w_hash_key_string):
		return __w_hash_sip(table, load_ptr(cast(char*, key)), load_ptr(key + __word_size__)) & 0x7fffffff
	return __w_hash_word(table, key)


int __w_hash_string_equal(int left, int right):
	int left_len = load_ptr(left + __word_size__)
	int right_len = load_ptr(right + __word_size__)
	if (left_len != right_len): return 0
	int left_data = load_ptr(cast(char*, left))
	int right_data = load_ptr(cast(char*, right))
	for i in range(left_len):
		if (left_data[i] != right_data[i]): return 0
	return 1


# string == string / != (grammar/equality_expr.w): contents, null-safe
# (a null descriptor equals only null).
int __w_string_equal(int left, int right):
	if (left == right): return 1
	if ((left == 0) || (right == 0)): return 0
	return __w_hash_string_equal(left, right)


# switch on a char* (grammar/switch_statement.w): contents, null-safe.
int __w_cstr_equal(char* left, char* right):
	if (left == right): return 1
	if ((left == 0) || (right == 0)): return 0
	return __w_strcmp(left, right) == 0


int __w_hash_key_equal(int kind, int left, int right):
	if (kind == __w_hash_key_cstr): return __w_strcmp(cast(char*, left), cast(char*, right)) == 0
	if (kind == __w_hash_key_string): return __w_hash_string_equal(left, right)
	return left == right


int __w_hash_clone_string(int key):
	int length = load_ptr(key + __word_size__)
	char* clone = cast(char*, __w_alloc(__w_size_add(2 * __word_size__ + 1, length)))
	int data = cast(int, clone) + 2 * __word_size__
	save_ptr(clone, data)
	save_ptr(clone + __word_size__, length)
	int source = load_ptr(cast(char*, key))
	for i in range(length): data[i] = source[i]
	data[length] = 0
	return cast(int, clone)


int __w_hash_key_clone(int kind, int key):
	if (kind == __w_hash_key_cstr): return cast(int, __w_strclone(cast(char*, key)))
	if (kind == __w_hash_key_string): return __w_hash_clone_string(key)
	return key


void __w_hash_key_free(int kind, int key):
	if ((kind == __w_hash_key_cstr) || (kind == __w_hash_key_string)): free(cast(void*, key))


# Allocate a zeroed index of capacity slots (two int32 each), sized for
# capacity / 2 entries.
void __w_hash_index_alloc(__w_hash_table* table, int capacity):
	table.capacity = capacity
	table.entry_cap = capacity / 2
	table.index = cast(int32*, __w_alloc(__w_size_mul(capacity, 8)))
	# The index is a whole number of words, so it clears by words.
	int* words = cast(int*, table.index)
	int n = (capacity * 8) / __word_size__
	int i = 0
	while (i < n):
		words[i] = 0
		i = i + 1


# A fresh index and an empty entries array. Entries need no
# initialization: one is written in full when it is appended.
void __w_hash_table_alloc(__w_hash_table* table, int capacity):
	__w_hash_index_alloc(table, capacity)
	table.entries = cast(char*, __w_alloc(__w_size_mul(table.entry_cap, table.entry_size)))
	table.used = 0
	table.count = 0


__w_hash_table* __w_hash_table_new(int key_kind, int value_size, int capacity):
	if (capacity < 16): capacity = 16
	__w_hash_table* table = cast(__w_hash_table*, __w_alloc(sizeof(__w_hash_table)))
	if (__w_hash_seed_state == 0): __w_hash_seed_init(cast(int, table))
	table.seed0 = __w_hash_seed0
	table.seed1 = __w_hash_seed1
	table.key_kind = key_kind
	table.value_size = value_size
	table.default_kind = __w_hash_default_none
	table.default_value = 0
	table.entry_size = 2 * __word_size__ + __w_hash_slot_size(table)
	__w_hash_table_alloc(table, capacity)
	return table


# Index position (the int32 offset of a slot's entry word, always even)
# whose entry holds key, or -1 when key is absent. Entries fill at most
# half the index, so the walk always reaches an empty slot, and a
# slot's hash word means only a full 31-bit hash match reads the entry.
int __w_hash_probe(__w_hash_table* table, int key):
	int kind = table.key_kind
	int by_content = (kind == __w_hash_key_cstr) || (kind == __w_hash_key_string)
	int hv = __w_hash_key_hash(table, key)
	int mask = table.capacity * 2 - 1
	int32* index = table.index
	int q = (hv + hv) & mask
	while (1):
		int slot = index[q]
		if (slot > 0):
			if (index[q + 1] == hv):
				int* e = cast(int*, table.entries + (slot - 1) * table.entry_size)
				int stored = e[1]
				# Identical words are equal keys under every kind (a C
				# string or descriptor equals itself), so only
				# non-identical pointer keys need the content compare.
				if (stored == key): return q
				if (by_content):
					if (__w_hash_key_equal(kind, stored, key)): return q
		else if (slot == 0): return -1
		q = (q + 2) & mask
	return -1


# Entry index of key, or -1 when it is absent: __w_hash_probe with the
# word-key hash inlined, since every lookup comes through here.
int __w_hash_table_find(__w_hash_table* table, int key):
	int kind = table.key_kind
	int by_content = (kind == __w_hash_key_cstr) || (kind == __w_hash_key_string)
	int hv = 0
	if (by_content): hv = __w_hash_key_hash(table, key)
	else:
		# __w_hash_word
		uint32 h = key ^ table.seed0
		if (__word_size__ == 8):
			h = h * (0 - 1640531535)
			h = h ^ (h >> 15)
			h = h + ((key >> 16) >> 16)
		h = h + table.seed1
		h = h ^ (h >> 16)
		h = h * (0 - 2048144789)
		h = h ^ (h >> 13)
		h = h * (0 - 1028477387)
		h = h ^ (h >> 16)
		hv = h & 0x7fffffff
	int mask = table.capacity * 2 - 1
	int32* index = table.index
	int q = (hv + hv) & mask
	while (1):
		int slot = index[q]
		if (slot > 0):
			if (index[q + 1] == hv):
				int* e = cast(int*, table.entries + (slot - 1) * table.entry_size)
				int stored = e[1]
				if (stored == key): return slot - 1
				if (by_content):
					if (__w_hash_key_equal(kind, stored, key)): return slot - 1
		else if (slot == 0): return -1
		q = (q + 2) & mask
	return -1


# Rebuild at new_capacity. With no dead entries (plain growth) the
# entries stay where they are -- realloc extends the block in place when
# it is the newest allocation -- and only the index is rebuilt from
# their stored hashes. Otherwise the live entries move to the front of a
# fresh entries array in insertion order, dropping the dead ones and
# every tombstone.
void __w_hash_table_rehash(__w_hash_table* table, int new_capacity):
	int32* old_index = table.index
	char* old_entries = table.entries
	int old_used = table.used
	int size = table.entry_size
	int mask = new_capacity * 2 - 1
	int32* index = cast(int32*, 0)
	int* e = cast(int*, 0)
	int hv = 0
	int q = 0
	int i = 0
	if (table.count == old_used):
		int old_bytes = table.entry_cap * size
		free(old_index)
		__w_hash_index_alloc(table, new_capacity)
		table.entries = __w_realloc(old_entries, old_bytes, __w_size_mul(table.entry_cap, size))
		index = table.index
		char* entries = table.entries
		while (i < old_used):
			e = cast(int*, entries + i * size)
			hv = e[0]
			q = (hv + hv) & mask
			while (index[q] != 0): q = (q + 2) & mask
			i = i + 1
			index[q] = i
			index[q + 1] = hv
		return
	__w_hash_table_alloc(table, new_capacity)
	index = table.index
	char* fresh = table.entries
	int words = size / __word_size__
	int n = 0
	int* dst = cast(int*, 0)
	int w = 0
	while (i < old_used):
		e = cast(int*, old_entries + i * size)
		hv = e[0]
		if (hv >= 0):
			dst = cast(int*, fresh + n * size)
			w = 0
			while (w < words):
				dst[w] = e[w]
				w = w + 1
			q = (hv + hv) & mask
			while (index[q] != 0): q = (q + 2) & mask
			n = n + 1
			index[q] = n
			index[q + 1] = hv
		i = i + 1
	table.used = n
	table.count = n
	free(old_index)
	free(old_entries)


# The entries array is full: double the table, or rebuild it at the same
# size when at least half the entries are dead (add/remove churn), which
# compacts them.
void __w_hash_table_grow(__w_hash_table* table):
	if (table.count * 2 <= table.used): __w_hash_table_rehash(table, table.capacity)
	else: __w_hash_table_rehash(table, __w_size_mul(table.capacity, 2))


__w_hash_table* __w_map_new(int key_kind, int value_size):
	return __w_hash_table_new(key_kind, value_size, 16)


# Insert or find the entry for key, growing and cloning the key as
# needed. A new key is appended after every existing entry (insertion
# order) with a zeroed value slot and takes the first tombstone on its
# probe path, else the empty slot that ended it; an existing key keeps
# its position. The lookup is __w_hash_table_find's, inlined.
int __w_map_insert_slot(__w_hash_table* table, int key):
	int kind = table.key_kind
	int by_content = (kind == __w_hash_key_cstr) || (kind == __w_hash_key_string)
	int hv = 0
	if (by_content): hv = __w_hash_key_hash(table, key)
	else:
		# __w_hash_word
		uint32 h = key ^ table.seed0
		if (__word_size__ == 8):
			h = h * (0 - 1640531535)
			h = h ^ (h >> 15)
			h = h + ((key >> 16) >> 16)
		h = h + table.seed1
		h = h ^ (h >> 16)
		h = h * (0 - 2048144789)
		h = h ^ (h >> 13)
		h = h * (0 - 1028477387)
		h = h ^ (h >> 16)
		hv = h & 0x7fffffff
	int mask = table.capacity * 2 - 1
	int32* index = table.index
	int q = (hv + hv) & mask
	int tomb = -1
	while (1):
		int slot = index[q]
		if (slot > 0):
			if (index[q + 1] == hv):
				int* found = cast(int*, table.entries + (slot - 1) * table.entry_size)
				int stored = found[1]
				if (stored == key): return slot - 1
				if (by_content):
					if (__w_hash_key_equal(kind, stored, key)): return slot - 1
		else if (slot == 0): break
		else if (tomb < 0): tomb = q
		q = (q + 2) & mask
	if (table.used >= table.entry_cap):
		# Rare (each growth doubles the room): rebuild, then insert
		# into the rebuilt table from scratch.
		__w_hash_table_grow(table)
		return __w_map_insert_slot(table, key)
	if (tomb >= 0): q = tomb
	int i = table.used
	int size = table.entry_size
	int* e = cast(int*, table.entries + i * size)
	e[0] = hv
	if (by_content): key = __w_hash_key_clone(kind, key)
	e[1] = key
	if (size == 3 * __word_size__): e[2] = 0
	else:
		int words = size / __word_size__
		int w = 2
		while (w < words):
			e[w] = 0
			w = w + 1
	index[q] = i + 1
	index[q + 1] = hv
	table.used = i + 1
	table.count = table.count + 1
	return i


void __w_map_set(__w_hash_table* table, int key, int value):
	int i = __w_map_insert_slot(table, key)
	int* e = cast(int*, table.entries + i * table.entry_size)
	e[2] = value


# Aggregate values (structs) are passed by address: copy one slot's worth
# of bytes from value_src into the value storage.
void __w_map_set_bytes(__w_hash_table* table, int key, char* value_src):
	int i = __w_map_insert_slot(table, key)
	__w_hash_value_copy(__w_hash_value_addr(table, i), value_src, __w_hash_slot_size(table))


# m.add(key, delta): insert-or-accumulate for integer-valued maps. A new
# key's value slot starts zeroed, so a missing key accumulates from
# zero. Returns the updated value.
int __w_map_add(__w_hash_table* table, int key, int delta):
	int i = __w_map_insert_slot(table, key)
	int* e = cast(int*, table.entries + i * table.entry_size)
	int sum = e[2] + delta
	e[2] = sum
	return sum


int __w_map_contains(__w_hash_table* table, int key):
	return __w_hash_table_find(table, key) >= 0


# Install the missing-key policy chosen at 'new map[K, V](...)' time.
void __w_map_set_default(__w_hash_table* table, int kind, int value):
	table.default_kind = kind
	table.default_value = value


# Build the empty inner container a __w_hash_default_container
# descriptor describes (layout above __w_hash_default_container).
int __w_map_default_new_container(int desc):
	int code = desc & 3
	int kind = (desc >> 2) & 3
	int size = desc >> 5
	if (code == 3): return cast(int, __w_list_new(size))
	__w_hash_table* inner = __w_map_new(kind, size)
	if (desc & 16):
		inner.default_kind = __w_hash_default_value
		inner.default_value = 0
	return cast(int, inner)


# Materialize one default value per the table's policy. Called before
# the slot is claimed so a factory that mutates this same map cannot
# invalidate the slot index.
type __factory_callback = fn() -> int


int __w_map_default_materialize(__w_hash_table* table):
	if (table.default_kind == __w_hash_default_factory):
		int factory = table.default_value
		return (cast(__factory_callback*, factory))()
	if (table.default_kind == __w_hash_default_container):
		return __w_map_default_new_container(table.default_value)
	return table.default_value


# Auto-vivification (issue #327): insert the materialized default for a
# missing key and return it. Only reachable when default_kind is not
# __w_hash_default_none, i.e. the map opted in at construction.
int __w_map_vivify(__w_hash_table* table, int key):
	int value = __w_map_default_materialize(table)
	int i = __w_map_insert_slot(table, key)
	int* slot = cast(int*, __w_hash_value_addr(table, i))
	slot[0] = value
	return value


# Scalar read for m[key] and one-argument m.get(key). Maps built with a
# 'new map[K, V](...)' default vivify missing keys instead of trapping;
# every other map keeps the documented trap.
int __w_map_get(__w_hash_table* table, int key):
	int i = __w_hash_table_find(table, key)
	if (i < 0):
		if (table.default_kind == __w_hash_default_none): __w_map_missing_key(table, key)
		return __w_map_vivify(table, key)
	int* e = cast(int*, table.entries + i * table.entry_size)
	return e[2]


# Aggregate read: the address of the stored value bytes. Only valid until
# the next insertion rehashes the table, so callers copy immediately.
char* __w_map_get_addr(__w_hash_table* table, int key):
	int i = __w_hash_table_find(table, key)
	if (i < 0): __w_map_missing_key(table, key)
	return __w_hash_value_addr(table, i)


# m.get(key, default): scalar value at key, or default when key is absent.
int __w_map_get_or(__w_hash_table* table, int key, int default_value):
	int i = __w_hash_table_find(table, key)
	if (i < 0): return default_value
	int* e = cast(int*, table.entries + i * table.entry_size)
	return e[2]


# Aggregate get-with-default: the stored value's address at key, or
# default_addr (the caller's default storage) when key is absent.
char* __w_map_get_or_addr(__w_hash_table* table, int key, char* default_addr):
	int i = __w_hash_table_find(table, key)
	if (i < 0): return default_addr
	return __w_hash_value_addr(table, i)


# m.keys() / s.keys(): snapshot of the keys (set members) in insertion
# order. element_size is the list's element width. Pointer keys
# (char*/string) share the container's cloned storage, so entries stay
# valid until that key is removed.
__w_list* __w_map_keys(__w_hash_table* table, int element_size):
	__w_list* result = __w_list_new(element_size)
	int i = 0
	while (i < table.used):
		int* e = __w_hash_entry(table, i)
		if (e[0] >= 0): __w_list_push(result, e[1])
		i = i + 1
	return result


# m.values(): snapshot of the values in insertion order. element_size is
# the list's element width; struct values copy their stored bytes.
__w_list* __w_map_values(__w_hash_table* table, int element_size):
	__w_list* result = __w_list_new(element_size)
	int i = 0
	while (i < table.used):
		int* e = __w_hash_entry(table, i)
		if (e[0] >= 0): __w_list_push_bytes(result, __w_hash_value_addr(table, i))
		i = i + 1
	return result


# The entry goes dead in place (hash -1, key cleared) and its index slot
# becomes a tombstone; the next rebuild drops both.
int __w_map_remove(__w_hash_table* table, int key):
	int q = __w_hash_probe(table, key)
	if (q < 0): return 0
	int* e = __w_hash_entry(table, table.index[q] - 1)
	__w_hash_key_free(table.key_kind, e[1])
	e[0] = -1
	e[1] = 0
	table.index[q] = -1
	table.count = table.count - 1
	return 1


int __w_map_length(__w_hash_table* table):
	return table.count


# The cursor is an entry index; -1 ends the walk. Dead entries are
# skipped, so removing the current key (or a later one) inside the loop
# is safe, and keys inserted inside the loop are visited.
int __w_hash_next_live(__w_hash_table* table, int i):
	int used = table.used
	while (i < used):
		int* e = __w_hash_entry(table, i)
		if (e[0] >= 0): return i
		i = i + 1
	return -1


int __w_map_iter_begin(__w_hash_table* table):
	return __w_hash_next_live(table, 0)


int __w_map_iter_done(__w_hash_table* table, int cursor):
	return cursor < 0


int __w_map_iter_next(__w_hash_table* table, int cursor):
	return __w_hash_next_live(table, cursor + 1)


# The live entry at the cursor; traps on a dead or out-of-range cursor.
int* __w_hash_iter_entry(__w_hash_table* table, int cursor):
	if ((cursor < 0) || (cursor >= table.used)): __w_trap(c"invalid map iterator")
	int* e = __w_hash_entry(table, cursor)
	if (e[0] < 0): __w_trap(c"invalid map iterator")
	return e


int __w_map_iter_key(__w_hash_table* table, int cursor):
	int* e = __w_hash_iter_entry(table, cursor)
	return e[1]


# Scalar value at the cursor's entry (for "for key, value in map").
int __w_map_iter_value(__w_hash_table* table, int cursor):
	int* e = __w_hash_iter_entry(table, cursor)
	return e[2]


# Aggregate value: the address of the stored bytes, valid until the next
# insertion rehashes the table.
char* __w_map_iter_value_addr(__w_hash_table* table, int cursor):
	__w_hash_iter_entry(table, cursor)
	return __w_hash_value_addr(table, cursor)


# Releases the table's arrays, its cloned string keys and the header.
# Pointer VALUES are not chased: freeing pointed-to values stays the
# caller's job. Using the container after free() is caller error (the
# lib/memory.w free contract); as a cheap best-effort safety the header
# is zeroed first — the freelist backend only rewrites the block's own
# header words on free, so until the block is reused a stale .length
# reads 0 and stale iteration sees no entries instead of plausible
# garbage (the debug backend unmaps the page, so any stale use faults
# outright).
void __w_map_free(__w_hash_table* table):
	# Insertion order, never index order: index positions depend on the
	# seed, and a seed-dependent free order would make later allocations
	# differ from run to run.
	int kind = table.key_kind
	if ((kind == __w_hash_key_cstr) || (kind == __w_hash_key_string)):
		int i = 0
		while (i < table.used):
			int* e = __w_hash_entry(table, i)
			if (e[0] >= 0): __w_hash_key_free(kind, e[1])
			i = i + 1
	free(table.index)
	free(table.entries)
	table.capacity = 0
	table.count = 0
	table.used = 0
	table.entry_cap = 0
	table.index = 0
	table.entries = 0
	free(table)


__w_hash_table* __w_set_new(int key_kind):
	return __w_map_new(key_kind, 0)


void __w_set_add(__w_hash_table* table, int key):
	__w_map_set(table, key, 1)


int __w_set_contains(__w_hash_table* table, int key):
	return __w_map_contains(table, key)


int __w_set_remove(__w_hash_table* table, int key):
	return __w_map_remove(table, key)


int __w_set_length(__w_hash_table* table):
	return __w_map_length(table)


void __w_set_free(__w_hash_table* table):
	__w_map_free(table)
