/*
AT&T-syntax text front end for the x86/x64 assembler library
(docs/projects/assembler_disassembler.md): parses one line of AT&T
assembly into an asm_insn, which libs/asm/x86_encode.w then encodes.

The GNU assembler syntax a C compiler and an operating-system kernel
write their inline asm in is AT&T: operands are source-first
(destination last), registers carry a `%`, immediates a `$`, memory is
`disp(%base,%index,scale)`, and the operation size is a mnemonic suffix
(`b`/`w`/`l`/`q`) rather than an operand keyword. This file normalizes
all of that into the architecture-neutral asm_insn (destination in
op1), so the single encoder serves both the in-house Intel text parser
(libs/asm/text.w) and AT&T callers.

Scope: the integer instructions a freestanding kernel's inline asm
uses -- data movement, ALU, bit tests and scans, atomics with the
`lock` prefix, the flag/segment/serializing instructions and branches.
Operands are registers, immediates, memory with a numeric displacement,
and branch labels; a symbolic operand (relocated against another
object's symbol) is the caller's concern, not the encoder's.

Compiled by the seed gate: only seed-understood syntax here.
*/
import lib.lib
import libs.asm.insn
import libs.asm.registers
import libs.asm.hexutil
import libs.asm.text


int asm_att_name_eq(char* list, int start, int n, char* base);
char* asm_att_slice(char* raw, int end);
int asm_att_two_suffix(char* raw, int rl, int* srcsz, int* dstsz, char** mnem_out);


# A cursor over the AT&T line, reusing text.w's number helpers through
# the shared asm_parse struct.
int asm_att_peek(asm_parse* p):
	return p.text[p.pos] & 255


void asm_att_skip_spaces(asm_parse* p):
	while (p.text[p.pos] == ' ' || p.text[p.pos] == 9): p.pos = p.pos + 1


int asm_att_ident_char(int c):
	if (c >= 'a' && c <= 'z'): return 1
	if (c >= 'A' && c <= 'Z'): return 1
	if (c >= '0' && c <= '9'): return 1
	if (c == '_' || c == '.'): return 1
	return 1 == 2


# A maximal mnemonic/label identifier (letters, digits, '_', '.').
char* asm_att_ident(asm_parse* p):
	asm_att_skip_spaces(p)
	int start = p.pos
	while (asm_att_ident_char(p.text[p.pos])): p.pos = p.pos + 1
	int n = p.pos - start
	char* out = cast(char*, malloc(n + 1))
	for i in range(n): out[i] = p.text[start + i]
	out[n] = 0
	return out


# A size suffix letter -> byte width, or 0.
int asm_att_suffix_size(int c):
	if (c == 'b'): return 1
	if (c == 'w'): return 2
	if (c == 'l'): return 4
	if (c == 'q'): return 8
	return 0


# raw[0..end) as a fresh string.
char* asm_att_slice(char* raw, int end):
	char* out = cast(char*, malloc(end + 1))
	for i in range(end): out[i] = raw[i]
	out[end] = 0
	return out


int asm_att_name_eq(char* names, int start, int n, char* base):
	for i in range(n):
		if (base[i] != names[start + i]): return 1 == 2
	return base[n] == 0


# The base mnemonics that take an AT&T size suffix (data movement, ALU,
# bit, shift, atomics, string). A mnemonic whose base is one of these,
# with a trailing b/w/l/q, is split into base + size; anything else
# (jcc, setcc, call, the fixed no-suffix instructions) is kept whole, so
# `jl`/`setle`/`call` are never mis-split.
int asm_att_suffixable(char* base):
	char* names = c"mov add or adc sbb and sub xor cmp test inc dec not neg mul imul div idiv shl shr sar sal rol ror rcl rcr bt bts btr btc bsf bsr xchg xadd cmpxchg popcnt lzcnt tzcnt push pop lea stos movs lods scas in out"
	int li = 0
	while (names[li] != 0):
		int s = li
		while ((names[li] != ' ') && (names[li] != 0)): li = li + 1
		int n = li - s
		if (asm_att_name_eq(names, s, n, base)): return 1
		if (names[li] == ' '): li = li + 1
	return 1 == 2


# A register operand (`%name`): fill op from the register name, which
# already carries its width. An unknown name leaves a -1 sentinel the
# operand check (asm_body_bad_operand) reports.
void asm_att_reg(asm_operand* op, char* name):
	int enc = asm_reg_lookup_x86(name)
	op.kind = ASM_OP_REG
	op.rclass = ASM_RCLASS_GP
	if (enc < 0):
		op.reg = 0 - 1
		op.size = 0
		return
	op.reg = asm_reg_number(enc)
	op.size = asm_reg_size(enc)


# 1 when tok is a numeric local label reference (`1b`, `12f`): digits
# then a single b/f.
int asm_att_numeric_label(char* tok):
	int n = strlen(tok)
	if (n < 2): return 1 == 2
	if (tok[n - 1] != 'b' && tok[n - 1] != 'f'): return 1 == 2
	for i in range(n - 1):
		if (tok[i] < '0' || tok[i] > '9'): return 1 == 2
	return 1


# 1 when the cursor starts a symbol (a name, or a numeric local label).
int asm_att_symbol_start(asm_parse* p):
	int c = asm_att_peek(p)
	if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')): return 1
	if (c == '_' || c == '.'): return 1
	if (c < '0' || c > '9'): return 1 == 2
	int save = p.pos
	char* tok = asm_att_ident(p)
	p.pos = save
	return asm_att_numeric_label(tok)


# A symbol with an optional `+N`/`-N` addend: the name into op.label, the
# addend returned. A `@PLT`/`@GOTPCREL`-style suffix is skipped (the
# caller chooses the relocation).
int asm_att_symbol(asm_parse* p, asm_operand* op):
	op.label = asm_att_ident(p)
	if (asm_att_peek(p) == '@'):
		p.pos = p.pos + 1
		asm_att_ident(p)
	asm_att_skip_spaces(p)
	int c = asm_att_peek(p)
	if (c != '+' && c != '-'): return 0
	p.pos = p.pos + 1
	asm_att_skip_spaces(p)
	int v = asm_parse_number(asm_att_ident(p))
	if (c == '-'): return 0 - v
	return v


# A signed number (asm_att_ident stops at '-', so the sign is read by
# hand).
int asm_att_signed_number(asm_parse* p):
	asm_att_skip_spaces(p)
	int neg = 0
	if (asm_att_peek(p) == '-'):
		neg = 1
		p.pos = p.pos + 1
	int v = asm_parse_number(asm_att_ident(p))
	if (neg): return 0 - v
	return v


# A constant displacement expression: numbers joined by `*`, `+` and `-`
# (`0*8`, `2*8+4`, as checksum templates write them), `*` binding first.
int asm_att_const_expr(asm_parse* p):
	int total = 0
	int term = asm_att_signed_number(p)
	while (1 == 1):
		asm_att_skip_spaces(p)
		int c = asm_att_peek(p)
		if (c == '*'):
			p.pos = p.pos + 1
			term = term * asm_att_signed_number(p)
		else if ((c == '+') || (c == '-')):
			p.pos = p.pos + 1
			total = total + term
			term = asm_att_signed_number(p)
			if (c == '-'): term = 0 - term
		else: return total + term
	return total + term


# A memory operand `disp(%base,%index,scale)` / `disp(%base)` /
# `(%base)` / `disp`. The cursor is at the displacement or '('.
void asm_att_mem(asm_parse* p, asm_operand* op):
	op.kind = ASM_OP_MEM
	op.base = -1
	op.index = -1
	op.scale = 1
	op.disp = 0
	op.disp_size = 0
	op.size = 0
	asm_att_skip_spaces(p)
	if (asm_att_symbol_start(p)):
		# A symbolic displacement (`sym(%rip)`, `1f+8(%rip)`, `sym`): the
		# reference stays in op.label, always a disp32 field.
		op.disp = asm_att_symbol(p, op)
		op.disp_size = 4
	else if (asm_att_peek(p) == '-' || (asm_att_peek(p) >= '0' && asm_att_peek(p) <= '9')):
		op.disp = asm_att_const_expr(p)
	asm_att_skip_spaces(p)
	if (asm_att_peek(p) != '('): return
	p.pos = p.pos + 1
	asm_att_skip_spaces(p)
	if (asm_att_peek(p) == '%'):
		p.pos = p.pos + 1
		char* bname = asm_att_ident(p)
		if (strcmp(bname, c"rip") == 0): op.base = ASM_BASE_RIP
		else: op.base = asm_reg_number(asm_reg_lookup_x86(bname))
	asm_att_skip_spaces(p)
	if (asm_att_peek(p) == ','):
		p.pos = p.pos + 1
		asm_att_skip_spaces(p)
		if (asm_att_peek(p) == '%'):
			p.pos = p.pos + 1
			char* iname = asm_att_ident(p)
			op.index = asm_reg_number(asm_reg_lookup_x86(iname))
		asm_att_skip_spaces(p)
		if (asm_att_peek(p) == ','):
			p.pos = p.pos + 1
			char* stok = asm_att_ident(p)
			op.scale = asm_parse_number(stok)
	asm_att_skip_spaces(p)
	if (asm_att_peek(p) == ')'): p.pos = p.pos + 1


# The segment-override prefix byte the last operand named (0 = none),
# moved to asm_insn.segment by asm_att_parse.
int asm_att_seg


# The prefix byte of a segment register name: %es 0x26, %cs 0x2e,
# %ss 0x36, %ds 0x3e, %fs 0x64, %gs 0x65; 0 for any other name.
int asm_att_segment_prefix(char* name):
	if (strcmp(name, c"fs") == 0): return 0x64
	if (strcmp(name, c"gs") == 0): return 0x65
	if (strcmp(name, c"es") == 0): return 0x26
	if (strcmp(name, c"cs") == 0): return 0x2e
	if (strcmp(name, c"ss") == 0): return 0x36
	if (strcmp(name, c"ds") == 0): return 0x3e
	return 0


# One operand into op. mnem_size is the mnemonic's suffix width (0 when
# none), applied to a memory or immediate operand that has none of its
# own. Returns 1 on success.
int asm_att_operand(asm_parse* p, asm_operand* op, int mnem_size):
	asm_operand_clear(op)
	asm_att_skip_spaces(p)
	int c = asm_att_peek(p)
	if (c == '*'):
		p.pos = p.pos + 1
		asm_att_skip_spaces(p)
		c = asm_att_peek(p)
	if (c == '%'):
		p.pos = p.pos + 1
		char* name = asm_att_ident(p)
		asm_att_skip_spaces(p)
		if (asm_att_peek(p) == ':'):
			# A segment override `%gs:`/`%fs:` before a memory operand:
			# the prefix byte is carried to the instruction by the caller
			# (asm_att_seg), the memory operand is parsed as usual.
			p.pos = p.pos + 1
			asm_att_seg = asm_att_segment_prefix(name)
			asm_att_mem(p, op)
			if (op.size == 0): op.size = mnem_size
			return 1
		asm_att_reg(op, name)
		return 1
	if (c == '$'):
		p.pos = p.pos + 1
		op.kind = ASM_OP_IMM
		if (asm_att_symbol_start(p)):
			# A symbolic immediate (`$sym`, `$1f`): the reference in
			# op.label, the addend in op.imm.
			op.imm = asm_att_symbol(p, op)
			return 1
		# asm_att_ident stops at a sign: a negative immediate keeps it.
		char* sign = c""
		if (asm_att_peek(p) == '-'):
			sign = c"-"
			p.pos = p.pos + 1
		char* tok = strjoin(sign, asm_att_ident(p))
		op.imm = asm_parse_number(tok)
		op.imm_hi = asm_parse_number_hi(tok)
		# An immediate keeps size 0: the operand width comes from the
		# register/memory destination (which carries the mnemonic suffix),
		# and the encoder then picks the minimal imm8 form where it fits,
		# matching the GNU assembler's output.
		op.size = 0
		return 1
	if (asm_att_symbol_start(p)):
		int save = p.pos
		op.kind = ASM_OP_LABEL
		int addend = asm_att_symbol(p, op)
		asm_att_skip_spaces(p)
		if (strcmp(op.label, c".") == 0):
			# A dot-relative branch target `.+N` / `.-N`, as the encoder
			# takes it.
			if (addend < 0): op.label = strjoin(c".-", itoa(0 - addend))
			else: op.label = strjoin(c".+", itoa(addend))
			return 1
		if (addend == 0 && asm_att_peek(p) != '('): return 1
		# `sym(%rip)`, `sym+8`: a symbolic memory operand.
		p.pos = save
		asm_att_mem(p, op)
		if (op.size == 0): op.size = mnem_size
		return 1
	if (c == '-' || (c >= '0' && c <= '9') || c == '('):
		asm_att_mem(p, op)
		if (op.size == 0): op.size = mnem_size
		return 1
	return 1 == 2


# movzbl/movzwl/movsbl/movslq style double suffixes on movz/movs: map to
# movzx/movsx/movsxd, returning the widths through srcsz/dstsz and the
# normalized mnemonic through mnem_out. Returns 1 on a match.
int asm_att_two_suffix(char* raw, int rl, int* srcsz, int* dstsz, char** mnem_out):
	if (rl != 6): return 1 == 2
	if (raw[0] != 'm' || (raw[1] != 'o' || raw[2] != 'v')): return 1 == 2
	int zx = raw[3] == 'z'
	int sx = raw[3] == 's'
	if (zx == 0 && sx == 0): return 1 == 2
	int s = asm_att_suffix_size(raw[4])
	int d = asm_att_suffix_size(raw[5])
	if (s == 0 || d == 0): return 1 == 2
	*srcsz = s
	*dstsz = d
	if (sx && (s == 4) && (d == 8)): *mnem_out = c"movsxd"
	else if (zx): *mnem_out = c"movzx"
	else: *mnem_out = c"movsx"
	return 1


# Give an immediate (or a memory operand with no suffix) the size of a
# register sibling, so the ALU imm8/imm32 and r/m width choices are right.
void asm_att_size_from_reg(asm_insn* insn):
	int rsize = 0
	if (insn.op1.kind == ASM_OP_REG && insn.op1.size != 0): rsize = insn.op1.size
	else if (insn.op2.kind == ASM_OP_REG && insn.op2.size != 0): rsize = insn.op2.size
	if (rsize == 0): return
	if (insn.op1.kind == ASM_OP_MEM && insn.op1.size == 0): insn.op1.size = rsize
	if (insn.op2.kind == ASM_OP_MEM && insn.op2.size == 0): insn.op2.size = rsize


# Parse one AT&T line into insn (arch ASM_ARCH_X86/X64). Returns 1 on a
# recognized line, 0 when the mnemonic is empty.
int asm_att_parse(char* line, int arch, asm_insn* insn):
	asm_insn_clear(insn)
	insn.arch = arch
	asm_parse parse
	parse.text = line
	parse.pos = 0
	asm_parse* p = &parse

	char* prefix = c""
	while (1 == 1):
		int save = p.pos
		char* word = asm_att_ident(p)
		if (strcmp(word, c"lock") == 0): prefix = c"lock "
		else if (strcmp(word, c"rep") == 0 || (strcmp(word, c"repz") == 0 || strcmp(word, c"repe") == 0)): prefix = c"rep "
		else if (strcmp(word, c"repnz") == 0 || strcmp(word, c"repne") == 0): prefix = c"repnz "
		else:
			p.pos = save
			break
		asm_att_skip_spaces(p)

	char* raw = asm_att_ident(p)
	if (raw[0] == 0): return 1 == 2

	int mnem_size = 0
	int two_src = 0
	int two_dst = 0
	int is_two = 0
	char* mnem = raw
	int rl = strlen(raw)
	char* two_mnem = c""
	if (asm_att_two_suffix(raw, rl, &two_src, &two_dst, &two_mnem)):
		mnem = two_mnem
		is_two = 1
	else if (rl >= 2):
		int sz = asm_att_suffix_size(raw[rl - 1])
		if (sz != 0):
			char* base = asm_att_slice(raw, rl - 1)
			if (asm_att_suffixable(base)):
				mnem = base
				mnem_size = sz
	# `rep nop` is how GNU C spells pause (cpu_relax()): f3 90; and
	# `rep bsf`/`rep bsr` (the kernel's __ffs) are the bytes of tzcnt /
	# lzcnt, which a CPU without them runs as bsf / bsr.
	if (strcmp(prefix, c"rep ") == 0):
		char* plain = mnem
		if (strcmp(mnem, c"nop") == 0): mnem = c"pause"
		else if (strcmp(mnem, c"bsf") == 0): mnem = c"tzcnt"
		else if (strcmp(mnem, c"bsr") == 0): mnem = c"lzcnt"
		if (mnem != plain): prefix = c""
	if (prefix[0] != 0): mnem = strjoin(prefix, mnem)
	insn.mnemonic = mnem

	# Up to three operands, parsed in AT&T source order into a/b/c, then
	# placed destination-first (op1 = last operand) for the encoder.
	asm_operand a
	asm_operand b
	asm_operand cc
	int count = 0
	asm_att_seg = 0
	asm_att_skip_spaces(p)
	if (asm_att_peek(p) != 0):
		if (asm_att_operand(p, &a, mnem_size)): count = 1
		asm_att_skip_spaces(p)
		if (count == 1 && asm_att_peek(p) == ','):
			p.pos = p.pos + 1
			if (asm_att_operand(p, &b, mnem_size)): count = 2
			asm_att_skip_spaces(p)
			if (count == 2 && asm_att_peek(p) == ','):
				p.pos = p.pos + 1
				if (asm_att_operand(p, &cc, mnem_size)): count = 3
	if (count == 1): insn.op1 = a
	else if (count == 2):
		insn.op1 = b
		insn.op2 = a
	else if (count == 3):
		insn.op1 = cc
		insn.op2 = b
		insn.op3 = a

	insn.segment = asm_att_seg
	if (is_two):
		insn.op1.size = two_dst
		if (insn.op2.kind == ASM_OP_MEM): insn.op2.size = two_src
	else if (mnem_size == 0): asm_att_size_from_reg(insn)
	return 1
