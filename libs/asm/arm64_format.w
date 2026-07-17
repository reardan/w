/*
AArch64 (A64) disassembler formatter (issue #168): renders a decoded
asm_insn into canonical A64 text, the exact form in tests/asm/corpus_arm64.txt
(lowercase, `#`-prefixed immediates, `[xN,#imm]` addressing, `b.cc .+N`
dot-relative branches). Kept separate from format.w so the x86 formatter is
untouched.

Compiled by the seed gate: only seed-understood syntax.
*/
import lib.lib
import libs.asm.insn
import libs.asm.registers
import libs.asm.arm64_decode


# Decimal immediate with sign (add/sub/movz/mem offsets are decimal in the
# corpus, unlike svc/brk which use asm_hex_min for values >= 10).
char* arm64_fmt_dec(int v):
	if (v < 0):
		return strjoin(c"-", itoa(0 - v))
	return itoa(v)


char* arm64_fmt_reg(asm_operand* op):
	return asm_reg_name_arm64(op.reg, op.size)


# A memory operand, per its addressing mode.
char* arm64_fmt_mem(asm_operand* op):
	int mode = op.disp_size
	if (mode == ARM64_ADDR_PCREL()):
		return strjoin(c"[pc,#", strjoin(arm64_fmt_dec(op.disp), c"]"))
	char* base = asm_reg_name_arm64(op.base, 8)
	if (mode == ARM64_ADDR_REG()):
		char* idx = asm_reg_name_arm64(op.index, 8)
		return strjoin(c"[", strjoin(base, strjoin(c",", strjoin(idx, c"]"))))
	if (mode == ARM64_ADDR_POST()):
		# [Xn],#imm
		return strjoin(c"[", strjoin(base, strjoin(c"],#", arm64_fmt_dec(op.disp))))
	if (mode == ARM64_ADDR_PRE()):
		# [Xn,#imm]!
		return strjoin(c"[", strjoin(base, strjoin(c",#", strjoin(arm64_fmt_dec(op.disp), c"]!"))))
	# unsigned offset: [Xn] when zero, else [Xn,#imm]
	if (op.disp == 0):
		return strjoin(c"[", strjoin(base, c"]"))
	return strjoin(c"[", strjoin(base, strjoin(c",#", strjoin(arm64_fmt_dec(op.disp), c"]"))))


# Immediate operand text. svc/brk render hex like asm_hex_min; everything
# else (add/sub/movz) is decimal.
char* arm64_fmt_imm(asm_insn* insn, asm_operand* op):
	if (strcmp(insn.mnemonic, c"svc") == 0 | strcmp(insn.mnemonic, c"brk") == 0 | strcmp(insn.mnemonic, c"hlt") == 0):
		if (op.imm >= 0 && op.imm < 10):
			return strjoin(c"#", itoa(op.imm))
		if (op.imm < 0):
			return strjoin(c"#-", asm_hex_min(0 - op.imm))
		return strjoin(c"#", asm_hex_min(op.imm))
	char* body = arm64_fmt_dec(op.imm)
	# movz/movk with a nonzero shift show ', lsl #N'.
	if (op.scale > 0 & (strcmp(insn.mnemonic, c"movz") == 0 | strcmp(insn.mnemonic, c"movk") == 0 | strcmp(insn.mnemonic, c"movn") == 0)):
		return strjoin(c"#", strjoin(body, strjoin(c", lsl #", itoa(op.scale * 16))))
	return strjoin(c"#", body)


char* arm64_fmt_operand(asm_insn* insn, asm_operand* op):
	if (op.kind == ASM_OP_REG()):
		return arm64_fmt_reg(op)
	if (op.kind == ASM_OP_MEM()):
		return arm64_fmt_mem(op)
	if (op.kind == ASM_OP_LABEL()):
		return op.label
	if (op.kind == ASM_OP_IMM()):
		return arm64_fmt_imm(insn, op)
	return c"?"


char* asm_arm64_format(asm_insn* insn):
	if (strcmp(insn.mnemonic, c".word") == 0):
		return strjoin(c".word ", asm_hex_min(insn.raw))
	int count = asm_insn_operand_count(insn)
	if (count == 0):
		return strclone(insn.mnemonic)
	char* out = strjoin(insn.mnemonic, c" ")
	out = strjoin(out, arm64_fmt_operand(insn, &insn.op1))
	if (count >= 2):
		out = strjoin(out, c",")
		out = strjoin(out, arm64_fmt_operand(insn, &insn.op2))
	if (count >= 3):
		out = strjoin(out, c",")
		out = strjoin(out, arm64_fmt_operand(insn, &insn.op3))
	return out
