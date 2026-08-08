/*
uint type: unsigned word

currently it's used for nearly everything
this is not appropriate because it's signed


currently this is used for both signed and unsigned operations
needs to get off this approach!!

in the mean time, before we have simple types mapped to files,
we will have to use 'uint' as the filename and 'int' in the code

*/

##################  Integer Type Information ##################

void push_all_integer_types():
	# todo: 64, 128, 256, 512, 1024, 2048, 4096
	# 8, 16, 32
	# int, uint
	int name_index = 0


##################  BIG ENDIAN (CPU) => LITTLE ENDIAN (MEM) ##################
#
# Every target is little-endian, so an n-byte field at p is exactly what a
# width-n machine load/store reads and writes: the byte loops below are
# only the fallback for widths with no matching machine type (3, 5, 6, 7,
# and 8 on a 32-bit host). Unaligned addresses are fine -- the symbol
# table packs 4-byte fields at odd offsets (compiler/symbol_table.w) and
# x86/x64/arm64 all take unaligned normal loads; wasm treats the encoded
# alignment as a hint, not a requirement.
#
# The sized wrappers below deliberately repeat the deref instead of
# delegating (save_int -> save_int32 -> save_i): W has no inliner, so
# every layer of delegation is a real call on a path the compiler walks
# millions of times per build.

void save_i(char* p, int v, int n):
	if (n == __word_size__):
		*cast(int*, p) = v
		return
	if (n == 4):
		*cast(int32*, p) = v
		return
	if (n == 2):
		*cast(int16*, p) = v
		return
	if (n == 1):
		p[0] = v
		return
	int i = 0
	while (i < n):
		p[i] = v
		v = v >> 8
		i = i + 1


# On a 32-bit host this keeps the byte loop's sign-fill of the upper four
# bytes (v >> 8 is arithmetic), which a 4-byte store would not reproduce.
void save_int64(char *p, int v):
	if (__word_size__ == 8):
		*cast(int*, p) = v
		return
	save_i(p, v, 8)


void save_int32(char *p, int v):
	*cast(int32*, p) = v


void save_int16(char *p, int v):
	*cast(int16*, p) = v


void save_int8(char *p, int v):
	p[0] = v


void save_int(char *p, int v):
	*cast(int32*, p) = v


int load_i(char* p, int n):
	if (n == __word_size__):
		return *cast(int*, p)
	if (n == 4):
		return *cast(uint32*, p)
	if (n == 2):
		return *cast(uint16*, p)
	if (n == 1):
		return *cast(uint8*, p)
	int result = 0
	while (n > 0):
		result = (result << 8) + (p[n - 1] & 255)
		n = n - 1
	return result


# A 32-bit host can only deliver the low four bytes, which is what the
# byte loop produced too (the high bytes shifted straight back out).
int load_int64(char *p):
	return *cast(int*, p)


# int32 (not uint32) so 4-byte fields sign-extend on a 64-bit host and a
# stored -1 loads with the same int semantics as on a 32-bit host.
int load_int32(char *p):
	return *cast(int32*, p)


int load_int16(char *p):
	return *cast(uint16*, p)


int load_int8(char *p):
	return *cast(uint8*, p)


int load_int(char *p):
	return *cast(int32*, p)


################## POINTER-SIZED SLOTS ##################
# For host pointers stored in compiler-internal tables. A pointer slot is
# __word_size__ bytes (the width of the *running* compiler's pointers, not
# the target's word_size): 4-byte save_int slots silently truncate on a
# 64-bit host whose heap sits above 4 GB -- every mmap result on arm64
# macOS, where the kernel mandates a 4 GB __PAGEZERO. Tables holding
# pointers must stride by __word_size__ and use these accessors. 'int' is
# the host word, so these are plain word loads and stores.

void save_ptr(char* p, int v):
	*cast(int*, p) = v


int load_ptr(char* p):
	return *cast(int*, p)
