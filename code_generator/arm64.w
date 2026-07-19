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
void sym_define_global(int current_symbol);          /* symbol_table.w */
void sym_define_global_at(int current_symbol, int v);
int sym_declare_global(char *s, int type, int symtype);


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
	if ((v >= 0) && (v <= 65535)):
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
	if ((k >= 0) && ((k & 7) == 0) && (widx <= 4095)):
		a64(op(0xf9, 0x400380) | (widx << 10) | rt)   # ldr Xrt,[x28,#k]
		return
	arm64_load_scratch(9, k)
	a64(op(0xf8, 0x696b80) | rt)   # ldr Xrt,[x28,x9]


void arm64_str_reg_wsp(int rt, int k):
	int widx = k >> 3
	if ((k >= 0) && ((k & 7) == 0) && (widx <= 4095)):
		a64(op(0xf9, 0x000380) | (widx << 10) | rt)   # str Xrt,[x28,#k]
		return
	arm64_load_scratch(9, k)
	a64(op(0xf8, 0x296b80) | rt)   # str Xrt,[x28,x9]


# add x9, x9, #imm (imm may be negative); used by the [esp+k] += imm helpers.
# The base words carry Rn=Rd=x9 only (0x129); until #174 they pre-set imm12
# bit 0 (0x529, copied from the +1 increment), so every even immediate
# OR'd in below encoded #(imm|1).
void arm64_add_x9_imm(int imm):
	if ((imm >= 0) && (imm <= 4095)):
		a64(op(0x91, 0x000129) | (imm << 10))   # add x9,x9,#imm
		return
	if ((imm < 0) && (0 - imm <= 4095)):
		a64(op(0xd1, 0x000129) | ((0 - imm) << 10))   # sub x9,x9,#(-imm)
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
	if ((v >= 0) && (v <= 4095)):
		a64(op(0x91, 0x000000) | (v << 10))   # add x0,x0,#v
		return
	if ((v < 0) && (0 - v <= 4095)):
		a64(op(0xd1, 0x000000) | ((0 - v) << 10))   # sub x0,x0,#(-v)
		return
	arm64_load_scratch(9, v)
	a64(op(0x8b, 0x090000))   # add x0,x0,x9


void arm64_add_ebx_int32(int v):
	if ((v >= 0) && (v <= 4095)):
		a64(op(0x91, 0x000021) | (v << 10))   # add x1,x1,#v
		return
	if ((v < 0) && (0 - v <= 4095)):
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
	if ((b >= 0) && (b <= 4095)):
		a64(op(0x91, 0x00039c) | (b << 10))   # add x28,x28,#b
		return
	arm64_load_scratch(9, b)
	a64(op(0x8b, 0x09039c))   # add x28,x28,x9


void arm64_lea_eax_esp_plus(int k):
	if ((k >= 0) && (k <= 4095)):
		a64(op(0x91, 0x000380) | (k << 10))   # add x0,x28,#k
		return
	arm64_load_scratch(9, k)
	a64(op(0x8b, 0x090380))   # add x0,x28,x9


void arm64_push_eax_plus(int v):
	int widx = v >> 3
	if ((v >= 0) && ((v & 7) == 0) && (widx <= 4095)):
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
# bit without the binary ^ operator, which the committed seed compiling
# this file does not know yet.
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
# Each check is a compare plus a b.cond threaded into a control-region patch
# chain (issue #228, docs/projects/wasm_backend.md D3): the caller passes the
# region's current chain head, which is encoded into the imm19 field exactly
# like the other chained branch forms, and records the new head (codepos)
# with be_ctrl_link. The grammar layer ends the failing branches' region at
# a trap block that calls the runtime diagnostic helper (see
# grammar/postfix_expr.w).

# b.cond with the chain link in its displacement field.
void arm64_bounds_branch(int cond, int link):
	a64(op(0x54, 0x000000) | cond | (((link >> 2) & 0x7ffff) << 5))


void arm64_bounds_branch_eax_negative(int link):
	a64(op(0xf1, 0x00001f))   # cmp x0, #0
	arm64_bounds_branch(11, link)   # b.lt


void arm64_bounds_branch_ebx_negative(int link):
	a64(op(0xf1, 0x00003f))   # cmp x1, #0
	arm64_bounds_branch(11, link)   # b.lt


void arm64_bounds_branch_ebx_greater_eax(int link):
	a64(op(0xeb, 0x00003f))   # cmp x1, x0
	arm64_bounds_branch(12, link)   # b.gt


void arm64_bounds_skip_ebx_less_eax(int link):
	a64(op(0xeb, 0x00003f))   # cmp x1, x0
	arm64_bounds_branch(11, link)   # b.lt


void arm64_bounds_skip_ebx_less_equal_eax(int link):
	a64(op(0xeb, 0x00003f))   # cmp x1, x0
	arm64_bounds_branch(13, link)   # b.le


void arm64_bounds_skip_eax_less_equal_int32(int limit, int link):
	arm64_load_scratch(9, limit)
	a64(op(0xeb, 0x09001f))   # cmp x0, x9
	arm64_bounds_branch(13, link)   # b.le


############################## abstractions #################################
# These be_* helpers are called from symbol_table.w and the grammar. On the
# x86 family they reproduce the original bytes exactly; on arm64 they emit
# the A64 form. Kept here so all arch knowledge lives in one file.

# Pointer-authentication level for arm64: 0 = off, 1 = pac=ret (the
# default: sign return addresses), 2 = pac=full (additionally sign W
# function pointers at materialization with the IA key and zero
# discriminator; indirect calls authenticate with blraaz). Set in
# link_impl, whole-program (see the --pac pre-scan there).
int arm64_pac


# Emit an address slot: on x86 a `mov eax, imm32` whose imm32 doubles as a
# backpatch-chain cell; on arm64 an adrp+add pair, which is PC-relative
# and therefore slide-proof (PIE groundwork for the Mach-O target — the
# kernel slides the image and nothing applies relocations, so absolute
# literals in code would break). The slot's stored value lives split
# across the two immediates; callers read and thread it through the
# be_addr_slot_read/write helpers at position codepos-4, the same
# convention the old contiguous 4-byte cell used (the "cell" is now the
# add instruction, with the adrp one word before it).
void be_addr_slot_emit():
	if (target_isa == 2):
		wasm_addr_slot_emit()
		return
	if (target_isa == 1):
		a64(op(0x90, 0x000000))   # adrp x0, . (page immediate patched)
		a64(op(0x91, 0x000000))   # add x0, x0, #0 (pageoff patched)
		return
	emit(5, c"\xb8....")   # mov $imm32,%eax


# Store value v (a vaddr, or a backpatch-chain link, both < 2^31) into
# the address slot whose add instruction sits at buffer offset pos. The
# adrp page immediate is the page delta from the adrp's own vaddr
# (immhi:immlo, signed 21 bits) and the add imm12 holds the low 12 bits,
# so ANY 31-bit value round-trips exactly through write+read — required
# because unfinished slots store chain links, not final addresses.
void arm64_addr_slot_write(int pos, int v):
	int adrp_vaddr = code_offset + pos - 4
	int delta = (v >> 12) - (adrp_vaddr >> 12)
	int immlo = delta & 3
	int immhi = (delta >> 2) & 0x7ffff
	save_int32(code + pos - 4, op(0x90 | (immlo << 5), immhi << 5))
	save_int32(code + pos, op(0x91, 0x000000) | ((v & 0xfff) << 10))


int arm64_addr_slot_read(int pos):
	int adrp_vaddr = code_offset + pos - 4
	int word = load_int32(code + pos - 4)
	int immlo = (word >> 29) & 3
	int immhi = (word >> 5) & 0x7ffff
	int delta = (immhi << 2) | immlo
	if (delta & 0x100000):
		delta = delta - 0x200000
	int page = (adrp_vaddr >> 12) + delta
	int addw = load_int32(code + pos)
	return (page << 12) | ((addw >> 10) & 0xfff)


# Read/write the value threaded through an address slot. pos is the
# buffer offset of the slot's last 4 bytes (codepos-4 right after
# be_addr_slot_emit, or a recorded chain link minus code_offset). On the
# x86 family the slot is a plain imm32 cell, byte-identical to the
# original save_int/load_int accesses; on arm64 the value is
# reassembled from the adrp+add immediates.
void be_addr_slot_write(int pos, int v):
	if (target_isa == 2):
		wasm_addr_slot_write(pos, v)
		return
	if (target_isa == 1):
		arm64_addr_slot_write(pos, v)
		return
	save_int(code + pos, v)


int be_addr_slot_read(int pos):
	if (target_isa == 2):
		return wasm_addr_slot_read(pos)
	if (target_isa == 1):
		return arm64_addr_slot_read(pos)
	return load_int(code + pos)


# Leave the address of the W-stack slot at byte offset k in the accumulator.
# On x86 this reproduces lea_eax_esp_plus(0) followed by patching the disp32
# to k (byte-identical to the original sym_get_value sequence).
void be_lea_acc_wstack(int k):
	if (target_isa == 3):
		ptx_lea_ax_sp(k)
		return
	if (target_isa == 2):
		wasm_lea_eax_esp_plus(k)
		return
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


# Sign the code pointer in the accumulator (IA key, zero discriminator).
# Called by sym_get_value when a function's address becomes a value; the
# matching authentication is the blraaz in call_eax. Zero discriminator
# keeps signed function pointers position-independent (struct moves and
# equality compares keep working) — W's own convention, see arm64.md D6.
void be_code_ptr_sign():
	if (target_isa == 1):
		if (arm64_pac == 2):
			a64(op(0xda, 0xc123e0))   # paciza x0


# Function prologue: sign the return address and push it onto the W stack so
# the callee has the same [return-slot | args...] layout the x86 backend
# relies on. Emitted right after the function's symbol address is fixed.
# Define a function symbol at the position be_function_prologue is about
# to open. On the native targets a function's address is its code
# position; on wasm it is its table index (the prologue's
# wasm_function_begin assigns the next one). Nothing may emit between
# this call and the prologue.
void be_function_define(int current_symbol, char* name):
	if (target_isa == 2):
		sym_define_global_at(current_symbol, wasm_func_count + 1)
		wasm_func_name_note(wasm_func_count + 1, name)
		return
	sym_define_global(current_symbol)


# declare + define in one step (runtime-synthesized functions like
# __w_test_main; the sym_define_declare_global_function twin that is
# function-table aware).
int be_function_define_declare(char* name):
	int t = sym_declare_global(name, 4, 2)
	be_function_define(t, name)
	return t


# Close a function body: on wasm the unit's `end` opcode plus the body
# size patch; nothing on the native targets. Called right after the
# body's final ret().
void be_function_epilogue():
	if (target_isa == 2):
		wasm_function_end()


void be_function_prologue():
	if (target_isa == 2):
		wasm_function_begin()
		return
	if (target_isa == 1):
		if (arm64_pac):
			a64(op(0xda, 0xc1039e))   # pacia x30, x28
		a64(op(0xf8, 0x1f8f9e))   # str x30, [x28, #-8]!
