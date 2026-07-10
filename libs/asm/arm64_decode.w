/*
AArch64 (A64) instruction decoder for the assembler/disassembler libraries
(docs/projects/assembler_disassembler.md, issue #168).

Unlike the x86 byte-stream decoder, A64 is fixed 32-bit words: one
little-endian word decodes into the arch-neutral asm_insn. insn.length is
always 4. Unknown words decode to a `.word 0x........` pseudo-instruction so
a linear sweep never crashes; recognized-but-unmodeled forms (floating point,
bitmask/bitfield immediates, ccmp) decode to their real mnemonic with the raw
word stashed in insn.raw so the encoder can reproduce them byte-for-byte.

Operand conventions (arm64-specific, read by arm64_format.w / arm64_encode.w):
  - registers: kind REG, rclass GP, reg 0..31, size 8 (x) or 4 (w).
  - memory: kind MEM; base = Xn, index = Xm or -1, disp = byte offset,
    disp_size = addressing mode (ARM64_ADDR_*), size = access width.
  - branch/adr targets: kind LABEL, label = dot-relative text, imm = the
    signed byte offset (adrp: signed immhi:immlo value); branch_target set.
  - condition (cset/csel): kind LABEL, label = cond name, imm = cond code.
  - immediates (svc/brk/movz/add): kind IMM.

Compiled by the seed gate: only seed-understood syntax.
*/
import lib.lib
import libs.asm.insn
import libs.asm.registers


# Memory addressing modes stored in asm_operand.disp_size.
int ARM64_ADDR_UOFF():
	return 0    # [Xn] / [Xn,#imm]  (unsigned scaled offset)


int ARM64_ADDR_PRE():
	return 1    # [Xn,#imm]!         (pre-index writeback)


int ARM64_ADDR_POST():
	return 2    # [Xn],#imm          (post-index writeback)


int ARM64_ADDR_PCREL():
	return 3    # [pc,#imm]          (literal)


int ARM64_ADDR_REG():
	return 4    # [Xn,Xm]            (register offset)


int arm64_bits(int w, int lo, int width):
	return (w >> lo) & ((1 << width) - 1)


# Sign-extend the low `bits` of v.
int arm64_sext(int v, int bits):
	int m = 1 << (bits - 1)
	if (v & m):
		return v - (1 << bits)
	return v


# Read one little-endian 32-bit word from a byte pointer.
int arm64_read_word(char* b):
	return (b[0] & 255) | ((b[1] & 255) << 8) | ((b[2] & 255) << 16) | ((b[3] & 255) << 24)


void arm64_set_reg(asm_operand* op, int number, int size):
	op.kind = ASM_OP_REG()
	op.rclass = ASM_RCLASS_GP()
	op.reg = number
	op.size = size


void arm64_set_imm(asm_operand* op, int v):
	op.kind = ASM_OP_IMM()
	op.imm = v


# A dot-relative label: "." for 0, else ".+N" / ".-N" (decimal, matching the
# corpus). offset is in bytes.
char* arm64_dotlabel(int offset):
	if (offset == 0):
		return c"."
	if (offset < 0):
		return strjoin(c".-", itoa(0 - offset))
	return strjoin(c".+", itoa(offset))


void arm64_set_branch(asm_insn* insn, asm_operand* op, int address, int offset):
	op.kind = ASM_OP_LABEL()
	op.label = arm64_dotlabel(offset)
	op.imm = offset
	insn.branch_target = address + offset


# Condition-code name tables. b.cond uses cs/cc; cset/csel use hs/lo. They
# differ only at codes 2 and 3.
char* arm64_cond_name_branch(int c):
	if (c == 0):
		return c"eq"
	if (c == 1):
		return c"ne"
	if (c == 2):
		return c"cs"
	if (c == 3):
		return c"cc"
	if (c == 4):
		return c"mi"
	if (c == 5):
		return c"pl"
	if (c == 6):
		return c"vs"
	if (c == 7):
		return c"vc"
	if (c == 8):
		return c"hi"
	if (c == 9):
		return c"ls"
	if (c == 10):
		return c"ge"
	if (c == 11):
		return c"lt"
	if (c == 12):
		return c"gt"
	if (c == 13):
		return c"le"
	if (c == 14):
		return c"al"
	return c"nv"


char* arm64_cond_name_cset(int c):
	if (c == 2):
		return c"hs"
	if (c == 3):
		return c"lo"
	return arm64_cond_name_branch(c)


int arm64_cond_lookup_branch(char* name):
	int c = 0
	while (c < 16):
		if (strcmp(arm64_cond_name_branch(c), name) == 0):
			return c
		c = c + 1
	return -1


int arm64_cond_lookup_cset(char* name):
	int c = 0
	while (c < 16):
		if (strcmp(arm64_cond_name_cset(c), name) == 0):
			return c
		c = c + 1
	return -1


void arm64_set_cond(asm_operand* op, char* name, int code):
	op.kind = ASM_OP_LABEL()
	op.label = name
	op.imm = code


# Mark insn as an opaque-but-recognized encoding: real mnemonic, raw word
# preserved so the encoder can reproduce it exactly.
void arm64_opaque(asm_insn* insn, char* mnemonic, int w):
	insn.mnemonic = mnemonic
	insn.raw = w


void arm64_unknown(asm_insn* insn, int w):
	insn.mnemonic = c".word"
	insn.raw = w
	arm64_set_imm(&insn.op1, w)


############################ instruction groups ###############################

# ADD/SUB (immediate), incl. cmp/cmn and mov Xd,sp aliases.
void arm64_dec_addsub_imm(asm_insn* insn, int w):
	int sf = arm64_bits(w, 31, 1)
	int op = arm64_bits(w, 30, 1)
	int s = arm64_bits(w, 29, 1)
	int sh = arm64_bits(w, 22, 1)
	int imm12 = arm64_bits(w, 10, 12)
	int rn = arm64_bits(w, 5, 5)
	int rd = arm64_bits(w, 0, 5)
	int size = 4
	if (sf):
		size = 8
	int imm = imm12
	if (sh):
		imm = imm12 << 12
	if (s == 0 & op == 0 & imm == 0 & rn == 31):
		# add Xd,sp,#0  ->  mov Xd,sp
		insn.mnemonic = c"mov"
		arm64_set_reg(&insn.op1, rd, size)
		arm64_set_reg(&insn.op2, 31, size)
		return
	if (s == 1 & rd == 31):
		insn.mnemonic = c"cmp"
		if (op == 0):
			insn.mnemonic = c"cmn"
		arm64_set_reg(&insn.op1, rn, size)
		arm64_set_imm(&insn.op2, imm)
		return
	insn.mnemonic = c"add"
	if (op):
		insn.mnemonic = c"sub"
	if (s):
		if (op):
			insn.mnemonic = c"subs"
		else:
			insn.mnemonic = c"adds"
	arm64_set_reg(&insn.op1, rd, size)
	arm64_set_reg(&insn.op2, rn, size)
	arm64_set_imm(&insn.op3, imm)


# MOVZ/MOVN/MOVK (move wide immediate).
void arm64_dec_movewide(asm_insn* insn, int w):
	int sf = arm64_bits(w, 31, 1)
	int opc = arm64_bits(w, 29, 2)
	int hw = arm64_bits(w, 21, 2)
	int imm16 = arm64_bits(w, 5, 16)
	int rd = arm64_bits(w, 0, 5)
	int size = 4
	if (sf):
		size = 8
	if (opc == 0):
		insn.mnemonic = c"movn"
	else if (opc == 2):
		insn.mnemonic = c"movz"
	else if (opc == 3):
		insn.mnemonic = c"movk"
	else:
		arm64_unknown(insn, w)
		return
	arm64_set_reg(&insn.op1, rd, size)
	arm64_set_imm(&insn.op2, imm16)
	# hw carried in op2.scale (0/1/2/3 -> lsl 0/16/32/48).
	insn.op2.scale = hw


# Logical (immediate): recognized-opaque (bitmask immediate).
void arm64_dec_logical_imm(asm_insn* insn, int w):
	int opc = arm64_bits(w, 29, 2)
	if (opc == 0):
		arm64_opaque(insn, c"and", w)
	else if (opc == 1):
		arm64_opaque(insn, c"orr", w)
	else if (opc == 2):
		arm64_opaque(insn, c"eor", w)
	else:
		arm64_opaque(insn, c"ands", w)


# Bitfield (SBFM/UBFM/BFM): recognized-opaque.
void arm64_dec_bitfield(asm_insn* insn, int w):
	int opc = arm64_bits(w, 29, 2)
	if (opc == 0):
		arm64_opaque(insn, c"sbfm", w)
	else if (opc == 1):
		arm64_opaque(insn, c"bfm", w)
	else:
		arm64_opaque(insn, c"ubfm", w)


# ADR / ADRP.
void arm64_dec_adr(asm_insn* insn, int w, int address):
	int is_page = arm64_bits(w, 31, 1)
	int immlo = arm64_bits(w, 29, 2)
	int immhi = arm64_bits(w, 5, 19)
	int rd = arm64_bits(w, 0, 5)
	int imm = arm64_sext((immhi << 2) | immlo, 21)
	arm64_set_reg(&insn.op1, rd, 8)
	if (is_page):
		insn.mnemonic = c"adrp"
		int byte_delta = imm << 12
		insn.op2.kind = ASM_OP_LABEL()
		insn.op2.label = arm64_dotlabel(byte_delta)
		insn.op2.imm = imm
		insn.branch_target = ((address >> 12) + imm) << 12
	else:
		insn.mnemonic = c"adr"
		insn.op2.kind = ASM_OP_LABEL()
		insn.op2.label = arm64_dotlabel(imm)
		insn.op2.imm = imm
		insn.branch_target = address + imm


# Unconditional branch (immediate): b / bl.
void arm64_dec_branch_imm(asm_insn* insn, int w, int address):
	int op = arm64_bits(w, 31, 1)
	int imm26 = arm64_bits(w, 0, 26)
	int offset = arm64_sext(imm26, 26) << 2
	insn.mnemonic = c"b"
	if (op):
		insn.mnemonic = c"bl"
	arm64_set_branch(insn, &insn.op1, address, offset)


# Compare and branch: cbz / cbnz.
void arm64_dec_cmp_branch(asm_insn* insn, int w, int address):
	int sf = arm64_bits(w, 31, 1)
	int op = arm64_bits(w, 24, 1)
	int imm19 = arm64_bits(w, 5, 19)
	int rt = arm64_bits(w, 0, 5)
	int size = 4
	if (sf):
		size = 8
	int offset = arm64_sext(imm19, 19) << 2
	insn.mnemonic = c"cbz"
	if (op):
		insn.mnemonic = c"cbnz"
	arm64_set_reg(&insn.op1, rt, size)
	arm64_set_branch(insn, &insn.op2, address, offset)


# Test and branch: tbz / tbnz.
void arm64_dec_test_branch(asm_insn* insn, int w, int address):
	int b5 = arm64_bits(w, 31, 1)
	int op = arm64_bits(w, 24, 1)
	int b40 = arm64_bits(w, 19, 5)
	int imm14 = arm64_bits(w, 5, 14)
	int rt = arm64_bits(w, 0, 5)
	int bit = (b5 << 5) | b40
	int size = 4
	if (b5):
		size = 8
	int offset = arm64_sext(imm14, 14) << 2
	insn.mnemonic = c"tbz"
	if (op):
		insn.mnemonic = c"tbnz"
	arm64_set_reg(&insn.op1, rt, size)
	arm64_set_imm(&insn.op2, bit)
	arm64_set_branch(insn, &insn.op3, address, offset)


# Conditional branch: b.cond.
void arm64_dec_cond_branch(asm_insn* insn, int w, int address):
	int imm19 = arm64_bits(w, 5, 19)
	int cond = arm64_bits(w, 0, 4)
	int offset = arm64_sext(imm19, 19) << 2
	insn.mnemonic = strjoin(c"b.", arm64_cond_name_branch(cond))
	arm64_set_branch(insn, &insn.op1, address, offset)


# Exception generation: svc / brk / hlt.
void arm64_dec_exception(asm_insn* insn, int w):
	int opc = arm64_bits(w, 21, 3)
	int ll = arm64_bits(w, 0, 2)
	int imm16 = arm64_bits(w, 5, 16)
	if (opc == 0 & ll == 1):
		insn.mnemonic = c"svc"
		arm64_set_imm(&insn.op1, imm16)
		return
	if (opc == 1 & ll == 0):
		insn.mnemonic = c"brk"
		arm64_set_imm(&insn.op1, imm16)
		return
	if (opc == 2 & ll == 0):
		insn.mnemonic = c"hlt"
		arm64_set_imm(&insn.op1, imm16)
		return
	arm64_unknown(insn, w)


# Unconditional branch (register): br / blr / ret and their pac variants.
void arm64_dec_branch_reg(asm_insn* insn, int w):
	int opc = arm64_bits(w, 21, 4)
	int op2 = arm64_bits(w, 16, 5)
	int op3 = arm64_bits(w, 10, 6)
	int rn = arm64_bits(w, 5, 5)
	int op4 = arm64_bits(w, 0, 5)
	# Plain forms: op2=11111, op3=000000, op4=00000.
	if (op2 == 31 & op3 == 0 & op4 == 0):
		if (opc == 0):
			insn.mnemonic = c"br"
			arm64_set_reg(&insn.op1, rn, 8)
			return
		if (opc == 1):
			insn.mnemonic = c"blr"
			arm64_set_reg(&insn.op1, rn, 8)
			return
		if (opc == 2):
			# ret Xn; ret x30 shows no operand.
			insn.mnemonic = c"ret"
			if (rn != 30):
				arm64_set_reg(&insn.op1, rn, 8)
			return
	# PAC variants with zero modifier (op3=000010, op4=11111): *aaz / *abz.
	if (op3 == 2 & op4 == 31):
		if (opc == 0):
			arm64_opaque(insn, c"braaz", w)
			return
		if (opc == 1):
			arm64_opaque(insn, c"blraaz", w)
			return
		if (opc == 2):
			arm64_opaque(insn, c"retaa", w)
			return
	arm64_opaque(insn, c"braaz", w)


# System (nop, hints, barriers): recognized-opaque except nop is exact.
void arm64_dec_system(asm_insn* insn, int w):
	if (w == 0xd503201f):
		insn.mnemonic = c"nop"
		return
	arm64_opaque(insn, c"hint", w)


# PAC data-processing (1 source): pacia/autia and *za variants.
void arm64_dec_pac(asm_insn* insn, int w):
	int fam = w & 0xfffff000
	int rn = arm64_bits(w, 5, 5)
	int rd = arm64_bits(w, 0, 5)
	if (fam == 0xdac10000):
		insn.mnemonic = c"pacia"
		arm64_set_reg(&insn.op1, rd, 8)
		arm64_set_reg(&insn.op2, rn, 8)
		return
	if (fam == 0xdac11000):
		insn.mnemonic = c"autia"
		arm64_set_reg(&insn.op1, rd, 8)
		arm64_set_reg(&insn.op2, rn, 8)
		return
	if (fam == 0xdac12000):
		insn.mnemonic = c"paciza"
		arm64_set_reg(&insn.op1, rd, 8)
		return
	if (fam == 0xdac13000):
		insn.mnemonic = c"autiza"
		arm64_set_reg(&insn.op1, rd, 8)
		return
	arm64_opaque(insn, c"pac", w)


# Logical (shifted register): and/orr/eor/ands + bic/orn/eon; mov/mvn aliases.
void arm64_dec_logical_reg(asm_insn* insn, int w):
	int sf = arm64_bits(w, 31, 1)
	int opc = arm64_bits(w, 29, 2)
	int shift = arm64_bits(w, 22, 2)
	int n = arm64_bits(w, 21, 1)
	int rm = arm64_bits(w, 16, 5)
	int imm6 = arm64_bits(w, 10, 6)
	int rn = arm64_bits(w, 5, 5)
	int rd = arm64_bits(w, 0, 5)
	int size = 4
	if (sf):
		size = 8
	# mov Xd,Xm = orr Xd,xzr,Xm (shift 0, imm6 0, N 0); mvn = orn.
	if (opc == 1 & shift == 0 & imm6 == 0 & rn == 31):
		if (n == 0):
			insn.mnemonic = c"mov"
			arm64_set_reg(&insn.op1, rd, size)
			arm64_set_reg(&insn.op2, rm, size)
			return
		insn.mnemonic = c"mvn"
		arm64_set_reg(&insn.op1, rd, size)
		arm64_set_reg(&insn.op2, rm, size)
		return
	# Shifted or extended forms with a nonzero shift are opaque.
	if (imm6 != 0 | shift != 0):
		arm64_opaque(insn, c"and", w)
		return
	if (opc == 0):
		insn.mnemonic = c"and"
	else if (opc == 1):
		insn.mnemonic = c"orr"
	else if (opc == 2):
		insn.mnemonic = c"eor"
	else:
		insn.mnemonic = c"ands"
	if (n):
		if (opc == 0):
			insn.mnemonic = c"bic"
		else if (opc == 1):
			insn.mnemonic = c"orn"
		else if (opc == 2):
			insn.mnemonic = c"eon"
		else:
			insn.mnemonic = c"bics"
	arm64_set_reg(&insn.op1, rd, size)
	arm64_set_reg(&insn.op2, rn, size)
	arm64_set_reg(&insn.op3, rm, size)


# Add/sub (shifted register): add/sub/adds/subs; neg/cmp/cmn aliases.
void arm64_dec_addsub_reg(asm_insn* insn, int w):
	int sf = arm64_bits(w, 31, 1)
	int op = arm64_bits(w, 30, 1)
	int s = arm64_bits(w, 29, 1)
	int shift = arm64_bits(w, 22, 2)
	int rm = arm64_bits(w, 16, 5)
	int imm6 = arm64_bits(w, 10, 6)
	int rn = arm64_bits(w, 5, 5)
	int rd = arm64_bits(w, 0, 5)
	int size = 4
	if (sf):
		size = 8
	if (imm6 != 0 | shift != 0):
		arm64_opaque(insn, c"add", w)
		return
	# subs Xzr,Xn,Xm = cmp; adds Xzr = cmn.
	if (s == 1 & rd == 31):
		insn.mnemonic = c"cmp"
		if (op == 0):
			insn.mnemonic = c"cmn"
		arm64_set_reg(&insn.op1, rn, size)
		arm64_set_reg(&insn.op2, rm, size)
		return
	# sub Xd,Xzr,Xm = neg; subs = negs.
	if (op == 1 & rn == 31):
		insn.mnemonic = c"neg"
		if (s):
			insn.mnemonic = c"negs"
		arm64_set_reg(&insn.op1, rd, size)
		arm64_set_reg(&insn.op2, rm, size)
		return
	insn.mnemonic = c"add"
	if (op):
		insn.mnemonic = c"sub"
	if (s):
		if (op):
			insn.mnemonic = c"subs"
		else:
			insn.mnemonic = c"adds"
	arm64_set_reg(&insn.op1, rd, size)
	arm64_set_reg(&insn.op2, rn, size)
	arm64_set_reg(&insn.op3, rm, size)


# Data-processing (3 source): madd/msub -> mul when Ra==31.
void arm64_dec_dp3(asm_insn* insn, int w):
	int sf = arm64_bits(w, 31, 1)
	int op31 = arm64_bits(w, 21, 3)
	int rm = arm64_bits(w, 16, 5)
	int o0 = arm64_bits(w, 15, 1)
	int ra = arm64_bits(w, 10, 5)
	int rn = arm64_bits(w, 5, 5)
	int rd = arm64_bits(w, 0, 5)
	int size = 4
	if (sf):
		size = 8
	if (op31 == 0):
		if (o0 == 0 & ra == 31):
			insn.mnemonic = c"mul"
			arm64_set_reg(&insn.op1, rd, size)
			arm64_set_reg(&insn.op2, rn, size)
			arm64_set_reg(&insn.op3, rm, size)
			return
		if (o0 == 0):
			insn.mnemonic = c"madd"
		else:
			insn.mnemonic = c"msub"
		arm64_set_reg(&insn.op1, rd, size)
		arm64_set_reg(&insn.op2, rn, size)
		arm64_set_reg(&insn.op3, rm, size)
		# Ra unmodeled in operands: keep raw for exact re-encode.
		insn.raw = w
		return
	arm64_opaque(insn, c"smulh", w)


# Data-processing (2 source): udiv/sdiv/lslv/lsrv/asrv/rorv.
void arm64_dec_dp2(asm_insn* insn, int w):
	int sf = arm64_bits(w, 31, 1)
	int opcode = arm64_bits(w, 10, 6)
	int rm = arm64_bits(w, 16, 5)
	int rn = arm64_bits(w, 5, 5)
	int rd = arm64_bits(w, 0, 5)
	int size = 4
	if (sf):
		size = 8
	char* m = 0
	if (opcode == 2):
		m = c"udiv"
	else if (opcode == 3):
		m = c"sdiv"
	else if (opcode == 8):
		m = c"lslv"
	else if (opcode == 9):
		m = c"lsrv"
	else if (opcode == 10):
		m = c"asrv"
	else if (opcode == 11):
		m = c"rorv"
	if (cast(int, m) == 0):
		arm64_opaque(insn, c"dp2", w)
		return
	insn.mnemonic = m
	arm64_set_reg(&insn.op1, rd, size)
	arm64_set_reg(&insn.op2, rn, size)
	arm64_set_reg(&insn.op3, rm, size)


# Conditional select: csel/csinc/csinv/csneg; cset alias when Rm=Rn=31.
void arm64_dec_cond_select(asm_insn* insn, int w):
	int sf = arm64_bits(w, 31, 1)
	int op = arm64_bits(w, 30, 1)
	int rm = arm64_bits(w, 16, 5)
	int cond = arm64_bits(w, 12, 4)
	int op2 = arm64_bits(w, 10, 2)
	int rn = arm64_bits(w, 5, 5)
	int rd = arm64_bits(w, 0, 5)
	int size = 4
	if (sf):
		size = 8
	# cset Xd,cc = csinc Xd,xzr,xzr,invert(cc): op=0,op2=1,Rm=Rn=31.
	if (op == 0 & op2 == 1 & rm == 31 & rn == 31):
		insn.mnemonic = c"cset"
		arm64_set_reg(&insn.op1, rd, size)
		# cset displays the inverse condition; flip the low bit without the
		# binary ^ operator (the committed seed does not know it yet).
		int disp = cond + 1 - 2 * (cond & 1)
		arm64_set_cond(&insn.op2, arm64_cond_name_cset(disp), disp)
		return
	# Otherwise model as csel-family, raw-preserved (cond/Rm/Rn kept via raw).
	if (op == 0 & op2 == 0):
		arm64_opaque(insn, c"csel", w)
	else if (op == 0 & op2 == 1):
		arm64_opaque(insn, c"csinc", w)
	else if (op == 1 & op2 == 0):
		arm64_opaque(insn, c"csinv", w)
	else:
		arm64_opaque(insn, c"csneg", w)


# Access width from the size field (bits 31-30): 0->1, 1->2, 2->4, 3->8.
int arm64_ldst_access(int sz):
	if (sz == 0):
		return 1
	if (sz == 1):
		return 2
	if (sz == 2):
		return 4
	return 8


# ldr/str mnemonic for the size/opc/V combination (integer only).
char* arm64_ldst_mnemonic(int sz, int opc):
	if (sz == 3):
		if (opc == 0):
			return c"str"
		return c"ldr"
	if (sz == 2):
		if (opc == 0):
			return c"str"
		if (opc == 1):
			return c"ldr"
		return c"ldrsw"
	if (sz == 1):
		if (opc == 0):
			return c"strh"
		if (opc == 1):
			return c"ldrh"
		if (opc == 2):
			return c"ldrsh"
		return c"ldrsh"
	if (opc == 0):
		return c"strb"
	if (opc == 1):
		return c"ldrb"
	return c"ldrsb"


# Rt register width for a load/store: 32-bit for byte/half/word accesses and
# for the ldrsw/ldrs* into a 64-bit dest we keep the shown width per opc.
int arm64_ldst_rt_size(int sz, int opc):
	if (sz == 3):
		return 8
	# ldrsw (word, opc 2) targets an X register; ldrsb/ldrsh 64-bit (opc 2)
	# also X. opc 3 is the 32-bit signed variant -> W.
	if (opc == 2):
		return 8
	return 4


# Load/store register (unsigned immediate offset).
void arm64_dec_ldst_uimm(asm_insn* insn, int w):
	int sz = arm64_bits(w, 30, 2)
	int v = arm64_bits(w, 26, 1)
	int opc = arm64_bits(w, 22, 2)
	int imm12 = arm64_bits(w, 10, 12)
	int rn = arm64_bits(w, 5, 5)
	int rt = arm64_bits(w, 0, 5)
	if (v):
		arm64_opaque(insn, c"ldr", w)   # SIMD/FP load-store
		return
	int access = arm64_ldst_access(sz)
	int offset = imm12 * access
	insn.mnemonic = arm64_ldst_mnemonic(sz, opc)
	arm64_set_reg(&insn.op1, rt, arm64_ldst_rt_size(sz, opc))
	insn.op2.kind = ASM_OP_MEM()
	insn.op2.base = rn
	insn.op2.index = -1
	insn.op2.disp = offset
	insn.op2.disp_size = ARM64_ADDR_UOFF()
	insn.op2.size = access


# Load/store register (unscaled / pre / post / register offset).
void arm64_dec_ldst_reg(asm_insn* insn, int w):
	int sz = arm64_bits(w, 30, 2)
	int v = arm64_bits(w, 26, 1)
	int opc = arm64_bits(w, 22, 2)
	int rn = arm64_bits(w, 5, 5)
	int rt = arm64_bits(w, 0, 5)
	if (v):
		arm64_opaque(insn, c"ldr", w)
		return
	int access = arm64_ldst_access(sz)
	insn.mnemonic = arm64_ldst_mnemonic(sz, opc)
	arm64_set_reg(&insn.op1, rt, arm64_ldst_rt_size(sz, opc))
	insn.op2.kind = ASM_OP_MEM()
	insn.op2.base = rn
	insn.op2.index = -1
	insn.op2.size = access
	int bit21 = arm64_bits(w, 21, 1)
	int op1110 = arm64_bits(w, 10, 2)
	if (bit21 == 1 & op1110 == 2):
		# register offset [Xn,Xm]
		insn.op2.index = arm64_bits(w, 16, 5)
		insn.op2.disp = 0
		insn.op2.disp_size = ARM64_ADDR_REG()
		return
	int imm9 = arm64_sext(arm64_bits(w, 12, 9), 9)
	insn.op2.disp = imm9
	if (op1110 == 0):
		insn.op2.disp_size = ARM64_ADDR_UOFF()   # unscaled (stur/ldur)
	else if (op1110 == 1):
		insn.op2.disp_size = ARM64_ADDR_POST()
	else if (op1110 == 3):
		insn.op2.disp_size = ARM64_ADDR_PRE()
	else:
		arm64_opaque(insn, insn.mnemonic, w)


# Load/store pair.
void arm64_dec_ldst_pair(asm_insn* insn, int w):
	int opc = arm64_bits(w, 30, 2)
	int v = arm64_bits(w, 26, 1)
	int mode = arm64_bits(w, 23, 2)   # 1 post, 2 offset, 3 pre
	int l = arm64_bits(w, 22, 1)
	int imm7 = arm64_sext(arm64_bits(w, 15, 7), 7)
	int rt2 = arm64_bits(w, 10, 5)
	int rn = arm64_bits(w, 5, 5)
	int rt = arm64_bits(w, 0, 5)
	if (v):
		arm64_opaque(insn, c"stp", w)
		return
	int size = 8
	if (opc == 0):
		size = 4
	int offset = imm7 * size
	insn.mnemonic = c"stp"
	if (l):
		insn.mnemonic = c"ldp"
	arm64_set_reg(&insn.op1, rt, size)
	arm64_set_reg(&insn.op2, rt2, size)
	insn.op3.kind = ASM_OP_MEM()
	insn.op3.base = rn
	insn.op3.index = -1
	insn.op3.disp = offset
	insn.op3.size = size
	if (mode == 1):
		insn.op3.disp_size = ARM64_ADDR_POST()
	else if (mode == 3):
		insn.op3.disp_size = ARM64_ADDR_PRE()
	else:
		insn.op3.disp_size = ARM64_ADDR_UOFF()


# Load register (literal): ldr Xt/Wt,[pc,#imm].
void arm64_dec_ldst_literal(asm_insn* insn, int w, int address):
	int opc = arm64_bits(w, 30, 2)
	int v = arm64_bits(w, 26, 1)
	int imm19 = arm64_bits(w, 5, 19)
	int rt = arm64_bits(w, 0, 5)
	if (v):
		arm64_opaque(insn, c"ldr", w)
		return
	int offset = arm64_sext(imm19, 19) << 2
	int size = 4
	if (opc == 1):
		size = 8
	insn.mnemonic = c"ldr"
	if (opc == 2):
		insn.mnemonic = c"ldrsw"
	arm64_set_reg(&insn.op1, rt, size)
	insn.op2.kind = ASM_OP_MEM()
	insn.op2.base = -1
	insn.op2.index = -1
	insn.op2.disp = offset
	insn.op2.disp_size = ARM64_ADDR_PCREL()
	insn.op2.size = size
	insn.branch_target = address + offset


# Conditional compare (register/immediate): recognized-opaque.
void arm64_dec_ccmp(asm_insn* insn, int w):
	int op = arm64_bits(w, 30, 1)
	if (op):
		arm64_opaque(insn, c"ccmp", w)
	else:
		arm64_opaque(insn, c"ccmn", w)


############################### top dispatch ##################################

int asm_arm64_decode(char* bytes, int length, int address, asm_insn* insn):
	asm_insn_clear(insn)
	insn.arch = ASM_ARCH_ARM64()
	insn.address = address
	insn.length = 4
	if (length < 4):
		arm64_unknown(insn, 0)
		return 4
	int w = arm64_read_word(bytes)
	insn.raw = w

	# --- Branches, exceptions, system (op0 = 101x) ---
	if ((w & 0x7c000000) == 0x14000000):
		arm64_dec_branch_imm(insn, w, address)
		return 4
	if ((w & 0x7e000000) == 0x34000000):
		arm64_dec_cmp_branch(insn, w, address)
		return 4
	if ((w & 0x7e000000) == 0x36000000):
		arm64_dec_test_branch(insn, w, address)
		return 4
	if ((w & 0xfe000000) == 0x54000000):
		if ((w & 0x00000010) == 0):
			arm64_dec_cond_branch(insn, w, address)
			return 4
	if ((w & 0xff000000) == 0xd4000000):
		arm64_dec_exception(insn, w)
		return 4
	if ((w & 0xffc00000) == 0xd5000000):
		arm64_dec_system(insn, w)
		return 4
	if ((w & 0xfe000000) == 0xd6000000):
		arm64_dec_branch_reg(insn, w)
		return 4

	# --- Data processing (immediate) (op0 = 100x) ---
	if ((w & 0x1f000000) == 0x11000000):
		arm64_dec_addsub_imm(insn, w)
		return 4
	if ((w & 0x1f800000) == 0x12800000):
		arm64_dec_movewide(insn, w)
		return 4
	if ((w & 0x1f800000) == 0x12000000):
		arm64_dec_logical_imm(insn, w)
		return 4
	if ((w & 0x1f000000) == 0x10000000):
		arm64_dec_adr(insn, w, address)
		return 4
	if ((w & 0x1f800000) == 0x13000000):
		arm64_dec_bitfield(insn, w)
		return 4

	# --- Loads and stores (op0 = x1x0) ---
	if ((w & 0x3b000000) == 0x18000000):
		arm64_dec_ldst_literal(insn, w, address)
		return 4
	if ((w & 0x3b000000) == 0x39000000):
		arm64_dec_ldst_uimm(insn, w)
		return 4
	if ((w & 0x3b000000) == 0x38000000):
		arm64_dec_ldst_reg(insn, w)
		return 4
	if ((w & 0x3a000000) == 0x28000000):
		arm64_dec_ldst_pair(insn, w)
		return 4

	# --- Data processing (register) (op0 = x101) ---
	if ((w & 0x1f000000) == 0x0a000000):
		arm64_dec_logical_reg(insn, w)
		return 4
	if ((w & 0x1f200000) == 0x0b000000):
		arm64_dec_addsub_reg(insn, w)
		return 4
	if ((w & 0x1f000000) == 0x1b000000):
		arm64_dec_dp3(insn, w)
		return 4
	# Data-processing (1 source, incl. PAC) has bit30 set (top byte 0xda) and
	# must precede the 2-source / conditional dispatches below, whose masks
	# ignore bit30 and so alias it.
	if ((w & 0xff000000) == 0xda000000):
		arm64_dec_pac(insn, w)
		return 4
	if ((w & 0x1fe00000) == 0x1a400000):
		arm64_dec_ccmp(insn, w)
		return 4
	if ((w & 0x1fe00000) == 0x1a800000):
		arm64_dec_cond_select(insn, w)
		return 4
	if ((w & 0x1fe00000) == 0x1ac00000):
		arm64_dec_dp2(insn, w)
		return 4

	# --- Scalar floating point (op0 = x111) ---
	if ((w & 0x5f000000) == 0x1e000000):
		arm64_opaque(insn, c"fp", w)
		return 4

	arm64_unknown(insn, w)
	return 4
