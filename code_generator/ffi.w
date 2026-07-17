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
  x64  Windows:  the first four args positionally in rcx/rdx/r8/r9 or
                 xmm0..xmm3, the rest on the stack above the caller's
                 32-byte shadow space. Float args among the first four
                 also load their GP register (the win64 varargs
                 contract). Selected when target_os is 2 (win64).
  x86  cdecl:    all args re-pushed right-to-left onto a 16-byte-aligned
                 stack (float32 bits pass through unchanged; float64 spans
                 two words). Float results come back in st(0) and are
                 popped into eax.
  a64  AAPCS64:  integer args in x0..x7, float args in v0..v7, overflow in
                 8-byte stack slots (Linux only; arm64_darwin packs stack
                 args at natural size, so overflow is rejected there).
                 Float results come back in s0/d0 and are moved to x0.
                 Selected when target_isa is 1 (both arm64 targets).

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
void movd_xmm0_eax();
void cvtss2sd_xmm0();
void movq_rax_xmm0();
void push_eax();
void a64(int w);
int op(int msb, int low);
void arm64_ldr_reg_wsp(int rt, int k);


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


############################### x64 Windows ##################################

# mov <gp reg>,[rbp+disp32] for argument registers 0..3 (rcx rdx r8 r9).
void emit_win64_load_gp_reg(int reg, int disp):
	if (reg == 0):
		emit(3, c"\x48\x8b\x8d")   /* mov rcx,[rbp+disp32] */
	else if (reg == 1):
		emit(3, c"\x48\x8b\x95")   /* mov rdx,[rbp+disp32] */
	else if (reg == 2):
		emit(3, c"\x4c\x8b\x85")   /* mov r8,[rbp+disp32] */
	else:
		emit(3, c"\x4c\x8b\x8d")   /* mov r9,[rbp+disp32] */
	emit_int32(disp)


/*
Microsoft x64 call for n arguments described by classes. Argument slots
are positional: argument i (i < 4) goes in GP register i or xmm i, the
rest go on the stack after the 32-byte shadow space. arg_base follows the
same convention as emit_c_abi_call_x64: rbp-relative offset of the LAST
argument, 16 inside a stub, 8 inline at a call site.
*/
void emit_c_abi_call_win64(int n, char* classes, int ret_class, int got_vaddr, int arg_base):
	emit(1, c"\x55")               /* push rbp */
	emit(3, c"\x48\x89\xe5")       /* mov rbp,rsp */
	emit(4, c"\x48\x83\xe4\xf0")   /* and rsp,-16 */

	# Shadow space plus stack arguments, kept 16-byte aligned so rsp is
	# aligned at the call instruction.
	int stack_args = 0
	if (n > 4):
		stack_args = n - 4
	int frame = 32 + (stack_args << 3)
	if ((frame & 15) != 0):
		frame = frame + 8
	emit(3, c"\x48\x81\xec")       /* sub rsp,imm32 */
	emit_int32(frame)

	# Stack arguments: argument 4 + k lands at [rsp + 32 + 8k]. The whole
	# 8-byte W word is copied; float32 callees read the low 4 bytes.
	int i = 4
	while (i < n):
		emit(3, c"\x48\x8b\x85")       /* mov rax,[rbp+disp32] */
		emit_int32(arg_base + ((n - 1 - i) << 3))
		emit(4, c"\x48\x89\x84\x24")   /* mov [rsp+disp32],rax */
		emit_int32(32 + ((i - 4) << 3))
		i = i + 1

	# Register arguments. Float args load both files: variadic callees
	# fetch them from the GP registers (the win64 va_arg contract) while
	# fixed callees read the xmm registers and ignore the duplicates.
	i = 0
	while (i < 4):
		if (i < n):
			int disp = arg_base + ((n - 1 - i) << 3)
			emit_win64_load_gp_reg(i, disp)
			if (ffi_arg_class(classes, i) != 0):
				emit_x64_load_xmm_reg(i, ffi_arg_class(classes, i), disp)
		i = i + 1

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


############################### AArch64 AAPCS64 ##############################

# ldr S<reg>/D<reg>, [x28, #off] for float argument registers v0..v7. The
# W stack offset is a multiple of 8, so the scaled unsigned-offset form
# always fits.
void emit_arm64_load_fp_reg(int reg, int arg_class, int off):
	if (arg_class == 2):
		a64(op(0xfd, 0x400380) | ((off >> 3) << 10) | reg)   # ldr D<reg>,[x28,#off]
	else:
		a64(op(0xbd, 0x400380) | ((off >> 2) << 10) | reg)   # ldr S<reg>,[x28,#off]


/*
AAPCS64 call for n arguments described by classes. The arguments sit on
the W stack (x28) with nothing between them and the stack top: argument i
of n at [x28 + 8 * (n - 1 - i)]. That layout holds both inside a stub
(blr enters it with the return address only in x30, never on the W stack)
and at an inline variadic call site, so one emitter serves both and there
is no arg_base parameter.

The W stack occupies the memory directly below the real sp (the entry
stub adopts sp as x28 and never moves sp), so pushing a C frame at sp
would overwrite the oldest W stack words. Instead the frame is parked
below x28: saved x29/x30 and the caller's sp at the top, then the
overflow-argument area, with sp restored after the call. x28 and x29 are
callee-saved in AAPCS64, so the C callee preserves the W stack pointer
and the frame anchor.
*/
void emit_c_abi_call_arm64(int n, char* classes, int ret_class, int got_vaddr):
	# Assign each argument a slot: 0..7 = x register, 16 + k = v register
	# k, -1 = stack. Classification walks left to right (AAPCS64 NGRN/NSRN
	# counters, matching the SysV walk above).
	char* slots = 0
	if (n > 0):
		slots = malloc(n * 4)
	int gp_count = 0
	int fp_count = 0
	int stack_count = 0
	int i = 0
	while (i < n):
		int slot = 0 - 1
		if (ffi_arg_class(classes, i) == 0):
			if (gp_count < 8):
				slot = gp_count
				gp_count = gp_count + 1
		else:
			if (fp_count < 8):
				slot = 16 + fp_count
				fp_count = fp_count + 1
		if (slot < 0):
			stack_count = stack_count + 1
		save_int(slots + (i << 2), slot)
		i = i + 1

	# Darwin packs on-stack arguments at natural size instead of 8-byte
	# slots, which the three-class model cannot express; no binding we
	# author needs overflow arguments, so reject rather than guess.
	if ((target_os == 1) && (stack_count > 0)):
		error(c"arm64_darwin extern calls support at most 8 integer and 8 float arguments")

	a64(op(0x91, 0x0003e9))   # mov x9, sp        (the caller's sp)
	a64(op(0xd1, 0x00838a))   # sub x10, x28, #32
	a64(op(0x92, 0x7ced4a))   # and x10, x10, #0xfffffffffffffff0
	a64(op(0x91, 0x00015f))   # mov sp, x10
	a64(op(0xa9, 0x007bfd))   # stp x29, x30, [sp]
	a64(op(0xf9, 0x000be9))   # str x9, [sp, #16]  (the caller's sp)
	a64(op(0x91, 0x0003fd))   # mov x29, sp        (frame anchor)

	# Overflow area: the leftmost overflow argument lands at [sp] (the
	# AAPCS64 memory order), one 8-byte slot each, size kept 16-aligned.
	int spill = ((stack_count << 3) + 15) & (0 - 16)
	if (spill > 0):
		a64(op(0xd1, 0x0003ff) | (spill << 10))   # sub sp, sp, #spill
	int k = 0
	i = 0
	while (i < n):
		if (load_int(slots + (i << 2)) < 0):
			arm64_ldr_reg_wsp(9, (n - 1 - i) << 3)
			a64(op(0xf9, 0x0003e9) | (k << 10))   # str x9, [sp, #8k]
			k = k + 1
		i = i + 1

	# Register arguments (x28-relative, unaffected by the sp moves).
	i = 0
	while (i < n):
		int assigned = load_int(slots + (i << 2))
		int off = (n - 1 - i) << 3
		if (assigned >= 16):
			emit_arm64_load_fp_reg(assigned - 16, ffi_arg_class(classes, i), off)
		else if (assigned >= 0):
			arm64_ldr_reg_wsp(assigned, off)
		i = i + 1
	if (slots != 0):
		free(slots)

	# Call through the GOT slot. The adrp page delta is computed at emit
	# time and survives the PIE slide because the data segment keeps its
	# fixed distance from the text segment (same math as
	# arm64_addr_slot_write).
	int pc = code_offset + codepos
	int delta = (got_vaddr >> 12) - (pc >> 12)
	int immlo = delta & 3
	int immhi = (delta >> 2) & 0x7ffff
	a64(op(0x90 | (immlo << 5), immhi << 5) | 16)           # adrp x16, page(got)
	a64(op(0x91, 0x000210) | ((got_vaddr & 0xfff) << 10))   # add x16, x16, #lo12
	a64(op(0xf9, 0x400210))   # ldr x16, [x16]
	# Deliberately a plain blr even under --pac=full: imported C pointers
	# are bound unsigned by the dynamic linker (plain arm64 convention),
	# so there is no signature to authenticate.
	a64(op(0xd6, 0x3f0200))   # blr x16

	# Float results come back in s0/d0; W callers expect the bits in x0.
	if (ret_class == 1):
		a64(op(0x1e, 0x260000))   # fmov w0, s0
	else if (ret_class == 2):
		a64(op(0x9e, 0x660000))   # fmov x0, d0

	a64(op(0x91, 0x0003bf))   # mov sp, x29       (drop the overflow area)
	a64(op(0xf9, 0x400be9))   # ldr x9, [sp, #16]
	a64(op(0xa9, 0x407bfd))   # ldp x29, x30, [sp]
	a64(op(0x91, 0x00013f))   # mov sp, x9        (restore the caller's sp)


############################### entry points ##################################

# Stub for an n-argument import: enters with the W frame (args + return
# address) on the stack, converts to the platform C ABI and returns the
# result W-style in eax/rax.
void emit_ffi_shim(int n, char* classes, int ret_class, int got_vaddr):
	if (target_isa == 1):
		emit_c_abi_call_arm64(n, classes, ret_class, got_vaddr)
		a64(op(0xd6, 0x5f03c0))   # ret
		return
	if (target_os == 2):
		emit_c_abi_call_win64(n, classes, ret_class, got_vaddr, 16)
	else if (word_size == 8):
		emit_c_abi_call_x64(n, classes, ret_class, got_vaddr, 16)
	else:
		emit_c_abi_call_x86(n, classes, ret_class, got_vaddr, 8)
	emit(1, c"\xc3")           /* ret */


# The same conversion emitted inline at a call site: the n arguments were
# just pushed onto the W stack (no return address between them and sp).
# Used for variadic imports, whose per-call float classes rule out a
# single per-function stub. The caller still pops its argument words.
void emit_ffi_call_inline(int n, char* classes, int ret_class, int got_vaddr):
	if (target_isa == 1):
		# A variadic callee on Darwin reads its variadic tail from the
		# stack even when the named arguments fit in registers, which
		# this register-based conversion cannot express.
		if (target_os == 1):
			error(c"variadic extern calls are not supported on arm64_darwin yet")
		emit_c_abi_call_arm64(n, classes, ret_class, got_vaddr)
		return
	if (target_os == 2):
		emit_c_abi_call_win64(n, classes, ret_class, got_vaddr, 8)
	else if (word_size == 8):
		emit_c_abi_call_x64(n, classes, ret_class, got_vaddr, 8)
	else:
		emit_c_abi_call_x86(n, classes, ret_class, got_vaddr, 4)


# C variadic calls apply the default argument promotions, so a float32
# argument widens to float64 before the call. Takes the float32 bits in
# eax and pushes the promoted value; returns the number of W stack words
# pushed (a float64 spans two words on x86).
int ffi_push_promoted_float32():
	movd_xmm0_eax()
	cvtss2sd_xmm0()
	if (word_size == 8):
		movq_rax_xmm0()
		push_eax()
		return 1
	emit(3, c"\x83\xec\x08")           /* sub esp,8 */
	emit(5, c"\xf2\x0f\x11\x04\x24")   /* movsd [esp],xmm0 */
	return 2
