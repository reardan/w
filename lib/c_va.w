# C variadic arguments (x86-64 System V) for C-variadic W definitions
# compiled with --c-abi (docs/projects/object_files.md, "The C ABI
# mode"):
#
#   import lib.c_va
#
#   int sum(int n, ... va):
#   	c_va_list ap
#   	c_va_start(&ap, va)
#   	int total = 0
#   	for i in range(n): total = total + c_va_arg(&ap)
#   	c_va_end(&ap)
#   	return total
#
# The '...' parameter is the va_list the function's System V entry
# builds for each call; c_va_list has the psABI layout of C's
# `__va_list_tag`, so a c_va_list* passes to and from C's `va_list`
# parameters (vprintf-style functions) unchanged. Freestanding: no
# runtime is needed.


struct c_va_list:
	uint32 gp_offset
	uint32 fp_offset
	void* overflow_arg_area
	void* reg_save_area


# va_start: ap starts at the first argument after the fixed ones (va
# is the definition's '...' parameter).
void c_va_start(c_va_list* ap, void* va):
	c_va_list* first = cast(c_va_list*, va)
	ap.gp_offset = first.gp_offset
	ap.fp_offset = first.fp_offset
	ap.overflow_arg_area = first.overflow_arg_area
	ap.reg_save_area = first.reg_save_area


# va_arg of an INTEGER-class argument (an integer, pointer or enum; a
# narrow one is read back with a cast) as a word.
int c_va_arg(c_va_list* ap):
	int value = 0
	if (ap.gp_offset < 48):
		value = *cast(int*, ap.reg_save_area + ap.gp_offset)
		ap.gp_offset = ap.gp_offset + 8
		return value
	value = *cast(int*, ap.overflow_arg_area)
	ap.overflow_arg_area = ap.overflow_arg_area + 8
	return value


# va_arg of a double (a float argument is promoted to one), as its bits.
int c_va_arg_float64_bits(c_va_list* ap):
	int bits = 0
	if (ap.fp_offset < 176):
		bits = *cast(int*, ap.reg_save_area + ap.fp_offset)
		ap.fp_offset = ap.fp_offset + 16
		return bits
	bits = *cast(int*, ap.overflow_arg_area)
	ap.overflow_arg_area = ap.overflow_arg_area + 8
	return bits


# va_arg of a struct or union of size bytes whose eightbytes are all
# INTEGER class (no float fields), or of any larger one: the address of
# its bytes, valid while the caller's arguments live.
void* c_va_arg_record(c_va_list* ap, int size):
	int words = (size + 7) >> 3
	void* at = 0
	if ((size <= 16) && (ap.gp_offset + words * 8 <= 48)):
		at = ap.reg_save_area + ap.gp_offset
		ap.gp_offset = ap.gp_offset + words * 8
		return at
	at = ap.overflow_arg_area
	ap.overflow_arg_area = ap.overflow_arg_area + words * 8
	return at


# va_end: nothing to release.
void c_va_end(c_va_list* ap):
	ap.gp_offset = ap.gp_offset


# va_copy: dst continues where src is.
void c_va_copy(c_va_list* dst, c_va_list* src):
	dst.gp_offset = src.gp_offset
	dst.fp_offset = src.fp_offset
	dst.overflow_arg_area = src.overflow_arg_area
	dst.reg_save_area = src.reg_save_area
