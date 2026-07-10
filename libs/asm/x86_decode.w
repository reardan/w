/*
x86 (32-bit) instruction decoder for the assembler/disassembler
libraries (docs/projects/assembler_disassembler.md, issue #165).

asm_x86_decode() reads one instruction from a byte buffer into the
arch-neutral asm_insn model (libs/asm/insn.w). The supported subset is
"everything the W compiler emits", defined concretely by
tests/asm/corpus_x86.txt; unknown bytes decode to a one-byte `.byte`
pseudo-instruction so a consumer walking a whole .text never crashes.

The `mode` parameter is the operand word size (4 here; x64 support in
#167 layers REX/64-bit onto the same ModRM core). Compiled by the seed
gate: only seed-understood syntax.
*/
import lib.lib
import libs.asm.insn
import libs.asm.registers


# Decoder cursor: the input bytes, a position, and the collected prefix
# state for the instruction currently being decoded.
struct asm_x86_dec:
	char* bytes
	int length
	int pos
	int mode        # operand word size (4 = x86, 8 = x64)
	int opsize      # operand size in bytes for the current instruction
	int rep         # 0xf2 / 0xf3 mandatory-prefix byte, or 0
	int seg         # segment-override byte, or 0
	int pfx66       # 1 when the 0x66 prefix was seen (SSE mandatory prefix)
	int rex         # x64 REX prefix byte (0x40-0x4f), or 0


# REX bit accessors: W selects 64-bit operand size; R/X/B extend the
# ModRM reg, SIB index and ModRM rm-or-base register numbers to 8-15.
int asm_x86_rex_w(asm_x86_dec* d):
	return (d.rex >> 3) & 1


int asm_x86_rex_r(asm_x86_dec* d):
	return (d.rex >> 2) & 1


int asm_x86_rex_x(asm_x86_dec* d):
	return (d.rex >> 1) & 1


int asm_x86_rex_b(asm_x86_dec* d):
	return d.rex & 1


# The ModRM reg field, extended by REX.R in x64.
int asm_x86_reg_field(asm_x86_dec* d, int modrm):
	return ((modrm >> 3) & 7) | (asm_x86_rex_r(d) << 3)


# push/pop/near-call/near-jmp default to 64-bit operand size in x64
# regardless of REX.W (only a 0x66 prefix shrinks them to 16-bit).
int asm_x86_stack_opsize(asm_x86_dec* d):
	if (d.mode == 8 & d.pfx66 == 0):
		return 8
	return d.opsize


int asm_x86_u8(asm_x86_dec* d):
	if (d.pos >= d.length):
		return 0
	int v = d.bytes[d.pos] & 255
	d.pos = d.pos + 1
	return v


int asm_x86_peek(asm_x86_dec* d):
	if (d.pos >= d.length):
		return -1
	return d.bytes[d.pos] & 255


int asm_x86_s8(asm_x86_dec* d):
	int v = asm_x86_u8(d)
	if (v >= 128):
		return v - 256
	return v


int asm_x86_u16(asm_x86_dec* d):
	int lo = asm_x86_u8(d)
	int hi = asm_x86_u8(d)
	return lo | (hi << 8)


int asm_x86_s16(asm_x86_dec* d):
	int v = asm_x86_u16(d)
	if (v >= 32768):
		return v - 65536
	return v


int asm_x86_u32(asm_x86_dec* d):
	int b0 = asm_x86_u8(d)
	int b1 = asm_x86_u8(d)
	int b2 = asm_x86_u8(d)
	int b3 = asm_x86_u8(d)
	return b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)


############################## operand helpers ################################

void asm_x86_set_reg(asm_operand* op, int rclass, int number, int size):
	op.kind = ASM_OP_REG()
	op.rclass = rclass
	op.reg = number
	op.size = size


void asm_x86_set_imm(asm_operand* op, int value, int size):
	op.kind = ASM_OP_IMM()
	op.imm = value
	op.size = size


# Decode the ModRM byte (already consumed as 'modrm') into the r/m
# operand, reading any SIB/displacement bytes. 'rm_class'/'rm_size'
# describe the register form (mod==3).
void asm_x86_decode_rm(asm_x86_dec* d, int modrm, asm_operand* rm, int rm_class, int rm_size):
	int mod = (modrm >> 6) & 3
	int rm_field = modrm & 7
	int rex_b = asm_x86_rex_b(d)
	int rex_x = asm_x86_rex_x(d)
	if (mod == 3):
		asm_x86_set_reg(rm, rm_class, rm_field | (rex_b << 3), rm_size)
		return
	rm.kind = ASM_OP_MEM()
	rm.size = rm_size
	rm.base = -1
	rm.index = -1
	rm.scale = 1
	rm.disp = 0
	rm.disp_size = 0
	if (rm_field == 4):
		# SIB byte
		int sib = asm_x86_u8(d)
		int scale = 1 << ((sib >> 6) & 3)
		int index_lo = (sib >> 3) & 7
		int base_lo = sib & 7
		# index field 4 with REX.X clear means "no index" (rsp cannot be an
		# index); r12 (4 | REX.X) IS a valid index.
		if (index_lo != 4 | rex_x != 0):
			rm.index = index_lo | (rex_x << 3)
			rm.scale = scale
		if (base_lo == 5 & mod == 0):
			# no base: absolute disp32 (SIB form) — same on x86 and x64.
			rm.disp = asm_x86_u32(d)
			rm.disp_size = 4
		else:
			rm.base = base_lo | (rex_b << 3)
	else if (rm_field == 5 & mod == 0):
		# mod=0 rm=5: [rip+disp32] on x64, absolute [disp32] on x86.
		if (d.mode == 8):
			rm.base = ASM_BASE_RIP()
		rm.disp = asm_x86_u32(d)
		rm.disp_size = 4
	else:
		rm.base = rm_field | (rex_b << 3)
	if (mod == 1):
		rm.disp = asm_x86_s8(d)
		rm.disp_size = 1
	else if (mod == 2):
		rm.disp = asm_x86_u32(d)
		rm.disp_size = 4


# Decode ModRM into reg (dest-style) and r/m operands, both GP of the
# current operand size.
void asm_x86_modrm_gp(asm_x86_dec* d, asm_operand* reg, asm_operand* rm):
	int modrm = asm_x86_u8(d)
	asm_x86_set_reg(reg, ASM_RCLASS_GP(), asm_x86_reg_field(d, modrm), d.opsize)
	asm_x86_decode_rm(d, modrm, rm, ASM_RCLASS_GP(), d.opsize)


############################### opcode groups ################################

char* asm_x86_grp1_mnemonic(int reg):
	if (reg == 0):
		return c"add"
	if (reg == 1):
		return c"or"
	if (reg == 2):
		return c"adc"
	if (reg == 3):
		return c"sbb"
	if (reg == 4):
		return c"and"
	if (reg == 5):
		return c"sub"
	if (reg == 6):
		return c"xor"
	return c"cmp"


char* asm_x86_grp2_mnemonic(int reg):
	if (reg == 0):
		return c"rol"
	if (reg == 1):
		return c"ror"
	if (reg == 2):
		return c"rcl"
	if (reg == 3):
		return c"rcr"
	if (reg == 4):
		return c"shl"
	if (reg == 5):
		return c"shr"
	if (reg == 7):
		return c"sar"
	return c"sal"


# 0x70+cc / 0x0f80+cc / 0x0f90+cc condition suffixes.
char* asm_x86_cc(int cc):
	if (cc == 0):
		return c"o"
	if (cc == 1):
		return c"no"
	if (cc == 2):
		return c"b"
	if (cc == 3):
		return c"ae"
	if (cc == 4):
		return c"e"
	if (cc == 5):
		return c"ne"
	if (cc == 6):
		return c"be"
	if (cc == 7):
		return c"a"
	if (cc == 8):
		return c"s"
	if (cc == 9):
		return c"ns"
	if (cc == 10):
		return c"p"
	if (cc == 11):
		return c"np"
	if (cc == 12):
		return c"l"
	if (cc == 13):
		return c"ge"
	if (cc == 14):
		return c"le"
	return c"g"


char* asm_x86_concat(char* a, char* b):
	int la = strlen(a)
	int lb = strlen(b)
	char* out = malloc(la + lb + 1)
	int i = 0
	while (i < la):
		out[i] = a[i]
		i = i + 1
	int j = 0
	while (j < lb):
		out[la + j] = b[j]
		j = j + 1
	out[la + lb] = 0
	return out


# A relative branch: operand is a label holding the ".+N" dot-relative
# target (N measured from the instruction's first byte), so a formatter
# with no absolute address still round-trips.
void asm_x86_rel_target(asm_insn* insn, asm_x86_dec* d, int rel):
	int target = d.pos + rel
	char* sign = c".+"
	int magnitude = target
	if (target < 0):
		sign = c".-"
		magnitude = 0 - target
	char* text = 0
	if (magnitude < 10):
		text = asm_x86_concat(sign, itoa(magnitude))
	else:
		text = asm_x86_concat(sign, asm_hex_min(magnitude))
	insn.op1.kind = ASM_OP_LABEL()
	insn.op1.label = text
	insn.branch_target = insn.address + target


################################ SSE opcodes #################################

# f2/f3 0f xx scalar-float ALU: returns the mnemonic or 0.
char* asm_x86_sse_alu(int rep, int op):
	if (op == 0x58):
		if (rep == 0xf2):
			return c"addsd"
		return c"addss"
	if (op == 0x59):
		if (rep == 0xf2):
			return c"mulsd"
		return c"mulss"
	if (op == 0x5c):
		if (rep == 0xf2):
			return c"subsd"
		return c"subss"
	if (op == 0x5e):
		if (rep == 0xf2):
			return c"divsd"
		return c"divss"
	if (op == 0x5a):
		if (rep == 0xf2):
			return c"cvtsd2ss"
		return c"cvtss2sd"
	return 0


char* asm_x86_grp8_mnemonic(int ext);

# Decode a 0f-prefixed opcode. Returns bytes consumed for the whole
# instruction, or 0 if unrecognized (caller emits .byte).
int asm_x86_decode_0f(asm_x86_dec* d, asm_insn* insn, int start):
	int op = asm_x86_u8(d)

	# syscall (0f 05)
	if (op == 0x05):
		insn.mnemonic = c"syscall"
		return d.pos - start

	# grp8 bit-test with imm8 (0f ba): bt/bts/btr/btc r/m, imm8
	if (op == 0xba):
		int modrm = asm_x86_u8(d)
		int ext = (modrm >> 3) & 7
		char* g8 = asm_x86_grp8_mnemonic(ext)
		if (cast(int, g8) == 0):
			return 0
		insn.mnemonic = g8
		asm_x86_decode_rm(d, modrm, &insn.op1, ASM_RCLASS_GP(), d.opsize)
		asm_x86_set_imm(&insn.op2, asm_x86_u8(d), 1)
		return d.pos - start

	# Jcc rel32
	if (op >= 0x80 & op <= 0x8f):
		insn.mnemonic = asm_x86_concat(c"j", asm_x86_cc(op - 0x80))
		asm_x86_rel_target(insn, d, asm_x86_u32(d))
		return d.pos - start

	# SETcc r/m8
	if (op >= 0x90 & op <= 0x9f):
		insn.mnemonic = asm_x86_concat(c"set", asm_x86_cc(op - 0x90))
		int modrm = asm_x86_u8(d)
		asm_x86_decode_rm(d, modrm, &insn.op1, ASM_RCLASS_GP(), 1)
		return d.pos - start

	# bswap r32
	if (op >= 0xc8 & op <= 0xcf):
		insn.mnemonic = c"bswap"
		asm_x86_set_reg(&insn.op1, ASM_RCLASS_GP(), (op - 0xc8) | (asm_x86_rex_b(d) << 3), d.opsize)
		return d.pos - start

	# movzx / movsx r32, r/m8|r/m16
	if (op == 0xb6 | op == 0xb7 | op == 0xbe | op == 0xbf):
		int src_size = 1
		if (op == 0xb7 | op == 0xbf):
			src_size = 2
		if (op == 0xb6 | op == 0xb7):
			insn.mnemonic = c"movzx"
		else:
			insn.mnemonic = c"movsx"
		int modrm = asm_x86_u8(d)
		asm_x86_set_reg(&insn.op1, ASM_RCLASS_GP(), asm_x86_reg_field(d, modrm), d.opsize)
		asm_x86_decode_rm(d, modrm, &insn.op2, ASM_RCLASS_GP(), src_size)
		return d.pos - start

	# imul r32, r/m32
	if (op == 0xaf):
		insn.mnemonic = c"imul"
		asm_x86_modrm_gp(d, &insn.op1, &insn.op2)
		return d.pos - start

	# ucomiss / ucomisd  (0f 2e, 66 0f 2e)
	if (op == 0x2e):
		if (d.opsize == 2):
			insn.mnemonic = c"ucomisd"
		else:
			insn.mnemonic = c"ucomiss"
		int modrm = asm_x86_u8(d)
		asm_x86_set_reg(&insn.op1, ASM_RCLASS_XMM(), asm_x86_reg_field(d, modrm), 16)
		asm_x86_decode_rm(d, modrm, &insn.op2, ASM_RCLASS_XMM(), 16)
		return d.pos - start

	# movd/movq xmm, r/m (66 0f 6e) and r/m, xmm (66 0f 7e). REX.W selects
	# the 64-bit (movq) form and widens the GP operand.
	if ((op == 0x6e | op == 0x7e) & d.pfx66):
		int gsize = 4
		insn.mnemonic = c"movd"
		if (asm_x86_rex_w(d)):
			gsize = 8
			insn.mnemonic = c"movq"
		int modrm = asm_x86_u8(d)
		asm_operand xmm
		asm_operand_clear(&xmm)
		asm_x86_set_reg(&xmm, ASM_RCLASS_XMM(), asm_x86_reg_field(d, modrm), 16)
		asm_operand rm
		asm_operand_clear(&rm)
		asm_x86_decode_rm(d, modrm, &rm, ASM_RCLASS_GP(), gsize)
		if (op == 0x6e):
			insn.op1 = xmm
			insn.op2 = rm
		else:
			insn.op1 = rm
			insn.op2 = xmm
		return d.pos - start

	# movss/movsd load: f3/f2 0f 10  r/m -> xmm
	if (op == 0x10 & (d.rep == 0xf2 | d.rep == 0xf3)):
		if (d.rep == 0xf2):
			insn.mnemonic = c"movsd"
		else:
			insn.mnemonic = c"movss"
		int modrm = asm_x86_u8(d)
		asm_x86_set_reg(&insn.op1, ASM_RCLASS_XMM(), asm_x86_reg_field(d, modrm), 16)
		asm_x86_decode_rm(d, modrm, &insn.op2, ASM_RCLASS_XMM(), 16)
		return d.pos - start

	# movss/movsd store: f3/f2 0f 11  xmm -> r/m
	if (op == 0x11 & (d.rep == 0xf2 | d.rep == 0xf3)):
		if (d.rep == 0xf2):
			insn.mnemonic = c"movsd"
		else:
			insn.mnemonic = c"movss"
		int modrm = asm_x86_u8(d)
		asm_operand xmm
		asm_operand_clear(&xmm)
		asm_x86_set_reg(&xmm, ASM_RCLASS_XMM(), asm_x86_reg_field(d, modrm), 16)
		asm_x86_decode_rm(d, modrm, &insn.op1, ASM_RCLASS_XMM(), 16)
		insn.op2 = xmm
		return d.pos - start

	# cvtsi2ss/cvtsi2sd xmm, r/m (f3/f2 0f 2a). REX.W widens the GP source.
	if (op == 0x2a & (d.rep == 0xf3 | d.rep == 0xf2)):
		if (d.rep == 0xf2):
			insn.mnemonic = c"cvtsi2sd"
		else:
			insn.mnemonic = c"cvtsi2ss"
		int modrm = asm_x86_u8(d)
		asm_x86_set_reg(&insn.op1, ASM_RCLASS_XMM(), asm_x86_reg_field(d, modrm), 16)
		asm_x86_decode_rm(d, modrm, &insn.op2, ASM_RCLASS_GP(), d.opsize)
		return d.pos - start

	# cvttss2si/cvttsd2si r32, xmm (f3/f2 0f 2c). REX.W widens the GP dest.
	if (op == 0x2c & (d.rep == 0xf3 | d.rep == 0xf2)):
		if (d.rep == 0xf2):
			insn.mnemonic = c"cvttsd2si"
		else:
			insn.mnemonic = c"cvttss2si"
		int modrm = asm_x86_u8(d)
		asm_x86_set_reg(&insn.op1, ASM_RCLASS_GP(), asm_x86_reg_field(d, modrm), d.opsize)
		asm_x86_decode_rm(d, modrm, &insn.op2, ASM_RCLASS_XMM(), 16)
		return d.pos - start

	# scalar-float ALU (add/mul/sub/div/cvt between ss/sd)
	char* sse = asm_x86_sse_alu(d.rep, op)
	if (cast(int, sse) != 0):
		insn.mnemonic = sse
		int modrm = asm_x86_u8(d)
		asm_x86_set_reg(&insn.op1, ASM_RCLASS_XMM(), asm_x86_reg_field(d, modrm), 16)
		asm_x86_decode_rm(d, modrm, &insn.op2, ASM_RCLASS_XMM(), 16)
		return d.pos - start

	return 0


############################ main opcode dispatch ############################

# Defined below; the single-pass compiler needs them declared before use.
int asm_x86_unknown(asm_insn* insn, char* bytes);
int asm_x86_decode_vex(asm_x86_dec* d, asm_insn* insn, char* bytes, int length, int start);
char* asm_x86_grp3_mnemonic(int ext);
char* asm_x86_grp5_mnemonic(int ext);

# ALU r/m,r and eax,imm families share opcode column layout: the low
# three bits of the base opcode select the form.
int asm_x86_alu_base(int op):
	if (op < 0x40):
		int col = op & 7
		if (col <= 5):
			return op - col
	return -1


char* asm_x86_alu_mnemonic(int base):
	if (base == 0x00):
		return c"add"
	if (base == 0x08):
		return c"or"
	if (base == 0x10):
		return c"adc"
	if (base == 0x18):
		return c"sbb"
	if (base == 0x20):
		return c"and"
	if (base == 0x28):
		return c"sub"
	if (base == 0x30):
		return c"xor"
	if (base == 0x38):
		return c"cmp"
	return 0


# Decode one instruction at bytes[0..length) with virtual address
# 'address'. Fills insn and returns the byte length (>=1). Unknown
# encodings yield mnemonic ".byte" of length 1.
int asm_x86_decode(char* bytes, int length, int address, int mode, asm_insn* insn):
	asm_insn_clear(insn)
	insn.address = address
	if (mode == 8):
		insn.arch = ASM_ARCH_X64()
	else:
		insn.arch = ASM_ARCH_X86()

	asm_x86_dec dec
	dec.bytes = bytes
	dec.length = length
	dec.pos = 0
	dec.mode = mode
	# x64's default operand size is 32-bit (REX.W promotes it to 64); x86's
	# is its word size. 0x66 makes it 16-bit either way.
	if (mode == 8):
		dec.opsize = 4
	else:
		dec.opsize = mode
	dec.rep = 0
	dec.seg = 0
	dec.pfx66 = 0
	dec.rex = 0
	asm_x86_dec* d = &dec

	# Prefixes. A REX prefix (0x40-0x4f, x64 only) must be the last prefix
	# before the opcode, so consuming it ends the scan; REX.W then overrides
	# the operand size to 64-bit.
	int scanning = 1
	while (scanning):
		int p = asm_x86_peek(d)
		if (p == 0x66):
			dec.opsize = 2
			dec.pfx66 = 1
			dec.pos = dec.pos + 1
		else if (p == 0x67):
			dec.pos = dec.pos + 1
		else if (p == 0xf2 | p == 0xf3):
			dec.rep = p
			dec.pos = dec.pos + 1
		else if (p == 0x64 | p == 0x65):
			dec.seg = p
			dec.pos = dec.pos + 1
		else if (mode == 8 & p >= 0x40 & p <= 0x4f):
			dec.rex = p
			dec.pos = dec.pos + 1
			if ((p >> 3) & 1):
				dec.opsize = 8
			scanning = 0
		else:
			scanning = 0

	int start = 0
	int op = asm_x86_u8(d)

	# Two-byte opcodes
	if (op == 0x0f):
		int consumed = asm_x86_decode_0f(d, insn, start)
		if (consumed > 0):
			insn.length = consumed
			return consumed
		return asm_x86_unknown(insn, bytes)

	# VEX (F16C): the only 3-byte-VEX forms the compiler emits.
	if (op == 0xc4):
		int consumed = asm_x86_decode_vex(d, insn, bytes, length, start)
		if (consumed > 0):
			insn.length = consumed
			return consumed
		return asm_x86_unknown(insn, bytes)

	# ALU r/m,r ; r,r/m ; al/eax,imm
	int base = asm_x86_alu_base(op)
	if (base >= 0):
		char* mnemonic = asm_x86_alu_mnemonic(base)
		int col = op - base
		if (col == 0):
			# r/m8, r8
			int modrm = asm_x86_u8(d)
			asm_x86_set_reg(&insn.op2, ASM_RCLASS_GP(), asm_x86_reg_field(d, modrm), 1)
			asm_x86_decode_rm(d, modrm, &insn.op1, ASM_RCLASS_GP(), 1)
			insn.mnemonic = mnemonic
			insn.length = d.pos - start
			return insn.length
		if (col == 1):
			insn.mnemonic = mnemonic
			asm_operand reg
			asm_operand_clear(&reg)
			asm_operand rm
			asm_operand_clear(&rm)
			asm_x86_modrm_gp(d, &reg, &rm)
			insn.op1 = rm
			insn.op2 = reg
			insn.length = d.pos - start
			return insn.length
		if (col == 3):
			insn.mnemonic = mnemonic
			asm_x86_modrm_gp(d, &insn.op1, &insn.op2)
			insn.length = d.pos - start
			return insn.length
		if (col == 5):
			# eax, imm(16/32)
			insn.mnemonic = mnemonic
			asm_x86_set_reg(&insn.op1, ASM_RCLASS_GP(), 0, d.opsize)
			if (d.opsize == 2):
				asm_x86_set_imm(&insn.op2, asm_x86_u16(d), 2)
			else:
				asm_x86_set_imm(&insn.op2, asm_x86_u32(d), 4)
			insn.length = d.pos - start
			return insn.length

	# inc/dec r32 (0x40-0x4f)
	if (op >= 0x40 & op <= 0x4f):
		if (op < 0x48):
			insn.mnemonic = c"inc"
			asm_x86_set_reg(&insn.op1, ASM_RCLASS_GP(), op - 0x40, d.opsize)
		else:
			insn.mnemonic = c"dec"
			asm_x86_set_reg(&insn.op1, ASM_RCLASS_GP(), op - 0x48, d.opsize)
		insn.length = d.pos - start
		return insn.length

	# push/pop r32 (0x50-0x5f). In x64 these default to 64-bit operand size
	# (no REX.W needed); REX.B extends the register to r8-r15.
	if (op >= 0x50 & op <= 0x57):
		insn.mnemonic = c"push"
		asm_x86_set_reg(&insn.op1, ASM_RCLASS_GP(), (op - 0x50) | (asm_x86_rex_b(d) << 3), asm_x86_stack_opsize(d))
		insn.length = d.pos - start
		return insn.length
	if (op >= 0x58 & op <= 0x5f):
		insn.mnemonic = c"pop"
		asm_x86_set_reg(&insn.op1, ASM_RCLASS_GP(), (op - 0x58) | (asm_x86_rex_b(d) << 3), asm_x86_stack_opsize(d))
		insn.length = d.pos - start
		return insn.length

	# push imm32 / imm16
	if (op == 0x68):
		if (d.opsize == 2):
			insn.mnemonic = c"pushw"
			asm_x86_set_imm(&insn.op1, asm_x86_u16(d), 2)
		else:
			insn.mnemonic = c"push"
			asm_x86_set_imm(&insn.op1, asm_x86_u32(d), 4)
			insn.op1.size = 4
		insn.length = d.pos - start
		return insn.length

	# push imm8 (sign-extended)
	if (op == 0x6a):
		if (d.opsize == 2):
			insn.mnemonic = c"pushw"
			# size 1 (not the logical 2) records that this was the compact
			# imm8 wire form, matching how plain "push" already distinguishes
			# its two forms (1 vs 4) and what asm_x86_encode's pushw_imm8
			# check reads back; recording the logical width here instead
			# made decode(encode(x)) pick the wider 0x68 form on re-encode
			# for any pushw value that happens to fit int8 (asm_fuzz_x86_test,
			# issue #171 — corpus_x86.txt's "666a02|pushw 2" already covers
			# this exact wire form as a golden decode round trip, but only
			# asm_fuzz_x86_test's decode->encode identity property caught
			# the re-encode mismatch, since the format-text comparison the
			# corpus test does doesn't depend on this field).
			asm_x86_set_imm(&insn.op1, asm_x86_s8(d), 1)
		else:
			insn.mnemonic = c"push"
			asm_x86_set_imm(&insn.op1, asm_x86_s8(d), 1)
		insn.length = d.pos - start
		return insn.length

	# imul r32, r/m32, imm32 (0x69)
	if (op == 0x69):
		insn.mnemonic = c"imul"
		asm_x86_modrm_gp(d, &insn.op1, &insn.op2)
		asm_x86_set_imm(&insn.op3, asm_x86_u32(d), 4)
		insn.length = d.pos - start
		return insn.length

	# Jcc rel8 (0x70-0x7f)
	if (op >= 0x70 & op <= 0x7f):
		insn.mnemonic = asm_x86_concat(c"j", asm_x86_cc(op - 0x70))
		asm_x86_rel_target(insn, d, asm_x86_s8(d))
		insn.length = d.pos - start
		return insn.length

	# grp1 r/m32, imm32 (0x81) and r/m32, imm8 (0x83)
	if (op == 0x81 | op == 0x83):
		int modrm = asm_x86_u8(d)
		insn.mnemonic = asm_x86_grp1_mnemonic((modrm >> 3) & 7)
		asm_x86_decode_rm(d, modrm, &insn.op1, ASM_RCLASS_GP(), d.opsize)
		if (op == 0x81):
			if (d.opsize == 2):
				asm_x86_set_imm(&insn.op2, asm_x86_s16(d), 2)
			else:
				asm_x86_set_imm(&insn.op2, asm_x86_u32(d), 4)
		else:
			asm_x86_set_imm(&insn.op2, asm_x86_s8(d), 1)
		insn.length = d.pos - start
		return insn.length

	# test r/m32, r32 (0x85) and r/m8, r8 (0x84)
	if (op == 0x84 | op == 0x85):
		insn.mnemonic = c"test"
		int size = d.opsize
		if (op == 0x84):
			size = 1
		int modrm = asm_x86_u8(d)
		asm_x86_set_reg(&insn.op2, ASM_RCLASS_GP(), asm_x86_reg_field(d, modrm), size)
		asm_x86_decode_rm(d, modrm, &insn.op1, ASM_RCLASS_GP(), size)
		insn.length = d.pos - start
		return insn.length

	# mov r/m8,r8 (0x88) ; r/m32,r32 (0x89) ; r8,r/m8 (0x8a) ; r32,r/m32 (0x8b)
	if (op == 0x88 | op == 0x89 | op == 0x8a | op == 0x8b):
		insn.mnemonic = c"mov"
		int size = d.opsize
		if (op == 0x88 | op == 0x8a):
			size = 1
		int modrm = asm_x86_u8(d)
		asm_operand reg
		asm_operand_clear(&reg)
		asm_operand rm
		asm_operand_clear(&rm)
		asm_x86_set_reg(&reg, ASM_RCLASS_GP(), asm_x86_reg_field(d, modrm), size)
		asm_x86_decode_rm(d, modrm, &rm, ASM_RCLASS_GP(), size)
		if (op == 0x88 | op == 0x89):
			insn.op1 = rm
			insn.op2 = reg
		else:
			insn.op1 = reg
			insn.op2 = rm
		insn.length = d.pos - start
		return insn.length

	# lea r32, m (0x8d)
	if (op == 0x8d):
		insn.mnemonic = c"lea"
		asm_x86_modrm_gp(d, &insn.op1, &insn.op2)
		insn.op2.size = 0
		insn.length = d.pos - start
		return insn.length

	# nop / xchg eax,r32 (0x90-0x97)
	if (op >= 0x90 & op <= 0x97):
		if (op == 0x90):
			insn.mnemonic = c"nop"
		else:
			insn.mnemonic = c"xchg"
			asm_x86_set_reg(&insn.op1, ASM_RCLASS_GP(), (op - 0x90) | (asm_x86_rex_b(d) << 3), d.opsize)
			asm_x86_set_reg(&insn.op2, ASM_RCLASS_GP(), 0, d.opsize)
		insn.length = d.pos - start
		return insn.length

	# cdq (0x99) / cqo (0x99 with REX.W)
	if (op == 0x99):
		if (asm_x86_rex_w(d)):
			insn.mnemonic = c"cqo"
		else:
			insn.mnemonic = c"cdq"
		insn.length = d.pos - start
		return insn.length

	# cwde (0x98) / cdqe (0x98 with REX.W)
	if (op == 0x98):
		if (asm_x86_rex_w(d)):
			insn.mnemonic = c"cdqe"
		else:
			insn.mnemonic = c"cwde"
		insn.length = d.pos - start
		return insn.length

	# mov r8, imm8 (0xb0-0xb7)
	if (op >= 0xb0 & op <= 0xb7):
		insn.mnemonic = c"mov"
		asm_x86_set_reg(&insn.op1, ASM_RCLASS_GP(), (op - 0xb0) | (asm_x86_rex_b(d) << 3), 1)
		asm_x86_set_imm(&insn.op2, asm_x86_u8(d), 1)
		insn.length = d.pos - start
		return insn.length

	# mov r32, imm32 (0xb8-0xbf)
	if (op >= 0xb8 & op <= 0xbf):
		insn.mnemonic = c"mov"
		asm_x86_set_reg(&insn.op1, ASM_RCLASS_GP(), (op - 0xb8) | (asm_x86_rex_b(d) << 3), d.opsize)
		if (d.opsize == 8):
			# movabs r64, imm64: low then high 32-bit halves.
			asm_x86_set_imm(&insn.op2, asm_x86_u32(d), 8)
			insn.op2.imm_hi = asm_x86_u32(d)
		else if (d.opsize == 2):
			asm_x86_set_imm(&insn.op2, asm_x86_u16(d), 2)
		else:
			asm_x86_set_imm(&insn.op2, asm_x86_u32(d), 4)
		insn.length = d.pos - start
		return insn.length

	# grp2 r/m32, cl (0xd3) and r/m32, 1 (0xd1)
	if (op == 0xd1 | op == 0xd3):
		int modrm = asm_x86_u8(d)
		insn.mnemonic = asm_x86_grp2_mnemonic((modrm >> 3) & 7)
		asm_x86_decode_rm(d, modrm, &insn.op1, ASM_RCLASS_GP(), d.opsize)
		if (op == 0xd3):
			asm_x86_set_reg(&insn.op2, ASM_RCLASS_GP(), 1, 1)
		else:
			asm_x86_set_imm(&insn.op2, 1, 1)
		insn.length = d.pos - start
		return insn.length

	# fstp dword [m] (0xd9 /3)
	if (op == 0xd9):
		int modrm = asm_x86_u8(d)
		int ext = (modrm >> 3) & 7
		if (ext == 3):
			insn.mnemonic = c"fstp"
			asm_x86_decode_rm(d, modrm, &insn.op1, ASM_RCLASS_X87(), 4)
			insn.length = d.pos - start
			return insn.length
		return asm_x86_unknown(insn, bytes)

	# call rel32 (0xe8) / jmp rel32 (0xe9)
	if (op == 0xe8 | op == 0xe9):
		if (op == 0xe8):
			insn.mnemonic = c"call"
		else:
			insn.mnemonic = c"jmp"
		asm_x86_rel_target(insn, d, asm_x86_u32(d))
		insn.length = d.pos - start
		return insn.length

	# int3 (0xcc) / int imm8 (0xcd)
	if (op == 0xcc):
		insn.mnemonic = c"int3"
		insn.length = d.pos - start
		return insn.length
	if (op == 0xcd):
		insn.mnemonic = c"int"
		asm_x86_set_imm(&insn.op1, asm_x86_u8(d), 1)
		insn.length = d.pos - start
		return insn.length

	# ret (0xc3)
	if (op == 0xc3):
		insn.mnemonic = c"ret"
		insn.length = d.pos - start
		return insn.length

	# grp3 r/m32 (0xf7): not/neg/mul/imul/div/idiv
	if (op == 0xf6 | op == 0xf7):
		int size = d.opsize
		if (op == 0xf6):
			size = 1
		int modrm = asm_x86_u8(d)
		int ext = (modrm >> 3) & 7
		char* mnemonic = asm_x86_grp3_mnemonic(ext)
		if (cast(int, mnemonic) == 0):
			return asm_x86_unknown(insn, bytes)
		insn.mnemonic = mnemonic
		asm_x86_decode_rm(d, modrm, &insn.op1, ASM_RCLASS_GP(), size)
		if (ext == 0):
			# test r/m, imm
			if (size == 1):
				asm_x86_set_imm(&insn.op2, asm_x86_u8(d), 1)
			else if (d.opsize == 2):
				asm_x86_set_imm(&insn.op2, asm_x86_u16(d), 2)
			else:
				asm_x86_set_imm(&insn.op2, asm_x86_u32(d), 4)
		insn.length = d.pos - start
		return insn.length

	# grp5 (0xff): inc/dec/call/jmp/push r/m32
	if (op == 0xff):
		int modrm = asm_x86_u8(d)
		int ext = (modrm >> 3) & 7
		char* mnemonic = asm_x86_grp5_mnemonic(ext)
		if (cast(int, mnemonic) == 0):
			return asm_x86_unknown(insn, bytes)
		insn.mnemonic = mnemonic
		int size = d.opsize
		# call/jmp/push through r/m default to 64-bit in x64; inc/dec honor
		# REX.W via opsize.
		if (ext >= 2):
			size = asm_x86_stack_opsize(d)
		asm_x86_decode_rm(d, modrm, &insn.op1, ASM_RCLASS_GP(), size)
		insn.length = d.pos - start
		return insn.length

	# movsxd r64, r/m32 (0x63, x64 only): sign-extend a 32-bit r/m to 64.
	if (op == 0x63 & d.mode == 8):
		insn.mnemonic = c"movsxd"
		int modrm = asm_x86_u8(d)
		asm_x86_set_reg(&insn.op1, ASM_RCLASS_GP(), asm_x86_reg_field(d, modrm), d.opsize)
		asm_x86_decode_rm(d, modrm, &insn.op2, ASM_RCLASS_GP(), 4)
		insn.length = d.pos - start
		return insn.length

	return asm_x86_unknown(insn, bytes)


char* asm_x86_grp3_mnemonic(int ext):
	if (ext == 0):
		return c"test"
	if (ext == 2):
		return c"not"
	if (ext == 3):
		return c"neg"
	if (ext == 4):
		return c"mul"
	if (ext == 5):
		return c"imul"
	if (ext == 6):
		return c"div"
	if (ext == 7):
		return c"idiv"
	return 0


# 0f ba /ext bit-test-with-imm8 group (bt/bts/btr/btc use ext 4/5/6/7).
char* asm_x86_grp8_mnemonic(int ext):
	if (ext == 4):
		return c"bt"
	if (ext == 5):
		return c"bts"
	if (ext == 6):
		return c"btr"
	if (ext == 7):
		return c"btc"
	return 0


char* asm_x86_grp5_mnemonic(int ext):
	if (ext == 0):
		return c"inc"
	if (ext == 1):
		return c"dec"
	if (ext == 2):
		return c"call"
	if (ext == 4):
		return c"jmp"
	if (ext == 6):
		return c"push"
	return 0


# One unknown byte -> `.byte 0xNN`, length 1, so callers keep walking.
int asm_x86_unknown(asm_insn* insn, char* bytes):
	asm_insn_clear(insn)
	insn.mnemonic = c".byte"
	asm_x86_set_imm(&insn.op1, bytes[0] & 255, 1)
	insn.length = 1
	return 1


# The two F16C VEX forms the graphics codegen emits:
#   c4 e2 79 13 /r        vcvtph2ps xmm, xmm
#   c4 e3 79 1d /r ib     vcvtps2ph xmm, xmm, imm8
int asm_x86_decode_vex(asm_x86_dec* d, asm_insn* insn, char* bytes, int length, int start):
	if (length < 5):
		return 0
	int b1 = asm_x86_u8(d)
	int b2 = asm_x86_u8(d)
	int op = asm_x86_u8(d)
	if (b1 == 0xe2 & b2 == 0x79 & op == 0x13):
		insn.mnemonic = c"vcvtph2ps"
		int modrm = asm_x86_u8(d)
		asm_x86_set_reg(&insn.op1, ASM_RCLASS_XMM(), (modrm >> 3) & 7, 16)
		asm_x86_decode_rm(d, modrm, &insn.op2, ASM_RCLASS_XMM(), 16)
		return d.pos - start
	if (b1 == 0xe3 & b2 == 0x79 & op == 0x1d):
		insn.mnemonic = c"vcvtps2ph"
		int modrm = asm_x86_u8(d)
		asm_x86_set_reg(&insn.op1, ASM_RCLASS_XMM(), modrm & 7, 16)
		asm_x86_decode_rm(d, modrm, &insn.op2, ASM_RCLASS_XMM(), 16)
		asm_x86_set_imm(&insn.op3, asm_x86_u8(d), 1)
		return d.pos - start
	return 0
