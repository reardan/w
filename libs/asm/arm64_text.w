/*
AArch64 (A64) text parser (issue #168): parses one line of canonical A64
assembly (the form arm64_format.w emits and tests/asm/corpus_arm64.txt
stores) into an asm_insn, which arm64_encode.w then encodes. Kept separate
from text.w so the x86 parser is untouched.

A dot-relative branch target ".+N" stores its byte offset in the operand's
imm; the encoder scales it. Registers, `#`-immediates, `[xN,#imm]` /
`[xN,xM]` / `[xN],#imm` / `[xN,#imm]!` / `[pc,#imm]` addressing and cset
condition names are all recognized.

Compiled by the seed gate: only seed-understood syntax.
*/
import lib.lib
import libs.asm.insn
import libs.asm.registers
import libs.asm.hexutil
import libs.asm.arm64_decode


struct arm64_parse:
	char* text
	int pos


int arm64_parse_peek(arm64_parse* p):
	return p.text[p.pos] & 255


void arm64_parse_skip_spaces(arm64_parse* p):
	while (p.text[p.pos] == ' '):
		p.pos = p.pos + 1


int arm64_ident_char(int c):
	if (c >= 'a' && c <= 'z'):
		return 1
	if (c >= 'A' && c <= 'Z'):
		return 1
	if (c >= '0' && c <= '9'):
		return 1
	if (c == '_'):
		return 1
	if (c == '.'):
		return 1
	return 1 == 2


# Read a maximal identifier token (letters/digits/underscore/dot).
char* arm64_parse_ident(arm64_parse* p):
	arm64_parse_skip_spaces(p)
	int start = p.pos
	while (arm64_ident_char(p.text[p.pos])):
		p.pos = p.pos + 1
	int n = p.pos - start
	char* out = malloc(n + 1)
	int i = 0
	while (i < n):
		out[i] = p.text[start + i]
		i = i + 1
	out[n] = 0
	return out


# Parse a signed number at the cursor (decimal or 0x hex; optional '-').
int arm64_parse_number(arm64_parse* p):
	int sign = 1
	if (arm64_parse_peek(p) == '-'):
		sign = 0 - 1
		p.pos = p.pos + 1
	int value = 0
	if (p.text[p.pos] == '0' && p.text[p.pos + 1] == 'x'):
		p.pos = p.pos + 2
		while (asm_hex_digit(p.text[p.pos]) >= 0):
			value = (value << 4) | asm_hex_digit(p.text[p.pos])
			p.pos = p.pos + 1
	else:
		while (p.text[p.pos] >= '0' && p.text[p.pos] <= '9'):
			value = value * 10 + (p.text[p.pos] - '0')
			p.pos = p.pos + 1
	return sign * value


# Parse a [ ... ] memory operand into op.
void arm64_parse_mem(arm64_parse* p, asm_operand* op):
	op.kind = ASM_OP_MEM()
	op.base = -1
	op.index = -1
	op.disp = 0
	op.disp_size = ARM64_ADDR_UOFF()
	op.size = 8
	p.pos = p.pos + 1   # consume '['
	arm64_parse_skip_spaces(p)
	char* base = arm64_parse_ident(p)
	if (strcmp(base, c"pc") == 0):
		op.disp_size = ARM64_ADDR_PCREL()
	else:
		op.base = asm_reg_number(asm_reg_lookup_arm64(base))
	arm64_parse_skip_spaces(p)
	if (arm64_parse_peek(p) == ','):
		p.pos = p.pos + 1
		arm64_parse_skip_spaces(p)
		if (arm64_parse_peek(p) == '#'):
			p.pos = p.pos + 1
			op.disp = arm64_parse_number(p)
			arm64_parse_skip_spaces(p)
			if (arm64_parse_peek(p) == ']'):
				p.pos = p.pos + 1
			if (arm64_parse_peek(p) == '!'):
				p.pos = p.pos + 1
				op.disp_size = ARM64_ADDR_PRE()
		else:
			char* idx = arm64_parse_ident(p)
			op.index = asm_reg_number(asm_reg_lookup_arm64(idx))
			op.disp_size = ARM64_ADDR_REG()
			arm64_parse_skip_spaces(p)
			if (arm64_parse_peek(p) == ']'):
				p.pos = p.pos + 1
		return
	if (arm64_parse_peek(p) == ']'):
		p.pos = p.pos + 1
		arm64_parse_skip_spaces(p)
		if (arm64_parse_peek(p) == ','):
			# post-index [Xn],#imm
			p.pos = p.pos + 1
			arm64_parse_skip_spaces(p)
			if (arm64_parse_peek(p) == '#'):
				p.pos = p.pos + 1
			op.disp = arm64_parse_number(p)
			op.disp_size = ARM64_ADDR_POST()


# Parse one operand. mnemonic guides condition-name recognition.
void arm64_parse_operand(arm64_parse* p, asm_insn* insn, asm_operand* op):
	asm_operand_clear(op)
	arm64_parse_skip_spaces(p)
	int c = arm64_parse_peek(p)
	if (c == '['):
		arm64_parse_mem(p, op)
		return
	if (c == '#'):
		p.pos = p.pos + 1
		op.kind = ASM_OP_IMM()
		op.imm = arm64_parse_number(p)
		op.scale = 0   # movz/movk hw (no lsl parsed => 0), not the x86 default 1
		return
	if (c == '.'):
		# dot-relative target: ".", ".+N", ".-N"
		p.pos = p.pos + 1
		int offset = 0
		if (arm64_parse_peek(p) == '+'):
			p.pos = p.pos + 1
			offset = arm64_parse_number(p)
		else if (arm64_parse_peek(p) == '-'):
			offset = arm64_parse_number(p)
		op.kind = ASM_OP_LABEL()
		op.label = arm64_dotlabel(offset)
		op.imm = offset
		insn.branch_target = insn.address + offset
		return
	char* tok = arm64_parse_ident(p)
	int reg = asm_reg_lookup_arm64(tok)
	if (reg >= 0):
		op.kind = ASM_OP_REG()
		op.rclass = ASM_RCLASS_GP()
		op.reg = asm_reg_number(reg)
		op.size = asm_reg_size(reg)
		return
	# condition name (cset x0,eq)
	int cond = arm64_cond_lookup_cset(tok)
	if (cond >= 0):
		op.kind = ASM_OP_LABEL()
		op.label = tok
		op.imm = cond
		return
	# bare label fallback
	op.kind = ASM_OP_LABEL()
	op.label = tok


# Parse a whole A64 instruction line into insn. Returns 1 on success.
int asm_arm64_parse(char* line, asm_insn* insn):
	asm_insn_clear(insn)
	insn.arch = ASM_ARCH_ARM64()
	arm64_parse parse
	parse.text = line
	parse.pos = 0
	arm64_parse* p = &parse

	# mnemonic: up to the first space
	int start = p.pos
	while (p.text[p.pos] != 0 && p.text[p.pos] != ' '):
		p.pos = p.pos + 1
	int n = p.pos - start
	char* mn = malloc(n + 1)
	int i = 0
	while (i < n):
		mn[i] = p.text[start + i]
		i = i + 1
	mn[n] = 0
	insn.mnemonic = mn
	if (mn[0] == 0):
		return 1 == 2
	arm64_parse_skip_spaces(p)
	if (arm64_parse_peek(p) == 0):
		return 1
	arm64_parse_operand(p, insn, &insn.op1)
	arm64_parse_skip_spaces(p)
	if (arm64_parse_peek(p) == ','):
		p.pos = p.pos + 1
		arm64_parse_operand(p, insn, &insn.op2)
	arm64_parse_skip_spaces(p)
	if (arm64_parse_peek(p) == ','):
		p.pos = p.pos + 1
		arm64_parse_operand(p, insn, &insn.op3)
	return 1
