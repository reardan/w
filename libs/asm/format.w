/*
Disassembler formatter for the assembler/disassembler libraries
(docs/projects/assembler_disassembler.md, issue #165): renders a
decoded asm_insn into canonical Intel-syntax text (the Phase 0.2 spec),
the exact form stored in tests/asm/corpus_*.txt.

Compiled by the seed gate: only seed-understood syntax.
*/
import lib.lib
import libs.asm.insn
import libs.asm.registers


# Numbers format as decimal below 10, lowercase hex otherwise, matching
# the corpus convention. Negatives keep a leading '-'.
char* asm_fmt_num(int v):
	if (v < 0):
		int m = 0 - v
		if (m < 10):
			return strjoin(c"-", itoa(m))
		return strjoin(c"-", asm_hex_min(m))
	if (v < 10):
		return itoa(v)
	return asm_hex_min(v)


char* asm_fmt_xmm(int number):
	return strjoin(c"xmm", itoa(number))


char* asm_fmt_reg(int arch, asm_operand* op):
	if (op.rclass == ASM_RCLASS_XMM()):
		return asm_fmt_xmm(op.reg)
	return asm_reg_name(arch, op.reg, op.size)


char* asm_fmt_size_keyword(int size):
	if (size == 1):
		return c"byte "
	if (size == 2):
		return c"word "
	if (size == 8):
		return c"qword "
	return c"dword "


# Memory operand: [base], [base+disp], [base+index*scale+disp], [disp].
char* asm_fmt_mem(int arch, asm_operand* op):
	char* inner = c""
	int wrote = 0
	# Address registers are the arch's pointer width: 64-bit on x64.
	int addr_size = 4
	if (arch == ASM_ARCH_X64()):
		addr_size = 8
	if (op.base == ASM_BASE_RIP()):
		# x64 RIP-relative base (mod=0 rm=5); prints as [rip+disp].
		inner = c"rip"
		wrote = 1
	else if (op.base >= 0):
		inner = asm_reg_name(arch, op.base, addr_size)
		wrote = 1
	if (op.index >= 0):
		char* idx = asm_reg_name(arch, op.index, addr_size)
		char* term = strjoin(idx, strjoin(c"*", itoa(op.scale)))
		if (wrote):
			inner = strjoin(inner, strjoin(c"+", term))
		else:
			inner = term
			wrote = 1
	if (op.disp != 0 | wrote == 0):
		if (wrote == 0):
			inner = asm_fmt_num(op.disp)
		else if (op.disp < 0):
			inner = strjoin(inner, strjoin(c"-", asm_fmt_num(0 - op.disp)))
		else:
			inner = strjoin(inner, strjoin(c"+", asm_fmt_num(op.disp)))
	return strjoin(c"[", strjoin(inner, c"]"))


# Size (in bytes) of the first register operand, or -1 if none. A memory
# operand shows its size keyword only when that width isn't already
# pinned by a register operand of the same width.
int asm_fmt_reg_size(asm_insn* insn):
	if (insn.op1.kind == ASM_OP_REG()):
		return insn.op1.size
	if (insn.op2.kind == ASM_OP_REG()):
		return insn.op2.size
	if (insn.op3.kind == ASM_OP_REG()):
		return insn.op3.size
	return -1


int asm_fmt_has_mem(asm_insn* insn):
	if (insn.op1.kind == ASM_OP_MEM() | insn.op2.kind == ASM_OP_MEM() | insn.op3.kind == ASM_OP_MEM()):
		return 1
	return 0


# Should a memory operand of this instruction carry a size keyword?
# Never for lea's address operand (size 0), near jmp/call (implied
# pointer size), or when a same-width register operand already pins it.
int asm_fmt_mem_needs_size(asm_insn* insn, asm_operand* op):
	if (op.size == 0):
		return 0
	if (strcmp(insn.mnemonic, c"jmp") == 0 | strcmp(insn.mnemonic, c"call") == 0):
		return 0
	if (strcmp(insn.mnemonic, c"lea") == 0):
		return 0
	int reg_size = asm_fmt_reg_size(insn)
	if (reg_size < 0):
		return 1
	if (reg_size == op.size):
		return 0
	return 1


char* asm_fmt_operand(asm_insn* insn, asm_operand* op, int has_mem):
	int arch = insn.arch
	if (op.kind == ASM_OP_REG()):
		return asm_fmt_reg(arch, op)
	if (op.kind == ASM_OP_LABEL()):
		return op.label
	if (op.kind == ASM_OP_MEM()):
		char* body = asm_fmt_mem(arch, op)
		if (asm_fmt_mem_needs_size(insn, op)):
			return strjoin(asm_fmt_size_keyword(op.size), body)
		return body
	if (op.kind == ASM_OP_IMM()):
		char* body = asm_fmt_num(op.imm)
		if (op.size == 8):
			# 64-bit immediate (movabs): value carried as imm_hi:imm.
			body = asm_hex_min64(op.imm_hi, op.imm)
		# push imm8/imm32 is the one form that shows a size keyword on a
		# lone immediate; pushw pins its width via the mnemonic instead.
		if (strcmp(insn.mnemonic, c"push") == 0):
			return strjoin(asm_fmt_size_keyword(op.size), body)
		return body
	return c"?"


# Render insn as canonical text (mnemonic + comma-separated operands).
char* asm_format(asm_insn* insn):
	if (strcmp(insn.mnemonic, c".byte") == 0):
		return strjoin(c".byte ", asm_fmt_num(insn.op1.imm))
	int count = asm_insn_operand_count(insn)
	if (count == 0):
		return strclone(insn.mnemonic)
	int has_mem = asm_fmt_has_mem(insn)
	char* out = strjoin(insn.mnemonic, c" ")
	out = strjoin(out, asm_fmt_operand(insn, &insn.op1, has_mem))
	if (count >= 2):
		out = strjoin(out, c",")
		out = strjoin(out, asm_fmt_operand(insn, &insn.op2, has_mem))
	if (count >= 3):
		out = strjoin(out, c",")
		out = strjoin(out, asm_fmt_operand(insn, &insn.op3, has_mem))
	return out
