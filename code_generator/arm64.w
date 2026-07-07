/*
AArch64 (ARM64) instruction emitter — the A64 twin of code_generator/x86.w.

The cc500 stack-machine model is preserved with a fixed register map:

  x0  = accumulator          (the x86 backend's eax)
  x1  = secondary operand    (ebx)
  x2  = shift count scratch  (ecx)
  x9, x10 = general scratch for materialized immediates / addresses
  x28 = the W evaluation stack pointer (NOT the real sp)

AArch64 faults on sp-based accesses that are not 16-byte aligned, and W
pushes single 8-byte words constantly, so the real sp cannot be the W
stack. x28 holds it instead; the entry stub sets x28 = sp and the kernel's
sp is left for signal frames. Pushes are str x0,[x28,#-8]! and pops are
ldr x0,[x28],#8.

A64 has no hardware call stack: bl/blr leave the return address in x30.
To keep the x86 argument-addressing math (which counts a return-address
slot) unchanged, every W function's prologue pushes x30 onto the x28 stack
(be_function_prologue) and the epilogue pops it (ret()). Return addresses
are signed with PAC (pacia x30,x28) using the W stack pointer as the
modifier, and authenticated before return (autia) — the --pac=ret model.

All instructions are 4 bytes, emitted little-endian via emit_int32. Every
encoding here was checked against binutils' assembler output.

This file is compiled by the committed seed, so it uses only seed-known
syntax. Emission is gated on target_isa (0 = x86 family, 1 = arm64) which
the x86.w helpers branch on, so x86/x64 output stays byte-identical.
*/
import code_generator.code_emitter


void error(char *s);       /* from diagnostics.w */
void emit_x64_opcode();    /* from x86.w (used on the x86 path of be_lea) */


void a64(int w):
	emit_int32(w)


# Compose a 32-bit A64 instruction word from its most-significant byte and
# the low 24 bits. Both operands are below 2^31, so the self-hosting
# compiler encodes them identically whether it runs as a 32- or 64-bit
# process; a bare 0x8....... literal would be negative on the 32-bit host and
# break the self-host fixpoint (see the "high-bit literal" note in
# grammar/unary_expression.w). The << 24 is a runtime shift, not a folded
# constant. Callers OR in wider fields (branch imm19/imm26) after this base.
int op(int msb, int low):
	return (msb << 24) | low


# Load a sign-extended 32-bit (or small) immediate into register `reg`.
# Small non-negative values use a single movz; everything else uses a
# PC-relative literal (ldr; b over the 8-byte word) so negative values and
# the full 32-bit range are handled uniformly.
void arm64_load_scratch(int reg, int v):
	if ((v >= 0) & (v <= 65535)):
		a64(op(0xd2, 0x800000) | (v << 5) | reg)   # movz Xreg, #v
		return
	a64(op(0x58, 0x000040) | reg)   # ldr Xreg, [pc, #8]
	a64(op(0x14, 0x000003))         # b .+12 (skip the 8-byte literal)
	emit_int64(v)


# ldr/str Xrt,[x28, #k] with k a byte offset (always a multiple of 8 for
# stack slots). Uses the scaled unsigned-offset form when it fits, else a
# materialized register offset.
void arm64_ldr_reg_wsp(int rt, int k):
	int widx = k >> 3
	if ((k >= 0) & ((k & 7) == 0) & (widx <= 4095)):
		a64(op(0xf9, 0x400380) | (widx << 10) | rt)   # ldr Xrt,[x28,#k]
		return
	arm64_load_scratch(9, k)
	a64(op(0xf8, 0x696b80) | rt)   # ldr Xrt,[x28,x9]


void arm64_str_reg_wsp(int rt, int k):
	int widx = k >> 3
	if ((k >= 0) & ((k & 7) == 0) & (widx <= 4095)):
		a64(op(0xf9, 0x000380) | (widx << 10) | rt)   # str Xrt,[x28,#k]
		return
	arm64_load_scratch(9, k)
	a64(op(0xf8, 0x296b80) | rt)   # str Xrt,[x28,x9]


# add x9, x9, #imm (imm may be negative); used by the [esp+k] += imm helpers.
void arm64_add_x9_imm(int imm):
	if ((imm >= 0) & (imm <= 4095)):
		a64(op(0x91, 0x000529) | (imm << 10))   # add x9,x9,#imm
		return
	if ((imm < 0) & (0 - imm <= 4095)):
		a64(op(0xd1, 0x000529) | ((0 - imm) << 10))   # sub x9,x9,#(-imm)
		return
	arm64_load_scratch(10, imm)
	a64(op(0x8b, 0x0a0129))   # add x9,x9,x10


####################### immediates into the accumulator ######################

void arm64_mov_eax_int32(int v):
	a64(op(0x18, 0x000040))   # ldr w0, [pc, #8]
	a64(op(0x14, 0x000002))   # b .+8 (skip the 4-byte literal)
	emit_int32(v)


void arm64_mov_rax_int64(int v):
	arm64_load_scratch(0, v)


void arm64_mov_rax_int64_halves(int lo, int hi):
	a64(op(0x58, 0x000040))   # ldr x0, [pc, #8]
	a64(op(0x14, 0x000003))   # b .+12 (skip the 8-byte literal)
	emit_int32(lo)
	emit_int32(hi)


void arm64_push_imm(int v):
	arm64_load_scratch(9, v)
	a64(op(0xf8, 0x1f8f89))   # str x9,[x28,#-8]!


void arm64_add_eax_int32(int v):
	if ((v >= 0) & (v <= 4095)):
		a64(op(0x91, 0x000000) | (v << 10))   # add x0,x0,#v
		return
	if ((v < 0) & (0 - v <= 4095)):
		a64(op(0xd1, 0x000000) | ((0 - v) << 10))   # sub x0,x0,#(-v)
		return
	arm64_load_scratch(9, v)
	a64(op(0x8b, 0x090000))   # add x0,x0,x9


void arm64_add_ebx_int32(int v):
	if ((v >= 0) & (v <= 4095)):
		a64(op(0x91, 0x000021) | (v << 10))   # add x1,x1,#v
		return
	if ((v < 0) & (0 - v <= 4095)):
		a64(op(0xd1, 0x000021) | ((0 - v) << 10))   # sub x1,x1,#(-v)
		return
	arm64_load_scratch(9, v)
	a64(op(0x8b, 0x090021))   # add x1,x1,x9


void arm64_imul_eax_int32(int v):
	arm64_load_scratch(9, v)
	a64(op(0x9b, 0x097c00))   # mul x0,x0,x9


############################## stack machine ################################

void arm64_be_pop(int n):
	int b = n << 3
	if ((b >= 0) & (b <= 4095)):
		a64(op(0x91, 0x00039c) | (b << 10))   # add x28,x28,#b
		return
	arm64_load_scratch(9, b)
	a64(op(0x8b, 0x09039c))   # add x28,x28,x9


void arm64_lea_eax_esp_plus(int k):
	if ((k >= 0) & (k <= 4095)):
		a64(op(0x91, 0x000380) | (k << 10))   # add x0,x28,#k
		return
	arm64_load_scratch(9, k)
	a64(op(0x8b, 0x090380))   # add x0,x28,x9


void arm64_push_eax_plus(int v):
	int widx = v >> 3
	if ((v >= 0) & ((v & 7) == 0) & (widx <= 4095)):
		a64(op(0xf9, 0x400009) | (widx << 10))   # ldr x9,[x0,#v]
	else:
		arm64_load_scratch(10, v)
		a64(op(0xf8, 0x6a6809))   # ldr x9,[x0,x10]
	a64(op(0xf8, 0x1f8f89))   # str x9,[x28,#-8]!


void arm64_inc_dword_esp_plus(int v):
	arm64_ldr_reg_wsp(9, v)
	a64(op(0x91, 0x000529))   # add x9,x9,#1
	arm64_str_reg_wsp(9, v)


void arm64_add_dword_esp_plus_eax(int v):
	arm64_ldr_reg_wsp(9, v)
	a64(op(0x8b, 0x000129))   # add x9,x9,x0
	arm64_str_reg_wsp(9, v)


void arm64_add_stack_word_int32(int offset, int v):
	arm64_ldr_reg_wsp(9, offset)
	arm64_add_x9_imm(v)
	arm64_str_reg_wsp(9, offset)


################################## branches #################################
# Patchable branches keep the x86 protocol: the caller records the codepos
# right AFTER the branch as the patch "site", the instruction lives at
# site-4, and the pending link (for jump chains) or displacement is stored
# in the instruction's immediate field, scaled by 4. Unconditional jumps
# are `b` (imm26, +/-128MB); zero/nonzero tests fold into cbz/cbnz (imm19,
# +/-1MB, always intra-function here).

void arm64_emit_b(int v):
	a64(op(0x14, 0x000000) | ((v >> 2) & op(0x03, 0xffffff)))   # b (link/placeholder in imm26)


void arm64_emit_cbz(int v):
	a64(op(0xb4, 0x000000) | (((v >> 2) & 0x7ffff) << 5))   # cbz x0


void arm64_emit_cbnz(int v):
	a64(op(0xb5, 0x000000) | (((v >> 2) & 0x7ffff) << 5))   # cbnz x0


# Patch the branch at site-4 to jump to `target` (a codepos). Preserves the
# opcode and register fields, rewriting only the immediate.
void arm64_branch_patch(int site, int target):
	int word = load_int32(code + site - 4)
	int offset = target - (site - 4)
	int enc = offset >> 2
	int top6 = (word >> 26) & 0x3f
	if (top6 == 0x05):
		save_int32(code + site - 4, (word & op(0xfc, 0x000000)) | (enc & op(0x03, 0xffffff)))
	else:
		save_int32(code + site - 4, (word & op(0xff, 0x00001f)) | ((enc & 0x7ffff) << 5))


int arm64_branch_link_get(int site):
	int word = load_int32(code + site - 4)
	int top6 = (word >> 26) & 0x3f
	if (top6 == 0x05):
		return (word & op(0x03, 0xffffff)) << 2
	return ((word >> 5) & 0x7ffff) << 2


################################ comparisons ################################
# x86 setcc opcode -> AArch64 condition code.
int arm64_setcc_cond(int setcc):
	if (setcc == 0x94):
		return 0    # eq
	if (setcc == 0x95):
		return 1    # ne
	if (setcc == 0x9c):
		return 11   # lt (signed <)
	if (setcc == 0x9d):
		return 10   # ge
	if (setcc == 0x9e):
		return 13   # le
	if (setcc == 0x9f):
		return 12   # gt
	if (setcc == 0x92):
		return 3    # lo (unsigned <)
	if (setcc == 0x93):
		return 2    # hs (unsigned >=)
	if (setcc == 0x96):
		return 9    # ls (unsigned <=)
	if (setcc == 0x97):
		return 8    # hi (unsigned >)
	error(c"arm64: unsupported setcc opcode")
	return 0


# CSET encodes the INVERTED condition (CSINC with Rn=Rm=xzr). Flip the low
# bit without a binary xor operator (which W's grammar lacks).
void arm64_cset(int cond):
	int inv = cond + 1 - 2 * (cond & 1)
	a64(op(0x9a, 0x9f07e0) | (inv << 12))   # cset x0, <cond>


# cmp x1,x0 ; cset x0,<cond>  (x1 is the left operand, x0 the right)
void arm64_alu_cmp_set(int setcc):
	a64(op(0xeb, 0x00003f))   # cmp x1, x0
	arm64_cset(arm64_setcc_cond(setcc))


# cmp x0,#0 ; cset x0,<cond>
void arm64_alu_test_set(int setcc):
	a64(op(0xf1, 0x00001f))   # cmp x0, #0
	arm64_cset(arm64_setcc_cond(setcc))


############################### bounds checks ###############################
# Each trap is a compare, a conditional skip over the next instruction, and
# brk #0 (SIGTRAP, like the x86 int3).

void arm64_bounds_check_eax_nonnegative():
	a64(op(0xf1, 0x00001f))   # cmp x0, #0
	a64(op(0x54, 0x00004a))   # b.ge .+8
	a64(op(0xd4, 0x200000))   # brk #0


void arm64_bounds_check_ebx_less_eax():
	a64(op(0xeb, 0x00003f))   # cmp x1, x0
	a64(op(0x54, 0x00004b))   # b.lt .+8
	a64(op(0xd4, 0x200000))   # brk #0


void arm64_bounds_check_ebx_less_equal_eax():
	a64(op(0xeb, 0x00003f))   # cmp x1, x0
	a64(op(0x54, 0x00004d))   # b.le .+8
	a64(op(0xd4, 0x200000))   # brk #0


void arm64_bounds_check_eax_less_equal_int32(int limit):
	arm64_load_scratch(9, limit)
	a64(op(0xeb, 0x09001f))   # cmp x0, x9
	a64(op(0x54, 0x00004d))   # b.le .+8
	a64(op(0xd4, 0x200000))   # brk #0


############################## abstractions #################################
# These be_* helpers are called from symbol_table.w and the grammar. On the
# x86 family they reproduce the original bytes exactly; on arm64 they emit
# the A64 form. Kept here so all arch knowledge lives in one file.

# Pointer-authentication level for arm64 return addresses: 1 = pac=ret (the
# default), 0 = off. Set in link_impl.
int arm64_pac


# Emit an address slot: on x86 a `mov eax, imm32` whose imm32 doubles as a
# backpatch-chain cell; on arm64 an ldr-literal that ends in the same
# contiguous 4-byte cell (code addresses are < 2^31, so ldr w0 zero-extends
# correctly). The caller writes/threads the cell via save_int/load_int at
# codepos-4, unchanged across targets.
void be_addr_slot_emit():
	if (target_isa == 1):
		a64(op(0x18, 0x000040))   # ldr w0, [pc, #8]
		a64(op(0x14, 0x000002))   # b .+8
		emit_int32(0)     # the 4-byte address/link cell
		return
	emit(5, c"\xb8....")   # mov $imm32,%eax


# Leave the address of the W-stack slot at byte offset k in the accumulator.
# On x86 this reproduces lea_eax_esp_plus(0) followed by patching the disp32
# to k (byte-identical to the original sym_get_value sequence).
void be_lea_acc_wstack(int k):
	if (target_isa == 1):
		arm64_lea_eax_esp_plus(k)
		return
	emit_x64_opcode()
	emit(3, c"\x8d\x84\x24")
	emit_int(0)
	save_int(code + codepos - 4, k)


# Patch a recorded branch site to the current position (or a given target).
void be_branch_patch(int site, int target):
	if (target_isa == 1):
		arm64_branch_patch(site, target)
		return
	save_int32(code + site - 4, target - site)


int be_branch_link_get(int site):
	if (target_isa == 1):
		return arm64_branch_link_get(site)
	return load_int32(code + site - 4)


# Round the code cursor up to a 4-byte boundary on arm64 (a no-op on x86).
# Called after inline data (string bytes, descriptor blobs) so the next
# instruction stays aligned, which AArch64 requires.
void be_align_code():
	if (target_isa == 1):
		while ((codepos & 3) != 0):
			emit_int8(0)


# Function prologue: sign the return address and push it onto the W stack so
# the callee has the same [return-slot | args...] layout the x86 backend
# relies on. Emitted right after the function's symbol address is fixed.
void be_function_prologue():
	if (target_isa == 1):
		if (arm64_pac):
			a64(op(0xda, 0xc1039e))   # pacia x30, x28
		a64(op(0xf8, 0x1f8f9e))   # str x30, [x28, #-8]!
