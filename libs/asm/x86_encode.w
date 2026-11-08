/*
x86 (32-bit) / x86-64 instruction encoder for the assembler/disassembler
libraries (docs/projects/assembler_disassembler.md, issues #166/#167):
the inverse of libs/asm/x86_decode.w. asm_x86_encode() writes a
structured asm_insn into an asm_buffer.

Encoding is many-to-one, and the W compiler is not always minimal (it
emits disp32 for some [esp+k] accessors whose k fits in disp8). The
operand model records the width a decoder saw (asm_operand.disp_size,
op.size), so decode -> encode reproduces the exact bytes; an insn built
by the text parser leaves those at "auto" and gets the minimal form.

x64 support (insn.arch == ASM_ARCH_X64): a REX prefix is emitted where
REX.W (64-bit operand) or REX.R/X/B (extended reg / SIB index /
rm-or-base) requires it; absolute [disp32] uses the SIB form and
[rip+disp32] the rm=5 form. The 32-bit path is byte-identical to before
(is64 == 0 emits no REX and keeps the x86 absolute [disp32] form).

Compiled by the seed gate: only seed-understood syntax.
*/
import lib.lib
import libs.asm.insn
import libs.asm.registers
import libs.asm.hexutil


int asm_enc_fits_int8(int v):
	return v >= -128 & v <= 127


int asm_enc_is64(asm_insn* insn):
	return insn.arch == ASM_ARCH_X64


int asm_enc_w(int size):
	if (size == 8): return 1
	return 0


# Emit a little-endian immediate of the given width (1/2/4 bytes).
void asm_enc_imm(asm_buffer* b, int value, int size):
	if (size == 1): asm_buffer_byte(b, value & 255)
	else if (size == 2):
		asm_buffer_byte(b, value & 255)
		asm_buffer_byte(b, (value >> 8) & 255)
	else: asm_buffer_int32(b, value)


############################### REX prefixes #################################

# Emit a REX prefix for an x64 ModRM-form instruction when any bit is
# needed. w selects a 64-bit operand size (REX.W); reg_field is the ModRM
# reg number (>= 8 sets REX.R); rm is the r/m operand, whose extended base
# (8-15) sets REX.B, extended SIB index sets REX.X, and — for a register
# r/m — an extended register sets REX.B. rm may be 0 for forms with none.
void asm_enc_rex(asm_buffer* b, int is64, int w, int reg_field, asm_operand* rm):
	if (is64 == 0): return
	int rex = 0
	if (w): rex = rex | 8
	if (reg_field >= 8): rex = rex | 4
	if (cast(int, rm) != 0):
		if (rm.kind == ASM_OP_REG):
			if (rm.reg >= 8): rex = rex | 1
		else:
			if (rm.index >= 8): rex = rex | 2
			if (rm.base >= 8 && rm.base <= 15): rex = rex | 1
	if (rex != 0): asm_buffer_byte(b, 0x40 | rex)


# REX for a form whose register is embedded in the opcode (push/pop,
# mov r,imm, bswap, xchg): REX.B extends that register.
void asm_enc_rex_reg(asm_buffer* b, int is64, int w, int reg):
	if (is64 == 0): return
	int rex = 0
	if (w): rex = rex | 8
	if (reg >= 8): rex = rex | 1
	if (rex != 0): asm_buffer_byte(b, 0x40 | rex)


# Choose the displacement width for a memory operand: honor a recorded
# disp_size, else pick the minimal legal form. ebp/r13 (base low bits 5)
# with no displacement still needs a disp8 (mod!=0), and an absolute
# [disp] (no base/index) is always disp32.
int asm_enc_disp_size(asm_operand* mem):
	if (mem.disp_size == 1 || mem.disp_size == 4): return mem.disp_size
	if (mem.base < 0): return 4
	if (mem.disp == 0 && (mem.base & 7) != 5): return 0
	if (asm_enc_fits_int8(mem.disp)): return 1
	return 4


# Emit ModRM (+ SIB + displacement) for reg_field against the r/m
# operand. Mirrors asm_x86_decode_rm exactly. is64 selects the x64
# encodings for absolute [disp32] (SIB form) and [rip+disp32] (rm=5); it
# does not otherwise change the low bits, since REX carries the high
# register bits and is emitted by the caller.
void asm_enc_modrm(asm_buffer* b, int reg_field, asm_operand* rm, int is64):
	if (rm.kind == ASM_OP_REG):
		asm_buffer_byte(b, 0xc0 | ((reg_field & 7) << 3) | (rm.reg & 7))
		return
	if (rm.base == ASM_BASE_RIP):
		# [rip+disp32]: mod=0 rm=5, no SIB (x64 only).
		asm_buffer_byte(b, ((reg_field & 7) << 3) | 5)
		asm_buffer_int32(b, rm.disp)
		return
	if (rm.base < 0):
		# absolute [disp32]. x86 uses mod=0 rm=5; x64 uses the SIB form
		# (mod=0 rm=4, SIB=0x25) since rm=5 means rip there.
		if (is64):
			asm_buffer_byte(b, ((reg_field & 7) << 3) | 4)
			asm_buffer_byte(b, 0x25)
		else: asm_buffer_byte(b, ((reg_field & 7) << 3) | 5)
		asm_buffer_int32(b, rm.disp)
		return
	int disp_size = asm_enc_disp_size(rm)
	int mod = 0
	if (disp_size == 1): mod = 1
	else if (disp_size == 4): mod = 2
	int needs_sib = 0
	if (rm.index >= 0): needs_sib = 1
	if ((rm.base & 7) == 4): needs_sib = 1
	if (needs_sib):
		asm_buffer_byte(b, (mod << 6) | ((reg_field & 7) << 3) | 4)
		int scale_bits = 0
		if (rm.scale == 2): scale_bits = 1
		else if (rm.scale == 4): scale_bits = 2
		else if (rm.scale == 8): scale_bits = 3
		int index_field = 4
		if (rm.index >= 0): index_field = rm.index
		asm_buffer_byte(b, (scale_bits << 6) | ((index_field & 7) << 3) | (rm.base & 7))
	else: asm_buffer_byte(b, (mod << 6) | ((reg_field & 7) << 3) | (rm.base & 7))
	if (disp_size == 1): asm_buffer_byte(b, rm.disp & 255)
	else if (disp_size == 4): asm_buffer_int32(b, rm.disp)


# 0x66 operand-size prefix when the operand size is 16-bit.
void asm_enc_opsize_prefix(asm_buffer* b, int size):
	if (size == 2): asm_buffer_byte(b, 0x66)


############################### mnemonic tables ##############################

# ALU family base opcode for the r/m,r form (op /r), or -1.
int asm_enc_alu_base(char* m):
	int ext = asm_x86_group_ext(1, m)
	if (ext < 0): return -1
	return ext << 3


# Condition-code number of a j<cc>/set<cc> suffix, or -1.
int asm_enc_cc(char* suffix):
	return asm_name_slot_find(asm_x86_cc_table(), 3, 16, suffix)

# Like asm_enc_cc but also resolving the condition-code synonyms the GNU
# assembler accepts, which an AT&T source uses interchangeably with the
# canonical spellings (setc/jc for carry = below, setz for zero = equal,
# setnae, setng, ...). The canonical table drives the decoder, so the
# synonyms live here in the encode direction only.
int asm_enc_cc_alias(char* suffix):
	if (strcmp(suffix, c"c") == 0): return 2
	if (strcmp(suffix, c"nae") == 0): return 2
	if (strcmp(suffix, c"nc") == 0): return 3
	if (strcmp(suffix, c"nb") == 0): return 3
	if (strcmp(suffix, c"z") == 0): return 4
	if (strcmp(suffix, c"nz") == 0): return 5
	if (strcmp(suffix, c"na") == 0): return 6
	if (strcmp(suffix, c"nbe") == 0): return 7
	if (strcmp(suffix, c"pe") == 0): return 10
	if (strcmp(suffix, c"po") == 0): return 11
	if (strcmp(suffix, c"nge") == 0): return 12
	if (strcmp(suffix, c"nl") == 0): return 13
	if (strcmp(suffix, c"ng") == 0): return 14
	if (strcmp(suffix, c"nle") == 0): return 15
	return asm_enc_cc(suffix)


# Shift-group /ext of m, or -1. sal (/6) decodes but is never emitted:
# shl (/4) is its canonical encoding.
int asm_enc_grp2_ext(char* m):
	if (strcmp(m, c"sal") == 0): return -1
	return asm_x86_group_ext(2, m)


############################### SSE encoding #################################

# Emit f2/f3 0f xx /r for a scalar-float op with two operands
# (op1 reg field, op2 r/m). Returns 1 if handled.
int asm_enc_sse(asm_buffer* b, asm_insn* insn):
	int rep = 0xf3
	int index = asm_name_slot_find(asm_x86_sse_table(rep), 9, 7, insn.mnemonic)
	if (index < 0):
		rep = 0xf2
		index = asm_name_slot_find(asm_x86_sse_table(rep), 9, 7, insn.mnemonic)
	int op = 0x58 + index
	if (index < 0): return 0
	int is64 = asm_enc_is64(insn)
	asm_buffer_byte(b, rep)
	asm_enc_rex(b, is64, 0, insn.op1.reg, &insn.op2)
	asm_buffer_byte(b, 0x0f)
	asm_buffer_byte(b, op)
	asm_enc_modrm(b, insn.op1.reg, &insn.op2, is64)
	return 1


############################## main entry point ##############################

# Defined below; forward declarations for the single-pass compiler.
int asm_x86_encode_0f(asm_buffer* b, asm_insn* insn);
int asm_x86_encode_alu(asm_buffer* b, asm_insn* insn);
int asm_x86_encode_mov(asm_buffer* b, asm_insn* insn, int start);
void asm_enc_rel32(asm_buffer* b, asm_insn* insn, int opcode);
void asm_enc_jcc(asm_buffer* b, asm_insn* insn, int cc);
int asm_enc_dot_target(char* label);


# Encode insn into b. Returns the number of bytes written, or -1 if the
# mnemonic/operand shape is unsupported (caller can report).
# Emit a two-byte 0f-prefixed opcode (0f <op>); returns 1.
int asm_enc_two_byte(asm_buffer* b, int op):
	asm_buffer_byte(b, 0x0f)
	asm_buffer_byte(b, op)
	return 1

# Emit a 0f ae <modrm> fence (lfence/mfence/sfence); returns 1.
int asm_enc_0f_ae(asm_buffer* b, int modrm):
	asm_buffer_byte(b, 0x0f)
	asm_buffer_byte(b, 0xae)
	asm_buffer_byte(b, modrm)
	return 1

# Emit a 0f 01 <modrm> instruction (xgetbv/xsetbv/clac/stac/swapgs);
# returns 1.
int asm_enc_0f_01(asm_buffer* b, int modrm):
	asm_buffer_byte(b, 0x0f)
	asm_buffer_byte(b, 0x01)
	asm_buffer_byte(b, modrm)
	return 1

# A single-byte opcode with no operand, or -1 when m is not one. Covers
# the inline-asm one-byte instructions a kernel uses (flags, string-op
# direction, interrupt enable, pause/hlt/nop).
int asm_enc_one_byte(char* m):
	if (strcmp(m, c"ret") == 0): return 0xc3
	if (strcmp(m, c"leave") == 0): return 0xc9
	if (strcmp(m, c"hlt") == 0): return 0xf4
	if (strcmp(m, c"cli") == 0): return 0xfa
	if (strcmp(m, c"sti") == 0): return 0xfb
	if (strcmp(m, c"cld") == 0): return 0xfc
	if (strcmp(m, c"std") == 0): return 0xfd
	if (strcmp(m, c"clc") == 0): return 0xf8
	if (strcmp(m, c"stc") == 0): return 0xf9
	if (strcmp(m, c"cmc") == 0): return 0xf5
	if (strcmp(m, c"pushfq") == 0 | strcmp(m, c"pushf") == 0): return 0x9c
	if (strcmp(m, c"popfq") == 0 | strcmp(m, c"popf") == 0): return 0x9d
	if (strcmp(m, c"sahf") == 0): return 0x9e
	if (strcmp(m, c"lahf") == 0): return 0x9f
	return -1

# The base mnemonic of a 'lock'-prefixed instruction whose r/m-with-reg
# or immediate form takes a 0xf0 prefix and is encoded here (ALU, the
# bit tests, inc/dec, xchg, not/neg). cmpxchg and xadd are prefixed in
# asm_x86_encode_0f, which runs before the generic path, so they are
# excluded. Returns the base mnemonic, or 0 when m is not such a lock.
char* asm_enc_lock_base(char* m):
	if (m[0] != 'l'): return 0
	if (m[1] != 'o'): return 0
	if (m[2] != 'c'): return 0
	if (m[3] != 'k'): return 0
	if (m[4] != ' '): return 0
	char* base = m + 5
	if (strcmp(base, c"cmpxchg") == 0 | strcmp(base, c"xadd") == 0): return 0
	if (asm_enc_alu_base(base) >= 0): return base
	if (asm_x86_group_ext(8, base) >= 0): return base
	if (strcmp(base, c"inc") == 0 | strcmp(base, c"dec") == 0): return base
	if (strcmp(base, c"not") == 0 | strcmp(base, c"neg") == 0): return base
	if (strcmp(base, c"xchg") == 0): return base
	return 0


int asm_x86_encode(asm_buffer* b, asm_insn* insn):
	int start = b.length
	char* m = insn.mnemonic
	int is64 = asm_enc_is64(insn)

	# A segment override (%fs:/%gs: on the memory operand) is the first
	# prefix, ahead of lock and the operand-size prefix, as gas orders it.
	int segment = insn.segment
	if (segment != 0):
		asm_buffer_byte(b, segment)
		insn.segment = 0
		int sr = asm_x86_encode(b, insn)
		insn.segment = segment
		if (sr <= 0): return 0 - 1
		return b.length - start

	# One-byte opcodes with no operand (flags, interrupt enable, ...).
	int ob = asm_enc_one_byte(m)
	if (ob >= 0):
		asm_buffer_byte(b, ob)
		return b.length - start
	if (strcmp(m, c"pause") == 0):
		asm_buffer_byte(b, 0xf3)
		asm_buffer_byte(b, 0x90)
		return b.length - start

	# A generic 'lock' prefix: emit 0xf0, then encode the base mnemonic.
	# cmpxchg/xadd carry their own prefix in asm_x86_encode_0f below.
	char* lock_base = asm_enc_lock_base(m)
	if (lock_base != 0):
		asm_buffer_byte(b, 0xf0)
		insn.mnemonic = lock_base
		int r = asm_x86_encode(b, insn)
		insn.mnemonic = m
		if (r <= 0): return 0 - 1
		return b.length - start

	# SSE scalar float
	if (asm_enc_sse(b, insn)): return b.length - start

	# Two-byte-opcode instructions delegated together.
	if (asm_x86_encode_0f(b, insn)): return b.length - start

	# ALU add/or/.../cmp in all forms.
	if (asm_enc_alu_base(m) >= 0):
		if (asm_x86_encode_alu(b, insn)): return b.length - start
		return 0 - 1

	int count = asm_insn_operand_count(insn)

	if (strcmp(m, c"ret") == 0):
		asm_buffer_byte(b, 0xc3)
		return b.length - start
	if (strcmp(m, c"leave") == 0):
		asm_buffer_byte(b, 0xc9)
		return b.length - start

	# Port I/O: in <port>, <acc> and out <acc>, <port>. The port is dx
	# (variable form, EC/ED and EE/EF) or an imm8 (E4/E5 and E6/E7); the
	# accumulator width (al/ax/eax) picks the byte-vs-word opcode and the
	# 0x66 prefix. After the AT&T reversal op1 is the destination.
	if (strcmp(m, c"in") == 0):
		int acc = insn.op1.size
		if (insn.op1.kind != ASM_OP_REG): acc = 4
		if (acc == 2): asm_buffer_byte(b, 0x66)
		if (insn.op2.kind == ASM_OP_IMM):
			if (acc == 1): asm_buffer_byte(b, 0xe4)
			else: asm_buffer_byte(b, 0xe5)
			asm_buffer_byte(b, insn.op2.imm & 255)
		else:
			if (acc == 1): asm_buffer_byte(b, 0xec)
			else: asm_buffer_byte(b, 0xed)
		return b.length - start
	if (strcmp(m, c"out") == 0):
		int acc = insn.op2.size
		if (insn.op2.kind != ASM_OP_REG): acc = 4
		if (acc == 2): asm_buffer_byte(b, 0x66)
		if (insn.op1.kind == ASM_OP_IMM):
			if (acc == 1): asm_buffer_byte(b, 0xe6)
			else: asm_buffer_byte(b, 0xe7)
			asm_buffer_byte(b, insn.op1.imm & 255)
		else:
			if (acc == 1): asm_buffer_byte(b, 0xee)
			else: asm_buffer_byte(b, 0xef)
		return b.length - start
	if (strcmp(m, c"nop") == 0):
		asm_buffer_byte(b, 0x90)
		return b.length - start
	if (strcmp(m, c"cdq") == 0):
		asm_buffer_byte(b, 0x99)
		return b.length - start
	if (strcmp(m, c"cqo") == 0):
		asm_buffer_byte(b, 0x48)
		asm_buffer_byte(b, 0x99)
		return b.length - start
	if (strcmp(m, c"cwde") == 0):
		asm_buffer_byte(b, 0x98)
		return b.length - start
	if (strcmp(m, c"cdqe") == 0):
		asm_buffer_byte(b, 0x48)
		asm_buffer_byte(b, 0x98)
		return b.length - start
	if (strcmp(m, c"syscall") == 0):
		asm_buffer_byte(b, 0x0f)
		asm_buffer_byte(b, 0x05)
		return b.length - start
	if (strcmp(m, c"int3") == 0):
		asm_buffer_byte(b, 0xcc)
		return b.length - start
	if (strcmp(m, c"int") == 0):
		asm_buffer_byte(b, 0xcd)
		asm_buffer_byte(b, insn.op1.imm & 255)
		return b.length - start

	# push
	if (strcmp(m, c"push") == 0):
		if (insn.op1.kind == ASM_OP_REG):
			asm_enc_opsize_prefix(b, insn.op1.size)
			asm_enc_rex_reg(b, is64, 0, insn.op1.reg)
			asm_buffer_byte(b, 0x50 + (insn.op1.reg & 7))
			return b.length - start
		if (insn.op1.kind == ASM_OP_IMM):
			if (insn.op1.size == 1):
				asm_buffer_byte(b, 0x6a)
				asm_buffer_byte(b, insn.op1.imm & 255)
			else:
				asm_buffer_byte(b, 0x68)
				asm_buffer_int32(b, insn.op1.imm)
			return b.length - start
		if (insn.op1.kind == ASM_OP_MEM):
			asm_enc_rex(b, is64, 0, 6, &insn.op1)
			asm_buffer_byte(b, 0xff)
			asm_enc_modrm(b, 6, &insn.op1, is64)
			return b.length - start
	if (strcmp(m, c"pushw") == 0):
		asm_buffer_byte(b, 0x66)
		# explicit size 1 or parsed text (size 0) with a small value picks
		# the imm8 form, like the ALU imm8/imm32 rule
		int pushw_imm8 = insn.op1.size == 1
		if (insn.op1.size == 0 & asm_enc_fits_int8(insn.op1.imm)): pushw_imm8 = 1
		if (pushw_imm8):
			asm_buffer_byte(b, 0x6a)
			asm_buffer_byte(b, insn.op1.imm & 255)
		else:
			asm_buffer_byte(b, 0x68)
			asm_enc_imm(b, insn.op1.imm, 2)
		return b.length - start
	if (strcmp(m, c"pop") == 0 & insn.op1.kind == ASM_OP_REG):
		asm_enc_opsize_prefix(b, insn.op1.size)
		asm_enc_rex_reg(b, is64, 0, insn.op1.reg)
		asm_buffer_byte(b, 0x58 + (insn.op1.reg & 7))
		return b.length - start
	# pop r/m (0x8f /0): 64-bit in x64, 32-bit in x86, like push r/m.
	if (strcmp(m, c"pop") == 0 & insn.op1.kind == ASM_OP_MEM):
		asm_enc_rex(b, is64, 0, 0, &insn.op1)
		asm_buffer_byte(b, 0x8f)
		asm_enc_modrm(b, 0, &insn.op1, is64)
		return b.length - start

	# inc/dec register: x86 has a one-byte short form (0x40/0x48+reg); x64
	# reuses those bytes for REX, so it must use the grp5 (0xff /0 /1) form.
	if ((strcmp(m, c"inc") == 0 | strcmp(m, c"dec") == 0) & insn.op1.kind == ASM_OP_REG):
		int ext = 0
		if (strcmp(m, c"dec") == 0): ext = 1
		if (is64):
			asm_enc_rex(b, is64, asm_enc_w(insn.op1.size), ext, &insn.op1)
			asm_buffer_byte(b, 0xff)
			asm_enc_modrm(b, ext, &insn.op1, is64)
			return b.length - start
		asm_enc_opsize_prefix(b, insn.op1.size)
		int reg_base = 0x40
		if (ext == 1): reg_base = 0x48
		asm_buffer_byte(b, reg_base + (insn.op1.reg & 7))
		return b.length - start

	# bswap
	if (strcmp(m, c"bswap") == 0):
		asm_enc_rex_reg(b, is64, asm_enc_w(insn.op1.size), insn.op1.reg)
		asm_buffer_byte(b, 0x0f)
		asm_buffer_byte(b, 0xc8 + (insn.op1.reg & 7))
		return b.length - start

	# grp5 memory (call/jmp/push/inc/dec through r/m)
	int g5 = asm_x86_group_ext(5, m)
	if (((g5 >= 0) && (count == 1)) && insn.op1.kind == ASM_OP_MEM):
		int w5 = 0
		if ((g5 == 0 || g5 == 1) && insn.op1.size == 8): w5 = 1
		asm_enc_rex(b, is64, w5, g5, &insn.op1)
		asm_buffer_byte(b, 0xff)
		asm_enc_modrm(b, g5, &insn.op1, is64)
		return b.length - start

	# call/jmp rel32 (label target)
	if (strcmp(m, c"call") == 0 & insn.op1.kind == ASM_OP_LABEL):
		asm_enc_rel32(b, insn, 0xe8)
		return b.length - start
	if (strcmp(m, c"jmp") == 0 & insn.op1.kind == ASM_OP_LABEL):
		asm_enc_rel32(b, insn, 0xe9)
		return b.length - start
	# jmp/call register indirect (grp5 with reg operand); near, default 64.
	if ((strcmp(m, c"jmp") == 0 | strcmp(m, c"call") == 0) & insn.op1.kind == ASM_OP_REG):
		asm_enc_rex(b, is64, 0, asm_x86_group_ext(5, m), &insn.op1)
		asm_buffer_byte(b, 0xff)
		asm_enc_modrm(b, asm_x86_group_ext(5, m), &insn.op1, is64)
		return b.length - start

	# Jcc rel8/rel32 (mnemonic j<cc>, label target)
	if (m[0] == 'j' && insn.op1.kind == ASM_OP_LABEL):
		int cc = asm_enc_cc_alias(m + 1)
		if (cc >= 0):
			asm_enc_jcc(b, insn, cc)
			return b.length - start

	# setcc r/m8
	if (m[0] == 's' && m[1] == 'e' && m[2] == 't'):
		int cc = asm_enc_cc_alias(m + 3)
		if (cc >= 0):
			asm_enc_rex(b, is64, 0, 0, &insn.op1)
			asm_buffer_byte(b, 0x0f)
			asm_buffer_byte(b, 0x90 + cc)
			asm_enc_modrm(b, 0, &insn.op1, is64)
			return b.length - start

	# mov
	if (strcmp(m, c"mov") == 0): return asm_x86_encode_mov(b, insn, start)

	# lea
	if (strcmp(m, c"lea") == 0):
		asm_enc_rex(b, is64, asm_enc_w(insn.op1.size), insn.op1.reg, &insn.op2)
		asm_buffer_byte(b, 0x8d)
		asm_enc_modrm(b, insn.op1.reg, &insn.op2, is64)
		return b.length - start

	# xchg: the one-byte 0x90+reg form is only valid when one operand is
	# (e)ax/rax and both are registers; a memory operand or two general
	# registers use the r/m, r form (0x86 byte / 0x87 word+).
	if (strcmp(m, c"xchg") == 0):
		int reg_reg = (insn.op1.kind == ASM_OP_REG) & (insn.op2.kind == ASM_OP_REG)
		int has_ax = reg_reg & ((insn.op1.reg == 0) | (insn.op2.reg == 0))
		if (has_ax):
			int r = insn.op1.reg
			if (insn.op1.reg == 0): r = insn.op2.reg
			asm_enc_rex_reg(b, is64, asm_enc_w(insn.op1.size), r)
			asm_buffer_byte(b, 0x90 + (r & 7))
			return b.length - start
		# r/m, r — op2 is the register, op1 the r/m (reg or mem).
		int opcode = 0x87
		if (insn.op2.size == 1): opcode = 0x86
		asm_enc_opsize_prefix(b, insn.op2.size)
		asm_enc_rex(b, is64, asm_enc_w(insn.op2.size), insn.op2.reg, &insn.op1)
		asm_buffer_byte(b, opcode)
		asm_enc_modrm(b, insn.op2.reg, &insn.op1, is64)
		return b.length - start

	# test r/m, r
	if (strcmp(m, c"test") == 0 & count == 2 & insn.op2.kind == ASM_OP_REG):
		int opcode = 0x85
		if (insn.op2.size == 1): opcode = 0x84
		asm_enc_opsize_prefix(b, insn.op2.size)
		asm_enc_rex(b, is64, asm_enc_w(insn.op2.size), insn.op2.reg, &insn.op1)
		asm_buffer_byte(b, opcode)
		asm_enc_modrm(b, insn.op2.reg, &insn.op1, is64)
		return b.length - start

	# test r/m, imm (f6 /0 ib for byte, f7 /0 id otherwise). No sign-
	# extended imm8 short form exists for test, so the immediate is always
	# emitted at the operand width.
	if (strcmp(m, c"test") == 0 & count == 2 & insn.op2.kind == ASM_OP_IMM):
		int tsize = insn.op1.size
		asm_enc_opsize_prefix(b, tsize)
		asm_enc_rex(b, is64, asm_enc_w(tsize), 0, &insn.op1)
		if (tsize == 1):
			asm_buffer_byte(b, 0xf6)
			asm_enc_modrm(b, 0, &insn.op1, is64)
			asm_buffer_byte(b, insn.op2.imm & 255)
		else:
			asm_buffer_byte(b, 0xf7)
			asm_enc_modrm(b, 0, &insn.op1, is64)
			if (tsize == 2): asm_enc_imm(b, insn.op2.imm, 2)
			else: asm_buffer_int32(b, insn.op2.imm)
		return b.length - start

	# grp2 shifts (r/m, cl or r/m, 1)
	int g2 = asm_enc_grp2_ext(m)
	if (g2 >= 0):
		asm_enc_rex(b, is64, asm_enc_w(insn.op1.size), g2, &insn.op1)
		if (insn.op2.kind == ASM_OP_REG): asm_buffer_byte(b, 0xd3)
		else if (insn.op2.imm == 1): asm_buffer_byte(b, 0xd1)
		else:
			# r/m, imm8 (0xc1); a count of 1 takes the shorter 0xd1 form
			asm_buffer_byte(b, 0xc1)
			asm_enc_modrm(b, g2, &insn.op1, is64)
			asm_buffer_byte(b, insn.op2.imm & 255)
			return b.length - start
		asm_enc_modrm(b, g2, &insn.op1, is64)
		return b.length - start

	# grp3 (not/neg/mul/imul/div/idiv r/m)  — single r/m operand form
	int g3 = asm_x86_group_ext(3, m)
	if (g3 >= 0 && count == 1):
		asm_enc_opsize_prefix(b, insn.op1.size)
		asm_enc_rex(b, is64, asm_enc_w(insn.op1.size), g3, &insn.op1)
		if (insn.op1.size == 1): asm_buffer_byte(b, 0xf6)
		else: asm_buffer_byte(b, 0xf7)
		asm_enc_modrm(b, g3, &insn.op1, is64)
		return b.length - start

	# imul r32, r/m32 (0f af) and imul r32, r/m32, imm32 (0x69)
	if (strcmp(m, c"imul") == 0):
		if (count == 3):
			asm_enc_rex(b, is64, asm_enc_w(insn.op1.size), insn.op1.reg, &insn.op2)
			asm_buffer_byte(b, 0x69)
			asm_enc_modrm(b, insn.op1.reg, &insn.op2, is64)
			asm_buffer_int32(b, insn.op3.imm)
			return b.length - start
		if (count == 2):
			asm_enc_rex(b, is64, asm_enc_w(insn.op1.size), insn.op1.reg, &insn.op2)
			asm_buffer_byte(b, 0x0f)
			asm_buffer_byte(b, 0xaf)
			asm_enc_modrm(b, insn.op1.reg, &insn.op2, is64)
			return b.length - start

	# fstp dword [m]
	if (strcmp(m, c"fstp") == 0):
		asm_buffer_byte(b, 0xd9)
		asm_enc_modrm(b, 3, &insn.op1, is64)
		return b.length - start

	# movsxd r64, r/m32 (0x63, x64)
	if (strcmp(m, c"movsxd") == 0):
		asm_enc_rex(b, is64, asm_enc_w(insn.op1.size), insn.op1.reg, &insn.op2)
		asm_buffer_byte(b, 0x63)
		asm_enc_modrm(b, insn.op1.reg, &insn.op2, is64)
		return b.length - start

	# movzx/movsx r32, r/m8|r/m16
	if (strcmp(m, c"movzx") == 0 | strcmp(m, c"movsx") == 0):
		asm_enc_rex(b, is64, asm_enc_w(insn.op1.size), insn.op1.reg, &insn.op2)
		asm_buffer_byte(b, 0x0f)
		int opcode = 0xb6
		if (strcmp(m, c"movsx") == 0): opcode = 0xbe
		if (insn.op2.size == 2): opcode = opcode + 1
		asm_buffer_byte(b, opcode)
		asm_enc_modrm(b, insn.op1.reg, &insn.op2, is64)
		return b.length - start

	# btc/bt/bts/btr r/m, imm8 (0f ba /ext ib)
	int g8 = asm_x86_group_ext(8, m)
	if (((g8 >= 0) && (count == 2)) && insn.op2.kind == ASM_OP_IMM):
		asm_enc_rex(b, is64, asm_enc_w(insn.op1.size), g8, &insn.op1)
		asm_buffer_byte(b, 0x0f)
		asm_buffer_byte(b, 0xba)
		asm_enc_modrm(b, g8, &insn.op1, is64)
		asm_buffer_byte(b, insn.op2.imm & 255)
		return b.length - start

	# vcvtph2ps / vcvtps2ph (fixed VEX forms)
	if (strcmp(m, c"vcvtph2ps") == 0):
		asm_buffer_byte(b, 0xc4)
		asm_buffer_byte(b, 0xe2)
		asm_buffer_byte(b, 0x79)
		asm_buffer_byte(b, 0x13)
		asm_enc_modrm(b, insn.op1.reg, &insn.op2, is64)
		return b.length - start
	if (strcmp(m, c"vcvtps2ph") == 0):
		asm_buffer_byte(b, 0xc4)
		asm_buffer_byte(b, 0xe3)
		asm_buffer_byte(b, 0x79)
		asm_buffer_byte(b, 0x1d)
		asm_enc_modrm(b, insn.op2.reg, &insn.op1, is64)
		asm_buffer_byte(b, insn.op3.imm & 255)
		return b.length - start

	return 0 - 1


# mov: register/immediate/memory forms.
int asm_x86_encode_mov(asm_buffer* b, asm_insn* insn, int start):
	int is64 = asm_enc_is64(insn)
	# mov r, imm
	if (insn.op1.kind == ASM_OP_REG && insn.op2.kind == ASM_OP_IMM):
		if (insn.op1.size == 1):
			asm_enc_rex_reg(b, is64, 0, insn.op1.reg)
			asm_buffer_byte(b, 0xb0 + (insn.op1.reg & 7))
			asm_buffer_byte(b, insn.op2.imm & 255)
		else if (insn.op1.size == 8 && insn.op2.size == 4):
			# mov r64, simm32 (REX.W C7 /0 id), as decoded: the width-4
			# immediate keeps the 7-byte form byte-exact.
			asm_enc_rex_reg(b, is64, 1, insn.op1.reg)
			asm_buffer_byte(b, 0xc7)
			asm_buffer_byte(b, 0xc0 | (insn.op1.reg & 7))
			asm_buffer_int32(b, insn.op2.imm)
		else if (insn.op1.size == 8):
			# movabs r64, imm64
			asm_enc_rex_reg(b, is64, 1, insn.op1.reg)
			asm_buffer_byte(b, 0xb8 + (insn.op1.reg & 7))
			asm_buffer_int32(b, insn.op2.imm)
			asm_buffer_int32(b, insn.op2.imm_hi)
		else:
			asm_enc_opsize_prefix(b, insn.op1.size)
			asm_enc_rex_reg(b, is64, 0, insn.op1.reg)
			asm_buffer_byte(b, 0xb8 + (insn.op1.reg & 7))
			if (insn.op1.size == 2): asm_enc_imm(b, insn.op2.imm, 2)
			else: asm_buffer_int32(b, insn.op2.imm)
		return b.length - start
	# mov r/m, imm (0xc6 /0 ib, 0xc7 /0 iw/id). A register destination
	# takes the shorter mov r,imm form above, so op1 is memory here.
	if (insn.op1.kind == ASM_OP_MEM && insn.op2.kind == ASM_OP_IMM):
		int msize = insn.op1.size
		if (msize == 0): msize = 4
		asm_enc_opsize_prefix(b, msize)
		asm_enc_rex(b, is64, asm_enc_w(msize), 0, &insn.op1)
		if (msize == 1): asm_buffer_byte(b, 0xc6)
		else: asm_buffer_byte(b, 0xc7)
		asm_enc_modrm(b, 0, &insn.op1, is64)
		if (msize == 1): asm_enc_imm(b, insn.op2.imm, 1)
		else if (msize == 2): asm_enc_imm(b, insn.op2.imm, 2)
		else: asm_buffer_int32(b, insn.op2.imm)
		return b.length - start
	# mov r/m, r  (store) and mov r, r/m (load)
	int size = 4
	if (insn.op1.kind == ASM_OP_REG): size = insn.op1.size
	else if (insn.op2.kind == ASM_OP_REG): size = insn.op2.size
	asm_enc_opsize_prefix(b, size)
	if (insn.op2.kind == ASM_OP_REG && insn.op1.kind != ASM_OP_IMM):
		# store: op1 is r/m, op2 is reg
		int opcode = 0x89
		if (size == 1): opcode = 0x88
		asm_enc_rex(b, is64, asm_enc_w(size), insn.op2.reg, &insn.op1)
		asm_buffer_byte(b, opcode)
		asm_enc_modrm(b, insn.op2.reg, &insn.op1, is64)
		return b.length - start
	# load: op1 is reg, op2 is r/m
	int opcode = 0x8b
	if (size == 1): opcode = 0x8a
	asm_enc_rex(b, is64, asm_enc_w(size), insn.op1.reg, &insn.op2)
	asm_buffer_byte(b, opcode)
	asm_enc_modrm(b, insn.op1.reg, &insn.op2, is64)
	return b.length - start


# ALU add/or/adc/sbb/and/sub/xor/cmp across r/m+r, r+r/m and imm forms.
int asm_x86_encode_alu(asm_buffer* b, asm_insn* insn):
	char* m = insn.mnemonic
	int is64 = asm_enc_is64(insn)
	int base = asm_enc_alu_base(m)
	int ext = base >> 3
	# imm form
	if (insn.op2.kind == ASM_OP_IMM):
		int size = insn.op1.size
		if (insn.op1.kind == ASM_OP_MEM): size = insn.op1.size
		# byte operand: al, imm8 short form (base + 4) or 80 /ext ib
		if (size == 1):
			if (insn.op1.kind == ASM_OP_REG && insn.op1.reg == 0):
				asm_buffer_byte(b, base + 4)
			else:
				asm_enc_rex(b, is64, 0, ext, &insn.op1)
				asm_buffer_byte(b, 0x80)
				asm_enc_modrm(b, ext, &insn.op1, is64)
			asm_buffer_byte(b, insn.op2.imm & 255)
			return 1
		# eax, imm32 short form
		if (insn.op1.kind == ASM_OP_REG && insn.op1.reg == 0 && insn.op2.size != 1):
			asm_enc_opsize_prefix(b, insn.op1.size)
			asm_enc_rex(b, is64, asm_enc_w(insn.op1.size), 0, cast(asm_operand*, 0))
			asm_buffer_byte(b, base + 5)
			if (insn.op1.size == 2): asm_enc_imm(b, insn.op2.imm, 2)
			else: asm_buffer_int32(b, insn.op2.imm)
			return 1
		asm_enc_opsize_prefix(b, size)
		asm_enc_rex(b, is64, asm_enc_w(size), ext, &insn.op1)
		# an explicit size 1 (decoded 0x83 form, or a `byte` keyword in
		# text) forces imm8; parsed text leaves size 0, which picks the
		# minimal form — mirroring the disp_size == 0 displacement rule
		int imm8 = insn.op2.size == 1
		if (insn.op2.size == 0 & asm_enc_fits_int8(insn.op2.imm)): imm8 = 1
		if (imm8):
			asm_buffer_byte(b, 0x83)
			asm_enc_modrm(b, ext, &insn.op1, is64)
			asm_buffer_byte(b, insn.op2.imm & 255)
		else:
			asm_buffer_byte(b, 0x81)
			asm_enc_modrm(b, ext, &insn.op1, is64)
			if (size == 2): asm_enc_imm(b, insn.op2.imm, 2)
			else: asm_buffer_int32(b, insn.op2.imm)
		return 1
	# register forms
	if (insn.op2.kind == ASM_OP_REG):
		int size = insn.op2.size
		asm_enc_opsize_prefix(b, size)
		asm_enc_rex(b, is64, asm_enc_w(size), insn.op2.reg, &insn.op1)
		int opcode = base + 1
		if (size == 1): opcode = base
		asm_buffer_byte(b, opcode)
		asm_enc_modrm(b, insn.op2.reg, &insn.op1, is64)
		return 1
	# op1 reg, op2 mem  (op /r, load direction base+3)
	if (insn.op1.kind == ASM_OP_REG && insn.op2.kind == ASM_OP_MEM):
		asm_enc_opsize_prefix(b, insn.op1.size)
		asm_enc_rex(b, is64, asm_enc_w(insn.op1.size), insn.op1.reg, &insn.op2)
		asm_buffer_byte(b, base + 3)
		asm_enc_modrm(b, insn.op1.reg, &insn.op2, is64)
		return 1
	return 0


# 0f-prefixed encodings that don't fit the flat dispatch (movd/movq,
# movss/movsd, cvtsi2ss/sd, cvttss2si/cvttsd2si, ucomiss/sd). Returns 1 if
# handled.
int asm_x86_encode_0f(asm_buffer* b, asm_insn* insn):
	char* m = insn.mnemonic
	int is64 = asm_enc_is64(insn)

	# Fixed two-byte and three-byte opcodes with no operands, as a kernel's
	# inline asm uses them (privileged and serializing instructions).
	if (strcmp(m, c"cpuid") == 0): return asm_enc_two_byte(b, 0xa2)
	if (strcmp(m, c"rdtsc") == 0): return asm_enc_two_byte(b, 0x31)
	if (strcmp(m, c"rdtscp") == 0):
		asm_buffer_byte(b, 0x0f)
		asm_buffer_byte(b, 0x01)
		asm_buffer_byte(b, 0xf9)
		return 1
	if (strcmp(m, c"rdpmc") == 0): return asm_enc_two_byte(b, 0x33)
	if (strcmp(m, c"rdmsr") == 0): return asm_enc_two_byte(b, 0x32)
	if (strcmp(m, c"wrmsr") == 0): return asm_enc_two_byte(b, 0x30)
	if (strcmp(m, c"wbinvd") == 0): return asm_enc_two_byte(b, 0x09)
	if (strcmp(m, c"invd") == 0): return asm_enc_two_byte(b, 0x08)
	if (strcmp(m, c"ud2") == 0): return asm_enc_two_byte(b, 0x0b)
	if (strcmp(m, c"lfence") == 0): return asm_enc_0f_ae(b, 0xe8)
	if (strcmp(m, c"mfence") == 0): return asm_enc_0f_ae(b, 0xf0)
	if (strcmp(m, c"sfence") == 0): return asm_enc_0f_ae(b, 0xf8)
	if (strcmp(m, c"xgetbv") == 0): return asm_enc_0f_01(b, 0xd0)
	if (strcmp(m, c"xsetbv") == 0): return asm_enc_0f_01(b, 0xd1)
	if (strcmp(m, c"clac") == 0): return asm_enc_0f_01(b, 0xca)
	if (strcmp(m, c"stac") == 0): return asm_enc_0f_01(b, 0xcb)
	if (strcmp(m, c"swapgs") == 0): return asm_enc_0f_01(b, 0xf8)

	# fxsave / fxrstor m (0f ae /0 and /1); fxsaveq/fxrstorq force REX.W.
	if (strcmp(m, c"fxsave") == 0 | strcmp(m, c"fxsaveq") == 0 | (strcmp(m, c"fxrstor") == 0 | strcmp(m, c"fxrstorq") == 0)):
		int fw = 0
		if (strcmp(m, c"fxsaveq") == 0 | strcmp(m, c"fxrstorq") == 0): fw = 1
		int fext = 0
		if (strcmp(m, c"fxrstor") == 0 | strcmp(m, c"fxrstorq") == 0): fext = 1
		asm_enc_rex(b, is64, fw, fext, &insn.op1)
		asm_buffer_byte(b, 0x0f)
		asm_buffer_byte(b, 0xae)
		asm_enc_modrm(b, fext, &insn.op1, is64)
		return 1

	# bsf / bsr / tzcnt / lzcnt / popcnt r, r/m (0f bc/bd; f3-prefixed forms)
	if (((strcmp(m, c"bsf") == 0 | strcmp(m, c"bsr") == 0) | (strcmp(m, c"tzcnt") == 0 | strcmp(m, c"lzcnt") == 0)) | strcmp(m, c"popcnt") == 0):
		int rep = 0
		if (strcmp(m, c"tzcnt") == 0 | (strcmp(m, c"lzcnt") == 0 | strcmp(m, c"popcnt") == 0)): rep = 0xf3
		int sop = 0xbc
		if (strcmp(m, c"bsr") == 0 | strcmp(m, c"lzcnt") == 0): sop = 0xbd
		if (strcmp(m, c"popcnt") == 0): sop = 0xb8
		if (rep): asm_buffer_byte(b, rep)
		asm_enc_opsize_prefix(b, insn.op1.size)
		asm_enc_rex(b, is64, asm_enc_w(insn.op1.size), insn.op1.reg, &insn.op2)
		asm_buffer_byte(b, 0x0f)
		asm_buffer_byte(b, sop)
		asm_enc_modrm(b, insn.op1.reg, &insn.op2, is64)
		return 1

	# bt / bts / btr / btc r/m, r (0f a3/ab/b3/bb /r); the [lock] prefix is
	# emitted by the generic lock path before this is reached.
	int bt_ext = asm_x86_group_ext(8, m)
	if (((bt_ext >= 0) && (asm_insn_operand_count(insn) == 2)) && insn.op2.kind == ASM_OP_REG):
		asm_enc_opsize_prefix(b, insn.op2.size)
		asm_enc_rex(b, is64, asm_enc_w(insn.op2.size), insn.op2.reg, &insn.op1)
		asm_buffer_byte(b, 0x0f)
		asm_buffer_byte(b, 0xa3 + (bt_ext - 4) * 8)
		asm_enc_modrm(b, insn.op2.reg, &insn.op1, is64)
		return 1

	# [lock] cmpxchg / xadd r/m, r (0f b1 /r, 0f c1 /r)
	int locked = 0
	if (strcmp(m, c"lock cmpxchg") == 0 | strcmp(m, c"lock xadd") == 0): locked = 1
	if (locked | strcmp(m, c"cmpxchg") == 0 | strcmp(m, c"xadd") == 0):
		if (locked): asm_buffer_byte(b, 0xf0)
		asm_enc_opsize_prefix(b, insn.op2.size)
		asm_enc_rex(b, is64, asm_enc_w(insn.op2.size), insn.op2.reg, &insn.op1)
		asm_buffer_byte(b, 0x0f)
		int opcode = 0xc1
		if (strcmp(m, c"cmpxchg") == 0 | strcmp(m, c"lock cmpxchg") == 0): opcode = 0xb1
		asm_buffer_byte(b, opcode)
		asm_enc_modrm(b, insn.op2.reg, &insn.op1, is64)
		return 1
	if (strcmp(m, c"movd") == 0 | strcmp(m, c"movq") == 0):
		int w = 0
		if (strcmp(m, c"movq") == 0): w = 1
		asm_buffer_byte(b, 0x66)
		if (insn.op1.rclass == ASM_RCLASS_XMM):
			asm_enc_rex(b, is64, w, insn.op1.reg, &insn.op2)
			asm_buffer_byte(b, 0x0f)
			asm_buffer_byte(b, 0x6e)
			asm_enc_modrm(b, insn.op1.reg, &insn.op2, is64)
		else:
			asm_enc_rex(b, is64, w, insn.op2.reg, &insn.op1)
			asm_buffer_byte(b, 0x0f)
			asm_buffer_byte(b, 0x7e)
			asm_enc_modrm(b, insn.op2.reg, &insn.op1, is64)
		return 1
	if (strcmp(m, c"movss") == 0 | strcmp(m, c"movsd") == 0):
		int rep = 0xf2
		if (strcmp(m, c"movss") == 0): rep = 0xf3
		asm_buffer_byte(b, rep)
		if (insn.op1.rclass == ASM_RCLASS_XMM):
			# load: xmm <- r/m  (0f 10)
			asm_enc_rex(b, is64, 0, insn.op1.reg, &insn.op2)
			asm_buffer_byte(b, 0x0f)
			asm_buffer_byte(b, 0x10)
			asm_enc_modrm(b, insn.op1.reg, &insn.op2, is64)
		else:
			# store: r/m <- xmm  (0f 11)
			asm_enc_rex(b, is64, 0, insn.op2.reg, &insn.op1)
			asm_buffer_byte(b, 0x0f)
			asm_buffer_byte(b, 0x11)
			asm_enc_modrm(b, insn.op2.reg, &insn.op1, is64)
		return 1
	if (strcmp(m, c"cvtsi2ss") == 0 | strcmp(m, c"cvtsi2sd") == 0):
		int rep = 0xf3
		if (strcmp(m, c"cvtsi2sd") == 0): rep = 0xf2
		asm_buffer_byte(b, rep)
		asm_enc_rex(b, is64, asm_enc_w(insn.op2.size), insn.op1.reg, &insn.op2)
		asm_buffer_byte(b, 0x0f)
		asm_buffer_byte(b, 0x2a)
		asm_enc_modrm(b, insn.op1.reg, &insn.op2, is64)
		return 1
	if (strcmp(m, c"cvttss2si") == 0 | strcmp(m, c"cvttsd2si") == 0):
		int rep = 0xf3
		if (strcmp(m, c"cvttsd2si") == 0): rep = 0xf2
		asm_buffer_byte(b, rep)
		asm_enc_rex(b, is64, asm_enc_w(insn.op1.size), insn.op1.reg, &insn.op2)
		asm_buffer_byte(b, 0x0f)
		asm_buffer_byte(b, 0x2c)
		asm_enc_modrm(b, insn.op1.reg, &insn.op2, is64)
		return 1
	if (strcmp(m, c"ucomiss") == 0 | strcmp(m, c"ucomisd") == 0):
		if (strcmp(m, c"ucomisd") == 0): asm_buffer_byte(b, 0x66)
		asm_enc_rex(b, is64, 0, insn.op1.reg, &insn.op2)
		asm_buffer_byte(b, 0x0f)
		asm_buffer_byte(b, 0x2e)
		asm_enc_modrm(b, insn.op1.reg, &insn.op2, is64)
		return 1
	return 0


# A rel32 branch (call/jmp): the label holds ".+N"/".-N" relative to the
# instruction start. opcode is 1 byte, rel field 4 bytes, so
# rel32 = N - 5.
void asm_enc_rel32(asm_buffer* b, asm_insn* insn, int opcode):
	int target = asm_enc_dot_target(insn.op1.label)
	asm_buffer_byte(b, opcode)
	asm_buffer_int32(b, target - 5)


# Jcc: rel8 when the ".+N" target fits (N-2 in int8), else rel32 (N-6).
void asm_enc_jcc(asm_buffer* b, asm_insn* insn, int cc):
	int target = asm_enc_dot_target(insn.op1.label)
	int rel8 = target - 2
	if (insn.length == 2 | (insn.length == 0 & asm_enc_fits_int8(rel8))):
		asm_buffer_byte(b, 0x70 + cc)
		asm_buffer_byte(b, rel8 & 255)
		return
	asm_buffer_byte(b, 0x0f)
	asm_buffer_byte(b, 0x80 + cc)
	asm_buffer_int32(b, target - 6)


# Parse a ".+N" / ".-N" dot-relative label (N decimal or 0x-hex) into
# its signed N.
int asm_enc_dot_target(char* label):
	int value = asm_parse_number(label + 2)
	if (label[1] == '-'): return 0 - value
	return value
