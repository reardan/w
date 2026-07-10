/*
Text assembler front end for the assembler/disassembler libraries
(docs/projects/assembler_disassembler.md, issue #166): parses one line
of canonical Intel-syntax assembly (the Phase 0.2 spec / the format
libs/asm/format.w emits) into an asm_insn, which libs/asm/x86_encode.w
then encodes.

A parsed operand leaves disp_size at "auto", so the encoder picks the
minimal displacement form; the exact-width reproduction path is
decode -> encode, which carries the recorded widths.

Compiled by the seed gate: only seed-understood syntax.
*/
import lib.lib
import libs.asm.insn
import libs.asm.registers
import libs.asm.hexutil


# Parser cursor over the operand text.
struct asm_parse:
	char* text
	int pos


int asm_parse_peek(asm_parse* p):
	return p.text[p.pos] & 255


void asm_parse_skip_spaces(asm_parse* p):
	while (p.text[p.pos] == ' '):
		p.pos = p.pos + 1


int asm_parse_is_ident(int c):
	if (c >= 'a' & c <= 'z'):
		return 1
	if (c >= 'A' & c <= 'Z'):
		return 1
	if (c >= '0' & c <= '9'):
		return 1
	if (c == '_'):
		return 1
	return 1 == 2


# Read a maximal identifier/number token (letters, digits, underscore),
# including a leading '-' so negative immediates tokenize whole.
char* asm_parse_token(asm_parse* p):
	asm_parse_skip_spaces(p)
	int start = p.pos
	if (p.text[p.pos] == '-'):
		p.pos = p.pos + 1
	while (asm_parse_is_ident(p.text[p.pos])):
		p.pos = p.pos + 1
	int n = p.pos - start
	char* out = malloc(n + 1)
	int i = 0
	while (i < n):
		out[i] = p.text[start + i]
		i = i + 1
	out[n] = 0
	return out


# Parse a signed number token (decimal or 0x hex, optional leading '-').
int asm_parse_number(char* s):
	int sign = 1
	int i = 0
	if (s[0] == '-'):
		sign = 0 - 1
		i = 1
	int value = 0
	if (s[i] == '0' & s[i + 1] == 'x'):
		i = i + 2
		while (s[i] != 0):
			value = (value << 4) | asm_hex_digit(s[i])
			i = i + 1
	else:
		while (s[i] != 0):
			value = value * 10 + (s[i] - '0')
			i = i + 1
	return sign * value


# High 32 bits of a hex immediate token wider than 32 bits (for movabs
# r64, imm64). asm_parse_number keeps the low 32 bits; this returns the
# high word (0 for decimal, negative, or <= 32-bit values).
int asm_parse_number_hi(char* s):
	if (s[0] == '-'):
		return 0
	if (s[0] != '0' | s[1] != 'x'):
		return 0
	int i = 2
	int hi = 0
	int lo = 0
	while (s[i] != 0):
		hi = (hi << 4) | ((lo >> 28) & 15)
		lo = (lo << 4) | asm_hex_digit(s[i])
		i = i + 1
	return hi


int asm_parse_is_number_start(int c):
	if (c >= '0' & c <= '9'):
		return 1
	if (c == '-'):
		return 1
	return 1 == 2


# Size keyword -> byte width, or 0 if the token isn't one.
int asm_parse_size_keyword(char* tok):
	if (strcmp(tok, c"byte") == 0):
		return 1
	if (strcmp(tok, c"word") == 0):
		return 2
	if (strcmp(tok, c"dword") == 0):
		return 4
	if (strcmp(tok, c"qword") == 0):
		return 8
	return 0


# Parse a [ ... ] memory body into op (base/index/scale/disp).
void asm_parse_mem(asm_parse* p, asm_operand* op, int arch):
	op.kind = ASM_OP_MEM()
	op.base = -1
	op.index = -1
	op.scale = 1
	op.disp = 0
	op.disp_size = 0
	p.pos = p.pos + 1   # consume '['
	int sign = 1
	while (asm_parse_peek(p) != ']' & asm_parse_peek(p) != 0):
		asm_parse_skip_spaces(p)
		int c = asm_parse_peek(p)
		if (c == '+'):
			sign = 1
			p.pos = p.pos + 1
		else if (c == '-'):
			sign = 0 - 1
			p.pos = p.pos + 1
		else if (asm_parse_is_number_start(c)):
			char* tok = asm_parse_token(p)
			op.disp = op.disp + sign * asm_parse_number(tok)
		else:
			# register term, optionally scaled (reg*scale)
			char* tok = asm_parse_token(p)
			int reg = asm_reg_lookup_x86(tok)
			int number = asm_reg_number(reg)
			asm_parse_skip_spaces(p)
			if (asm_parse_peek(p) == '*'):
				p.pos = p.pos + 1
				char* scale_tok = asm_parse_token(p)
				op.index = number
				op.scale = asm_parse_number(scale_tok)
			else if (op.base < 0):
				op.base = number
			else:
				op.index = number
	if (asm_parse_peek(p) == ']'):
		p.pos = p.pos + 1


# Parse one operand into op. size_hint carries a preceding size keyword.
void asm_parse_operand(asm_parse* p, asm_operand* op, int arch, int size_hint):
	asm_operand_clear(op)
	asm_parse_skip_spaces(p)
	int c = asm_parse_peek(p)
	if (c == '['):
		asm_parse_mem(p, op, arch)
		op.size = size_hint
		return
	if (c == '.'):
		# dot-relative label ".+N" / ".-N"
		int start = p.pos
		p.pos = p.pos + 2
		while (asm_parse_is_ident(p.text[p.pos])):
			p.pos = p.pos + 1
		int n = p.pos - start
		char* label = malloc(n + 1)
		int i = 0
		while (i < n):
			label[i] = p.text[start + i]
			i = i + 1
		label[n] = 0
		op.kind = ASM_OP_LABEL()
		op.label = label
		return
	if (asm_parse_is_number_start(c)):
		char* tok = asm_parse_token(p)
		op.kind = ASM_OP_IMM()
		op.imm = asm_parse_number(tok)
		op.imm_hi = asm_parse_number_hi(tok)
		op.size = size_hint
		return
	# identifier: size keyword + operand, register, or bare label
	char* tok = asm_parse_token(p)
	int kw = asm_parse_size_keyword(tok)
	if (kw != 0):
		asm_parse_operand(p, op, arch, kw)
		return
	int reg = asm_reg_lookup_x86(tok)
	if (tok[0] == 'x' & tok[1] == 'm' & tok[2] == 'm'):
		op.kind = ASM_OP_REG()
		op.rclass = ASM_RCLASS_XMM()
		op.reg = asm_parse_number(tok + 3)
		op.size = 16
		return
	if (reg >= 0):
		op.kind = ASM_OP_REG()
		op.rclass = ASM_RCLASS_GP()
		op.reg = asm_reg_number(reg)
		op.size = asm_reg_size(reg)
		return
	# bare label
	op.kind = ASM_OP_LABEL()
	op.label = tok


# Parse a whole instruction line into insn. Returns 1 on success.
int asm_x86_parse(char* line, int arch, asm_insn* insn):
	asm_insn_clear(insn)
	insn.arch = arch
	asm_parse parse
	parse.text = line
	parse.pos = 0
	asm_parse* p = &parse

	insn.mnemonic = asm_parse_token(p)
	if (insn.mnemonic[0] == 0):
		return 1 == 2
	asm_parse_skip_spaces(p)
	if (asm_parse_peek(p) == 0):
		return 1
	asm_parse_operand(p, &insn.op1, arch, 0)
	asm_parse_skip_spaces(p)
	if (asm_parse_peek(p) == ','):
		p.pos = p.pos + 1
		asm_parse_operand(p, &insn.op2, arch, 0)
	asm_parse_skip_spaces(p)
	if (asm_parse_peek(p) == ','):
		p.pos = p.pos + 1
		asm_parse_operand(p, &insn.op3, arch, 0)
	return 1
