/*
AArch64 (A64) encoder (issue #168): asm_insn -> 32-bit word, emitted
little-endian through asm_buffer. The inverse of arm64_decode.w for the
modeled subset (everything the W compiler emits); recognized-but-unmodeled
forms (floating point, bitmask/bitfield immediates, ccmp, madd/msub with a
non-trivial accumulator) are reproduced from insn.raw, which the decoder
stashed. arm64_encode_reconstructed reports which path the last encode took
so the golden identity test can bound the raw-passthrough count.

Compiled by the seed gate: only seed-understood syntax.
*/
import lib.lib
import libs.asm.insn
import libs.asm.registers
import libs.asm.arm64_decode


# 1 if the last asm_arm64_encode rebuilt the word from operands, 0 if it fell
# back to insn.raw passthrough.
int arm64_encode_reconstructed


int arm64_enc_sf(int size):
	if (size == 8):
		return cast(int, 0x80000000)
	return 0


int arm64_ldst_size_field(int access):
	if (access == 1):
		return 0
	if (access == 2):
		return 1
	if (access == 4):
		return 2
	return 3


# Map a load/store mnemonic to its (size_field, opc), packed as
# (size_field << 4) | opc. rt_size is the Rt register width (8 or 4).
int arm64_ldst_kind(char* m, int rt_size):
	int sf = 3
	if (rt_size == 4):
		sf = 2
	if (strcmp(m, c"str") == 0):
		return (sf << 4) | 0
	if (strcmp(m, c"ldr") == 0):
		return (sf << 4) | 1
	if (strcmp(m, c"strb") == 0):
		return (0 << 4) | 0
	if (strcmp(m, c"ldrb") == 0):
		return (0 << 4) | 1
	if (strcmp(m, c"strh") == 0):
		return (1 << 4) | 0
	if (strcmp(m, c"ldrh") == 0):
		return (1 << 4) | 1
	if (strcmp(m, c"ldrsw") == 0):
		return (2 << 4) | 2
	if (strcmp(m, c"ldrsb") == 0):
		if (rt_size == 8):
			return (0 << 4) | 2
		return (0 << 4) | 3
	if (strcmp(m, c"ldrsh") == 0):
		if (rt_size == 8):
			return (1 << 4) | 2
		return (1 << 4) | 3
	return -1


int arm64_is_load_store(char* m):
	if (arm64_ldst_kind(m, 8) >= 0):
		return 1
	return 1 == 2


# Encode a modeled load/store (op1 = Rt reg, op2 = mem). Returns the word.
int arm64_enc_ldst(asm_insn* insn):
	char* m = insn.mnemonic
	int rt = insn.op1.reg
	int kind = arm64_ldst_kind(m, insn.op1.size)
	int size_field = kind >> 4
	int opc = kind & 15
	int access = 1 << size_field
	asm_operand* mem = &insn.op2
	int rn = mem.base
	int mode = mem.disp_size
	if (mode == ARM64_ADDR_PCREL()):
		# ldr literal: opc 00 w, 01 x, 10 sw.
		int lopc = 1
		if (insn.op1.size == 4):
			lopc = 0
		if (strcmp(m, c"ldrsw") == 0):
			lopc = 2
		int imm19 = (mem.disp >> 2) & 0x7ffff
		return (lopc << 30) | 0x18000000 | (imm19 << 5) | rt
	if (mode == ARM64_ADDR_REG()):
		int base = (size_field << 30) | 0x38200800 | (opc << 22) | (3 << 13)
		return base | (mem.index << 16) | (rn << 5) | rt
	if (mode == ARM64_ADDR_UOFF()):
		# Distinguish scaled unsigned-offset (imm >= 0, aligned) — that is
		# the only unsigned form the compiler emits — from stur is not
		# needed: the decoder tags stur as UOFF too, but with imm9. All
		# compiler UOFF loads are the scaled form.
		int imm12 = mem.disp / access
		int base = (size_field << 30) | 0x39000000 | (opc << 22)
		return base | ((imm12 & 0xfff) << 10) | (rn << 5) | rt
	# pre / post index (imm9, unscaled)
	int mode_bits = 3
	if (mode == ARM64_ADDR_POST()):
		mode_bits = 1
	int imm9 = mem.disp & 0x1ff
	int base = (size_field << 30) | 0x38000000 | (opc << 22)
	return base | (imm9 << 12) | (mode_bits << 10) | (rn << 5) | rt


int arm64_enc_addsub(asm_insn* insn):
	char* m = insn.mnemonic
	int size = insn.op1.size
	int sf = arm64_enc_sf(size)
	int is_reg = insn.op3.kind == ASM_OP_REG()
	int op = 0
	int s = 0
	if (strcmp(m, c"sub") == 0):
		op = 1
	else if (strcmp(m, c"adds") == 0):
		s = 1
	else if (strcmp(m, c"subs") == 0):
		op = 1
		s = 1
	int rd = insn.op1.reg
	int rn = insn.op2.reg
	if (is_reg):
		int base = sf | 0x0b000000 | (op << 30) | (s << 29)
		return base | (insn.op3.reg << 16) | (rn << 5) | rd
	int imm = insn.op3.imm
	int sh = 0
	if (imm >= 4096):
		sh = 1
		imm = imm >> 12
	int base = sf | 0x11000000 | (op << 30) | (s << 29)
	return base | (sh << 22) | ((imm & 0xfff) << 10) | (rn << 5) | rd


int arm64_enc_cmp(asm_insn* insn):
	# cmp/cmn = subs/adds with Rd=31.
	int size = insn.op1.size
	int sf = arm64_enc_sf(size)
	int op = 1
	if (strcmp(insn.mnemonic, c"cmn") == 0):
		op = 0
	int rn = insn.op1.reg
	if (insn.op2.kind == ASM_OP_REG()):
		int base = sf | 0x0b000000 | (op << 30) | (1 << 29)
		return base | (insn.op2.reg << 16) | (rn << 5) | 31
	int imm = insn.op2.imm
	int sh = 0
	if (imm >= 4096):
		sh = 1
		imm = imm >> 12
	int base = sf | 0x11000000 | (op << 30) | (1 << 29)
	return base | (sh << 22) | ((imm & 0xfff) << 10) | (rn << 5) | 31


int arm64_enc_neg(asm_insn* insn):
	# neg/negs = sub/subs with Rn=31.
	int sf = arm64_enc_sf(insn.op1.size)
	int s = 0
	if (strcmp(insn.mnemonic, c"negs") == 0):
		s = 1
	int base = sf | 0x4b000000 | (s << 29)
	return base | (insn.op2.reg << 16) | (31 << 5) | insn.op1.reg


int arm64_enc_logical(asm_insn* insn):
	int sf = arm64_enc_sf(insn.op1.size)
	char* m = insn.mnemonic
	int opc = 0
	int n = 0
	if (strcmp(m, c"orr") == 0):
		opc = 1
	else if (strcmp(m, c"eor") == 0):
		opc = 2
	else if (strcmp(m, c"ands") == 0):
		opc = 3
	else if (strcmp(m, c"bic") == 0):
		n = 1
	else if (strcmp(m, c"orn") == 0):
		opc = 1
		n = 1
	else if (strcmp(m, c"eon") == 0):
		opc = 2
		n = 1
	else if (strcmp(m, c"bics") == 0):
		opc = 3
		n = 1
	int base = sf | 0x0a000000 | (opc << 29) | (n << 21)
	return base | (insn.op3.reg << 16) | (insn.op2.reg << 5) | insn.op1.reg


int arm64_enc_mov(asm_insn* insn):
	int sf = arm64_enc_sf(insn.op1.size)
	if (insn.op2.reg == 31):
		# mov Xd,sp = add Xd,sp,#0
		return sf | 0x11000000 | (31 << 5) | insn.op1.reg
	# mov Xd,Xm = orr Xd,xzr,Xm
	return sf | 0x2a000000 | (insn.op2.reg << 16) | (31 << 5) | insn.op1.reg


int arm64_enc_mvn(asm_insn* insn):
	int sf = arm64_enc_sf(insn.op1.size)
	return sf | 0x2a200000 | (insn.op2.reg << 16) | (31 << 5) | insn.op1.reg


int arm64_enc_movewide(asm_insn* insn):
	int sf = arm64_enc_sf(insn.op1.size)
	char* m = insn.mnemonic
	int opc = 2
	if (strcmp(m, c"movn") == 0):
		opc = 0
	else if (strcmp(m, c"movk") == 0):
		opc = 3
	int hw = insn.op2.scale
	int base = sf | 0x12800000 | (opc << 29)
	return base | (hw << 21) | ((insn.op2.imm & 0xffff) << 5) | insn.op1.reg


int arm64_enc_mul(asm_insn* insn):
	int sf = arm64_enc_sf(insn.op1.size)
	return sf | 0x1b000000 | (insn.op3.reg << 16) | (31 << 10) | (insn.op2.reg << 5) | insn.op1.reg


int arm64_enc_dp2(asm_insn* insn):
	int sf = arm64_enc_sf(insn.op1.size)
	char* m = insn.mnemonic
	int opcode = 2
	if (strcmp(m, c"sdiv") == 0):
		opcode = 3
	else if (strcmp(m, c"lslv") == 0):
		opcode = 8
	else if (strcmp(m, c"lsrv") == 0):
		opcode = 9
	else if (strcmp(m, c"asrv") == 0):
		opcode = 10
	else if (strcmp(m, c"rorv") == 0):
		opcode = 11
	int base = sf | 0x1ac00000
	return base | (insn.op3.reg << 16) | (opcode << 10) | (insn.op2.reg << 5) | insn.op1.reg


int arm64_enc_cset(asm_insn* insn):
	int sf = arm64_enc_sf(insn.op1.size)
	# csinc stores the inverted condition; flip the low bit without the
	# binary ^ operator (unknown to the committed seed).
	int c = insn.op2.imm
	int condfield = c + 1 - 2 * (c & 1)
	int base = sf | 0x1a800000
	return base | (31 << 16) | (condfield << 12) | (1 << 10) | (31 << 5) | insn.op1.reg


int arm64_enc_pac(asm_insn* insn):
	char* m = insn.mnemonic
	if (strcmp(m, c"pacia") == 0):
		return cast(int, 0xdac10000) | (insn.op2.reg << 5) | insn.op1.reg
	if (strcmp(m, c"autia") == 0):
		return cast(int, 0xdac11000) | (insn.op2.reg << 5) | insn.op1.reg
	if (strcmp(m, c"paciza") == 0):
		return cast(int, 0xdac123e0) | insn.op1.reg
	return cast(int, 0xdac133e0) | insn.op1.reg


int arm64_enc_adr(asm_insn* insn):
	int imm = insn.op2.imm
	int immlo = imm & 3
	int immhi = (imm >> 2) & 0x7ffff
	int base = 0x10000000
	if (strcmp(insn.mnemonic, c"adrp") == 0):
		base = cast(int, 0x90000000)
	return base | (immlo << 29) | (immhi << 5) | insn.op1.reg


int arm64_enc_branch_imm(asm_insn* insn):
	int base = 0x14000000
	if (strcmp(insn.mnemonic, c"bl") == 0):
		base = cast(int, 0x94000000)
	return base | ((insn.op1.imm >> 2) & 0x3ffffff)


int arm64_enc_cond_branch(asm_insn* insn):
	int cond = arm64_cond_lookup_branch(insn.mnemonic + 2)
	int imm19 = (insn.op1.imm >> 2) & 0x7ffff
	return 0x54000000 | (imm19 << 5) | cond


int arm64_enc_cmp_branch(asm_insn* insn):
	int sf = arm64_enc_sf(insn.op1.size)
	int op = 0
	if (strcmp(insn.mnemonic, c"cbnz") == 0):
		op = 1
	int imm19 = (insn.op2.imm >> 2) & 0x7ffff
	return sf | 0x34000000 | (op << 24) | (imm19 << 5) | insn.op1.reg


int arm64_enc_test_branch(asm_insn* insn):
	int op = 0
	if (strcmp(insn.mnemonic, c"tbnz") == 0):
		op = 1
	int bit = insn.op2.imm
	int b5 = (bit >> 5) & 1
	int b40 = bit & 0x1f
	int imm14 = (insn.op3.imm >> 2) & 0x3fff
	return (b5 << 31) | 0x36000000 | (op << 24) | (b40 << 19) | (imm14 << 5) | insn.op1.reg


int arm64_enc_branch_reg(asm_insn* insn):
	char* m = insn.mnemonic
	int rn = 30
	if (insn.op1.kind == ASM_OP_REG()):
		rn = insn.op1.reg
	if (strcmp(m, c"br") == 0):
		return cast(int, 0xd61f0000) | (rn << 5)
	if (strcmp(m, c"blr") == 0):
		return cast(int, 0xd63f0000) | (rn << 5)
	return cast(int, 0xd65f0000) | (rn << 5)


int arm64_enc_exception(asm_insn* insn):
	int imm16 = insn.op1.imm & 0xffff
	if (strcmp(insn.mnemonic, c"brk") == 0):
		return cast(int, 0xd4200000) | (imm16 << 5)
	if (strcmp(insn.mnemonic, c"hlt") == 0):
		return cast(int, 0xd4400000) | (imm16 << 5)
	return cast(int, 0xd4000001) | (imm16 << 5)


int arm64_enc_pair(asm_insn* insn):
	char* m = insn.mnemonic
	int opc = 2
	if (insn.op1.size == 4):
		opc = 0
	int l = 0
	if (strcmp(m, c"ldp") == 0):
		l = 1
	asm_operand* mem = &insn.op3
	int mode_class = 2
	if (mem.disp_size == ARM64_ADDR_POST()):
		mode_class = 1
	else if (mem.disp_size == ARM64_ADDR_PRE()):
		mode_class = 3
	int size = 8
	if (opc == 0):
		size = 4
	int imm7 = (mem.disp / size) & 0x7f
	int base = (opc << 30) | 0x28000000 | (mode_class << 23) | (l << 22)
	return base | (imm7 << 15) | (insn.op2.reg << 10) | (mem.base << 5) | insn.op1.reg


# Encode insn into b. Returns 4 on success, -1 on an unencodable insn.
int asm_arm64_encode(asm_buffer* b, asm_insn* insn):
	arm64_encode_reconstructed = 1
	char* m = insn.mnemonic
	int w = 0
	int done = 1
	if (arm64_is_load_store(m) & insn.op2.kind == ASM_OP_MEM()):
		w = arm64_enc_ldst(insn)
	else if (strcmp(m, c"add") == 0 | strcmp(m, c"sub") == 0 | strcmp(m, c"adds") == 0 | strcmp(m, c"subs") == 0):
		w = arm64_enc_addsub(insn)
	else if (strcmp(m, c"cmp") == 0 | strcmp(m, c"cmn") == 0):
		w = arm64_enc_cmp(insn)
	else if (strcmp(m, c"neg") == 0 | strcmp(m, c"negs") == 0):
		w = arm64_enc_neg(insn)
	else if (strcmp(m, c"mov") == 0):
		w = arm64_enc_mov(insn)
	else if (strcmp(m, c"mvn") == 0):
		w = arm64_enc_mvn(insn)
	else if (strcmp(m, c"movz") == 0 | strcmp(m, c"movk") == 0 | strcmp(m, c"movn") == 0):
		w = arm64_enc_movewide(insn)
	else if (strcmp(m, c"mul") == 0):
		w = arm64_enc_mul(insn)
	else if (strcmp(m, c"udiv") == 0 | strcmp(m, c"sdiv") == 0 | strcmp(m, c"lslv") == 0 | strcmp(m, c"lsrv") == 0 | strcmp(m, c"asrv") == 0 | strcmp(m, c"rorv") == 0):
		w = arm64_enc_dp2(insn)
	else if (strcmp(m, c"cset") == 0):
		w = arm64_enc_cset(insn)
	else if (strcmp(m, c"and") == 0 | strcmp(m, c"orr") == 0 | strcmp(m, c"eor") == 0 | strcmp(m, c"ands") == 0 | strcmp(m, c"bic") == 0 | strcmp(m, c"orn") == 0 | strcmp(m, c"eon") == 0 | strcmp(m, c"bics") == 0):
		if (insn.op3.kind == ASM_OP_REG()):
			w = arm64_enc_logical(insn)
		else:
			done = 0
	else if (strcmp(m, c"pacia") == 0 | strcmp(m, c"autia") == 0 | strcmp(m, c"paciza") == 0 | strcmp(m, c"autiza") == 0):
		w = arm64_enc_pac(insn)
	else if (strcmp(m, c"adr") == 0 | strcmp(m, c"adrp") == 0):
		w = arm64_enc_adr(insn)
	else if (strcmp(m, c"b") == 0 | strcmp(m, c"bl") == 0):
		w = arm64_enc_branch_imm(insn)
	else if (m[0] == 'b' & m[1] == '.'):
		w = arm64_enc_cond_branch(insn)
	else if (strcmp(m, c"cbz") == 0 | strcmp(m, c"cbnz") == 0):
		w = arm64_enc_cmp_branch(insn)
	else if (strcmp(m, c"tbz") == 0 | strcmp(m, c"tbnz") == 0):
		w = arm64_enc_test_branch(insn)
	else if (strcmp(m, c"br") == 0 | strcmp(m, c"blr") == 0 | strcmp(m, c"ret") == 0):
		w = arm64_enc_branch_reg(insn)
	else if (strcmp(m, c"svc") == 0 | strcmp(m, c"brk") == 0 | strcmp(m, c"hlt") == 0):
		w = arm64_enc_exception(insn)
	else if (strcmp(m, c"stp") == 0 | strcmp(m, c"ldp") == 0):
		if (insn.op3.kind == ASM_OP_MEM()):
			w = arm64_enc_pair(insn)
		else:
			done = 0
	else if (strcmp(m, c"nop") == 0):
		w = cast(int, 0xd503201f)
	else:
		done = 0
	if (done == 0):
		# Recognized-opaque or unknown: reproduce the decoded word.
		arm64_encode_reconstructed = 0
		w = insn.raw
	asm_buffer_int32(b, w)
	return 4
