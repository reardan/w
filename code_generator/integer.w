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

void save_i(char* p, int v, int n):
	int i = 0
	while (i < n):
		p[i] = v
		v = v >> 8
		i = i + 1


void save_int64(char *p, int v):
	save_i(p, v, 8)


void save_int32(char *p, int v):
	save_i(p, v, 4)


void save_int16(char *p, int v):
	save_i(p, v, 2)


void save_int8(char *p, int v):
	save_i(p, v, 1)


void save_int(char *p, int v):
	save_int32(p, v)


int load_i(char* p, int n):
	int result = 0
	while (n > 0):
		result = (result << 8) + (p[n - 1] & 255)
		n = n - 1
	return result


int load_int64(char *p):
	return load_i(p, 8)


int load_int32(char *p):
	int result = load_i(p, 4)
	# Sign-extend on 64-bit hosts so 4-byte fields (e.g. a stored -1) load
	# with the same int semantics as on 32-bit hosts
	if (__word_size__ == 8):
		result = (result << 32) >> 32
	return result


int load_int16(char *p):
	return load_i(p, 2)


int load_int8(char *p):
	return load_i(p, 1)


int load_int(char *p):
	return load_int32(p)


################## POINTER-SIZED SLOTS ##################
# For host pointers stored in compiler-internal tables. A pointer slot is
# __word_size__ bytes (the width of the *running* compiler's pointers, not
# the target's word_size): 4-byte save_int slots silently truncate on a
# 64-bit host whose heap sits above 4 GB — every mmap result on arm64
# macOS, where the kernel mandates a 4 GB __PAGEZERO. Tables holding
# pointers must stride by __word_size__ and use these accessors.

void save_ptr(char* p, int v):
	save_i(p, v, __word_size__)


int load_ptr(char* p):
	return load_i(p, __word_size__)
