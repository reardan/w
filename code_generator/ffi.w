/*
Calling-convention shims for extern (shared-library) functions.

W's internal convention pushes every argument on the stack (last argument
on top, caller cleans up) and returns in eax/rax; float values travel as
raw IEEE-754 bits in the integer pipeline. C libraries follow the platform
ABI instead, so each extern gets a generated stub that converts between
the two and jumps through the function's GOT slot (which the dynamic
loader fills in before the entry point runs):

  x64  System V: integer args in rdi/rsi/rdx/rcx/r8/r9, float args in
                 xmm0..xmm7, the rest on a 16-byte-aligned stack,
                 al = number of vector registers used (varargs contract).
                 Float results come back in xmm0 and are moved to rax.
  x86  cdecl:    all args re-pushed right-to-left onto a 16-byte-aligned
                 stack (float32 bits pass through unchanged; float64 spans
                 two words). Float results come back in st(0) and are
                 popped into eax.

Every argument is described by an ABI class so the stub knows which
register file it belongs to:

  class 0 = integer/pointer word
  class 1 = float32
  class 2 = float64

A null class array means "all integer", the historic behavior.

The same conversion is also emitted inline at variadic call sites (see
emit_ffi_call_inline): a variadic callee's float classes depend on the
actual arguments of each call, so no single per-function stub can cover
printf-style imports.
*/
import code_generator.code_emitter
import lib.lib


int type_get_pointer_level(int type_index);
int type_float_kind(int t);
void error(char *s);


# ABI class of a parameter or return type: 0 = integer/pointer word,
# 1 = float32, 2 = float64. Pointer types have their own indices, so
# float* correctly reads as class 0.
int ffi_type_class(int type):
	if (type < 0):
		return 0
	if (type_get_pointer_level(type) > 0):
		return 0
	return type_float_kind(type)


int ffi_arg_class(char* classes, int i):
	if (classes == 0):
		return 0
	return classes[i]


# Words one argument occupies on the W caller's stack: on x86 a float64
# (only produced by variadic default promotion) spans two 32-bit words.
int ffi_arg_words(char* classes, int i):
	if (word_size == 8):
		return 1
	if (ffi_arg_class(classes, i) == 2):
		return 2
	return 1


############################### x64 System V #################################

# mov <gp reg>,[rbp+disp32] for argument registers 0..5 (rdi rsi rdx rcx
# r8 r9). The REX prefix and ModRM byte vary per register.
void emit_x64_load_gp_reg(int reg, int disp):
	if (reg == 0):
		emit(3, c"\x48\x8b\xbd")   /* mov rdi,[rbp+disp32] */
	else if (reg == 1):
		emit(3, c"\x48\x8b\xb5")   /* mov rsi,[rbp+disp32] */
	else if (reg == 2):
		emit(3, c"\x48\x8b\x95")   /* mov rdx,[rbp+disp32] */
	else if (reg == 3):
		emit(3, c"\x48\x8b\x8d")   /* mov rcx,[rbp+disp32] */
	else if (reg == 4):
		emit(3, c"\x4c\x8b\x85")   /* mov r8,[rbp+disp32] */
	else:
		emit(3, c"\x4c\x8b\x8d")   /* mov r9,[rbp+disp32] */
	emit_int32(disp)


# movss/movsd xmm<reg>,[rbp+disp32] for xmm0..xmm7.
void emit_x64_load_xmm_reg(int reg, int arg_class, int disp):
	if (arg_class == 2):
		emit(1, c"\xf2")           /* movsd */
	else:
		emit(1, c"\xf3")           /* movss */
	emit(2, c"\x0f\x10")
	emit_int8(133 + (reg << 3))    /* ModRM: mod=10 reg=xmm rm=rbp */
	emit_int32(disp)


/*
System V AMD64 call for n arguments described by classes. arg_base is the
rbp-relative offset of the LAST argument (the one on top of the W stack)
after the frame is set up: 16 inside a stub (saved rbp + return address),
8 when emitted inline at a call site (saved rbp only). Argument i (0
based) then sits at [rbp + arg_base + 8 * (n - 1 - i)].
*/
void emit_c_abi_call_x64(int n, char* classes, int ret_class, int got_vaddr, int arg_base):
	emit(1, c"\x55")               /* push rbp */
	emit(3, c"\x48\x89\xe5")       /* mov rbp,rsp */
	emit(4, c"\x48\x83\xe4\xf0")   /* and rsp,-16 */

	# Assign each argument a slot: 0..5 = gp register index, 16+k = xmm k,
	# -1 = stack. Classification walks left to right per the SysV ABI.
	char* slots = 0
	if (n > 0):
		slots = malloc(n * 4)
	int gp_count = 0
	int xmm_count = 0
	int stack_count = 0
	int i = 0
	while (i < n):
		int slot = 0 - 1
		if (ffi_arg_class(classes, i) == 0):
			if (gp_count < 6):
				slot = gp_count
				gp_count = gp_count + 1
		else:
			if (xmm_count < 8):
				slot = 16 + xmm_count
				xmm_count = xmm_count + 1
		if (slot < 0):
			stack_count = stack_count + 1
		save_int(slots + (i << 2), slot)
		i = i + 1

	# An odd number of stack pushes would leave rsp 8 off a 16-byte boundary.
	if ((stack_count & 1) == 1):
		emit(4, c"\x48\x83\xec\x08")   /* sub rsp,8 */

	# Push overflow args in reverse so the leftmost lands at the lowest
	# address (the SysV memory argument order).
	i = n - 1
	while (i >= 0):
		if (load_int(slots + (i << 2)) < 0):
			emit(2, c"\xff\xb5")       /* push qword [rbp+disp32] */
			emit_int32(arg_base + ((n - 1 - i) << 3))
		i = i - 1

	# Load the register arguments (rbp-relative, so the pushes above do
	# not disturb the offsets).
	i = 0
	while (i < n):
		int assigned = load_int(slots + (i << 2))
		int disp = arg_base + ((n - 1 - i) << 3)
		if (assigned >= 16):
			emit_x64_load_xmm_reg(assigned - 16, ffi_arg_class(classes, i), disp)
		else if (assigned >= 0):
			emit_x64_load_gp_reg(assigned, disp)
		i = i + 1
	if (slots != 0):
		free(slots)

	emit(1, c"\xb8")               /* mov eax,imm32: xmm registers used */
	emit_int32(xmm_count)
	emit(3, c"\xff\x14\x25")       /* call qword ptr [abs32] */
	emit_int32(got_vaddr)

	# Float results come back in xmm0; W callers expect the bits in rax.
	if (ret_class == 1):
		emit(4, c"\x66\x0f\x7e\xc0")       /* movd eax,xmm0 */
	else if (ret_class == 2):
		emit(5, c"\x66\x48\x0f\x7e\xc0")   /* movq rax,xmm0 */

	emit(3, c"\x48\x89\xec")       /* mov rsp,rbp */
	emit(1, c"\x5d")               /* pop rbp */


################################# x86 cdecl ###################################

/*
cdecl call for n arguments described by classes. arg_base is the
ebp-relative offset of the top W stack word after the frame is set up:
8 inside a stub (saved ebp + return address), 4 when emitted inline.
Stack word at depth d (0 = the word on top of the W stack) sits at
[ebp + arg_base + 4 * d]; a float64 argument spans two words with the
low word at the smaller depth.
*/
void emit_c_abi_call_x86(int n, char* classes, int ret_class, int got_vaddr, int arg_base):
	if (ret_class == 2):
		error(c"float64 requires the x64 target")

	int total_words = 0
	int i = 0
	while (i < n):
		total_words = total_words + ffi_arg_words(classes, i)
		i = i + 1

	emit(1, c"\x55")           /* push ebp */
	emit(2, c"\x89\xe5")       /* mov ebp,esp */
	emit(3, c"\x83\xe4\xf0")   /* and esp,-16 */

	# Pad so the pushes finish on a 16-byte boundary.
	int pad = (16 - ((total_words << 2) & 15)) & 15
	if (pad > 0):
		emit(2, c"\x83\xec")   /* sub esp,imm8 */
		emit_int8(pad)

	# Re-push right-to-left so the leftmost argument ends on top (cdecl
	# order). Within one float64 the high word is pushed first so the low
	# word keeps the lower address.
	int depth = 0
	i = n - 1
	while (i >= 0):
		int words = ffi_arg_words(classes, i)
		int w = words - 1
		while (w >= 0):
			emit(2, c"\xff\xb5")   /* push dword [ebp+disp32] */
			emit_int32(arg_base + ((depth + w) << 2))
			w = w - 1
		depth = depth + words
		i = i - 1

	emit(2, c"\xff\x15")       /* call dword ptr [abs32] */
	emit_int32(got_vaddr)

	# Float results come back in st(0); pop the bits into eax.
	if (ret_class == 1):
		emit(3, c"\x83\xec\x04")   /* sub esp,4 */
		emit(3, c"\xd9\x1c\x24")   /* fstp dword [esp] */
		emit(3, c"\x8b\x04\x24")   /* mov eax,[esp] */

	emit(2, c"\x89\xec")       /* mov esp,ebp */
	emit(1, c"\x5d")           /* pop ebp */


############################### entry points ##################################

# Stub for an n-argument import: enters with the W frame (args + return
# address) on the stack, converts to the platform C ABI and returns the
# result W-style in eax/rax.
void emit_ffi_shim(int n, char* classes, int ret_class, int got_vaddr):
	if (word_size == 8):
		emit_c_abi_call_x64(n, classes, ret_class, got_vaddr, 16)
	else:
		emit_c_abi_call_x86(n, classes, ret_class, got_vaddr, 8)
	emit(1, c"\xc3")           /* ret */


# The same conversion emitted inline at a call site: the n arguments were
# just pushed onto the W stack (no return address between them and sp).
# Used for variadic imports, whose per-call float classes rule out a
# single per-function stub. The caller still pops its argument words.
void emit_ffi_call_inline(int n, char* classes, int ret_class, int got_vaddr):
	if (word_size == 8):
		emit_c_abi_call_x64(n, classes, ret_class, got_vaddr, 8)
	else:
		emit_c_abi_call_x86(n, classes, ret_class, got_vaddr, 4)
