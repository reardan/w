/*
The template assembler of the native inline asm statement
(grammar/inline_asm_stmt.w, docs/projects/native_inline_asm.md): turns
the AT&T template lines of one asm_native block into machine code inline
in the surrounding function, with what a GNU inline asm template needs
beyond straight-line instructions:

- local labels: numeric (`1:` referenced as `1b` / `1f`, redefinable)
  and named (`retry:`, `.Lout:`, unique inside the statement); a branch
  to a label is always the rel32 form, patched when the template ends;
- directives: `.pushsection NAME[,"flags"[,@progbits]]`, `.section`,
  `.popsection`, `.previous`, the data directives `.byte` `.word`
  `.short` `.long` `.int` `.quad` (and the `.2byte`/`.4byte`/`.8byte`
  spellings) over expressions of the form `A`, `A + N`, `A - .` and
  `A - B`, and `.balign` / `.align` / `.p2align`;
- symbol operands: `call sym`, `jmp sym`, `sym(%rip)`, `$sym`, `sym`.

Instructions and data in a pushed section collect in the object writer's
asm sections (code_generator/elf_object.w). A reference that stays
inside one section is resolved here; one that crosses sections, or names
a symbol outside the statement, becomes an ELF relocation
(R_X86_64_PC32, PLT32, 64, 32, 32S, PC64), so sections and symbol
references need --emit=obj. Local labels work in every output mode.

Compiled by the pinned seed (w.w's import graph): seed syntax only.
*/
import libs.asm.att
import libs.asm.insn
import libs.asm.text
import libs.asm.x86_encode
import code_generator.elf_object


void emit(int n, char* s);
void error(char* s);


# The current section: INASM_TEXT (inline in the function) or an asm
# section index (object_asm_section).
const int INASM_TEXT = -1

# Fixup kinds: an absolute value (S + A), a PC-relative one (S + A - P),
# a branch (PC-relative; PLT32 when it names a symbol) and a label
# difference (S - M + A).
const int INASM_FIX_ABS = 0
const int INASM_FIX_PC = 1
const int INASM_FIX_BRANCH = 2
const int INASM_FIX_DIFF = 3

# A displacement/immediate value no real operand uses, encoded in place
# of a symbolic one so its field can be found in the encoded bytes.
const int INASM_SENTINEL = 0x5a5a5a5a


list[char*] inasm_label_name
list[int] inasm_label_section
list[int] inasm_label_offset
list[int] inasm_label_seq
int inasm_label_defs

list[int] inasm_fix_kind
list[int] inasm_fix_section
list[int] inasm_fix_offset
list[int] inasm_fix_width
list[int] inasm_fix_signed
list[char*] inasm_fix_plus
list[char*] inasm_fix_minus
list[int] inasm_fix_seq
list[int] inasm_fix_addend

int inasm_section
int inasm_previous
list[int] inasm_section_stack
char* inasm_prefix


void inasm_template_reset():
	inasm_label_name = new list[char*]
	inasm_label_section = new list[int]
	inasm_label_offset = new list[int]
	inasm_label_seq = new list[int]
	inasm_label_defs = 0
	inasm_fix_kind = new list[int]
	inasm_fix_section = new list[int]
	inasm_fix_offset = new list[int]
	inasm_fix_width = new list[int]
	inasm_fix_signed = new list[int]
	inasm_fix_plus = new list[char*]
	inasm_fix_minus = new list[char*]
	inasm_fix_seq = new list[int]
	inasm_fix_addend = new list[int]
	inasm_section = INASM_TEXT
	inasm_previous = INASM_TEXT
	inasm_section_stack = new list[int]
	inasm_prefix = c""


void inasm_fail(char* what, char* text):
	error(strjoin(strjoin(c"native inline asm: ", what), strjoin(c": ", text)))


void inasm_need_object(char* text):
	if (elf_object == 0): inasm_fail(c"sections and symbol references need --emit=obj", text)


# The current offset in the current section.
int inasm_here():
	if (inasm_section == INASM_TEXT): return codepos
	return object_asm_size(inasm_section)


void inasm_put(char* bytes, int n):
	if (inasm_section == INASM_TEXT): emit(n, bytes)
	else: object_asm_put(inasm_section, bytes, n)


# Write a width-byte little-endian value at an offset of a section.
void inasm_patch(int section, int offset, int width, int value):
	char* at = code + offset
	if (section != INASM_TEXT): at = object_asm_data(section) + offset
	int v = value
	for i in range(width):
		if (i < 4):
			at[i] = v & 255
			v = v >> 8
		else if (value < 0): at[i] = 255
		else: at[i] = 0


int inasm_fits(int value, int width, int is_signed):
	if (width == 1):
		if (is_signed): return (value >= -128) && (value <= 127)
		return (value >= -128) && (value <= 255)
	if (width == 2):
		if (is_signed): return (value >= -32768) && (value <= 32767)
		return (value >= -32768) && (value <= 65535)
	return 1


################################## labels ####################################

int inasm_is_numeric(char* name):
	if (name[0] == 0): return 0
	int i = 0
	while (name[i] != 0):
		if ((name[i] < '0') || (name[i] > '9')): return 0
		i = i + 1
	return 1


void inasm_define_label(char* name):
	if (inasm_is_numeric(name) == 0):
		for i in range(inasm_label_name.length):
			if (strcmp(inasm_label_name[i], name) == 0): inasm_fail(c"label defined twice", name)
	inasm_label_name.push(name)
	inasm_label_section.push(inasm_section)
	inasm_label_offset.push(inasm_here())
	inasm_label_seq.push(inasm_label_defs)
	inasm_label_defs = inasm_label_defs + 1


# The label a reference made after seq definitions names, or -1: `Nb`
# is the latest definition of N before the reference, `Nf` the first one
# after it, any other name the statement's label of that name.
int inasm_find_label(char* name, int seq):
	if (asm_att_numeric_label(name)):
		int n = strlen(name)
		char* base = asm_att_slice(name, n - 1)
		int backward = name[n - 1] == 'b'
		int found = -1
		for i in range(inasm_label_name.length):
			if (strcmp(inasm_label_name[i], base) == 0):
				if (backward && (inasm_label_seq[i] < seq)): found = i
				if ((backward == 0) && (inasm_label_seq[i] >= seq) && (found < 0)): found = i
		if (found < 0): inasm_fail(c"undefined local label", name)
		return found
	for i in range(inasm_label_name.length):
		if (strcmp(inasm_label_name[i], name) == 0): return i
	return -1


void inasm_add_fixup(int kind, int section, int offset, int width, int is_signed, char* plus, char* minus, int addend):
	inasm_fix_kind.push(kind)
	inasm_fix_section.push(section)
	inasm_fix_offset.push(offset)
	inasm_fix_width.push(width)
	inasm_fix_signed.push(is_signed)
	inasm_fix_plus.push(plus)
	inasm_fix_minus.push(minus)
	inasm_fix_seq.push(inasm_label_defs)
	inasm_fix_addend.push(addend)


# A PC-relative value from (section, offset) to a label, or to a symbol
# when label < 0: patched when both ends share a section, otherwise a
# relocation.
void inasm_resolve_pc(int i, int label, int addend):
	int section = inasm_fix_section[i]
	int offset = inasm_fix_offset[i]
	int width = inasm_fix_width[i]
	if ((label >= 0) && (inasm_label_section[label] == section)):
		int value = inasm_label_offset[label] + addend - offset
		if (inasm_fits(value, width, 1) == 0): inasm_fail(c"label out of range", inasm_fix_plus[i])
		inasm_patch(section, offset, width, value)
		return
	inasm_need_object(inasm_fix_plus[i])
	int rtype = 2
	if (width == 8): rtype = 24
	else if (width != 4): inasm_fail(c"a relocated PC-relative value must be 4 or 8 bytes", inasm_fix_plus[i])
	if ((label < 0) && (inasm_fix_kind[i] == INASM_FIX_BRANCH)): rtype = 4
	if (label < 0): object_asm_reloc(section, offset, rtype, OBJECT_ASM_SYMBOL, 0, inasm_fix_plus[i], addend)
	else: object_asm_reloc(section, offset, rtype, inasm_label_section[label], inasm_label_offset[label], 0, addend)
	inasm_patch(section, offset, width, 0)


void inasm_resolve(int i):
	int kind = inasm_fix_kind[i]
	int section = inasm_fix_section[i]
	int offset = inasm_fix_offset[i]
	int width = inasm_fix_width[i]
	int addend = inasm_fix_addend[i]
	int label = inasm_find_label(inasm_fix_plus[i], inasm_fix_seq[i])
	if (kind == INASM_FIX_DIFF):
		int minus = inasm_find_label(inasm_fix_minus[i], inasm_fix_seq[i])
		if (minus < 0): inasm_fail(c"label difference needs a local label", inasm_fix_minus[i])
		if ((label >= 0) && (inasm_label_section[label] == inasm_label_section[minus])):
			int value = inasm_label_offset[label] - inasm_label_offset[minus] + addend
			if (inasm_fits(value, width, 0) == 0): inasm_fail(c"label difference out of range", inasm_fix_plus[i])
			inasm_patch(section, offset, width, value)
			return
		if (inasm_label_section[minus] != section): inasm_fail(c"label difference across sections", inasm_fix_plus[i])
		# S - M + A == S + (A + P - M) - P: PC-relative from the site.
		inasm_resolve_pc(i, label, addend + offset - inasm_label_offset[minus])
		return
	if (kind != INASM_FIX_ABS):
		inasm_resolve_pc(i, label, addend)
		return
	inasm_need_object(inasm_fix_plus[i])
	int rtype = 10
	if (width == 8): rtype = 1
	else if (width != 4): inasm_fail(c"an absolute symbol value must be 4 or 8 bytes", inasm_fix_plus[i])
	else if (inasm_fix_signed[i]): rtype = 11
	if (label < 0): object_asm_reloc(section, offset, rtype, OBJECT_ASM_SYMBOL, 0, inasm_fix_plus[i], addend)
	else: object_asm_reloc(section, offset, rtype, inasm_label_section[label], inasm_label_offset[label], 0, addend)
	inasm_patch(section, offset, width, 0)


################################ instructions ################################

int inasm_is_branch(char* m):
	if ((strcmp(m, c"call") == 0) || (strcmp(m, c"jmp") == 0)): return 1
	return (m[0] == 'j') && (asm_enc_cc_alias(m + 1) >= 0)


# 1 for an encoder-ready dot-relative target (`.+N` / `.-N`).
int inasm_dot_label(char* label):
	return (label[0] == '.') && ((label[1] == '+') || (label[1] == '-'))


# 1 for a data-expression token naming a label or symbol.
int inasm_symbol_token(char* tok):
	int c = tok[0]
	if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')): return 1
	if ((c == '_') || (c == '.')): return 1
	return asm_att_numeric_label(tok)


# The operand of insn that carries a symbol or label reference other
# than a branch target, or 0.
asm_operand* inasm_symbolic(asm_insn* insn, char* line):
	asm_operand* found = cast(asm_operand*, 0)
	for k in range(3):
		asm_operand* op = &insn.op1
		if (k == 1): op = &insn.op2
		if (k == 2): op = &insn.op3
		if ((op.kind == ASM_OP_LABEL) && (inasm_dot_label(op.label) == 0)):
			# A bare symbol as a data operand (`movl sym, %eax`): absolute
			# memory.
			op.kind = ASM_OP_MEM
			op.base = -1
			op.index = -1
			op.scale = 1
			op.disp = 0
			op.disp_size = 4
		if (((op.kind == ASM_OP_MEM) || (op.kind == ASM_OP_IMM)) && (cast(int, op.label) != 0)):
			if (cast(int, found) != 0): inasm_fail(c"more than one symbol operand", line)
			found = op
	return found


void inasm_encode_put(asm_insn* insn, char* line, asm_buffer* b):
	int n = asm_x86_encode(b, insn)
	if (n <= 0): inasm_fail(c"cannot assemble", line)


void inasm_instruction(char* line):
	asm_insn insn
	if (asm_att_parse(line, ASM_ARCH_X64, &insn) == 0): inasm_fail(c"cannot assemble", line)
	asm_buffer* b = asm_buffer_new()
	char* m = insn.mnemonic
	int start = inasm_here()
	if ((insn.op1.kind == ASM_OP_LABEL) && inasm_is_branch(m) && (inasm_dot_label(insn.op1.label) == 0)):
		# Always the rel32 form: a placeholder target past rel8 range,
		# the displacement (the last four bytes) patched at the end.
		char* target = insn.op1.label
		insn.op1.label = c".+1000"
		inasm_encode_put(&insn, line, b)
		inasm_put(b.data, b.length)
		inasm_add_fixup(INASM_FIX_BRANCH, inasm_section, start + b.length - 4, 4, 1, target, 0, -4)
		asm_buffer_free(b)
		return
	asm_operand* op = inasm_symbolic(&insn, line)
	if (cast(int, op) == 0):
		inasm_encode_put(&insn, line, b)
		inasm_put(b.data, b.length)
		asm_buffer_free(b)
		return
	char* name = op.label
	int addend = 0
	if (op.kind == ASM_OP_MEM):
		addend = op.disp
		op.disp = INASM_SENTINEL
	else:
		addend = op.imm
		op.imm = INASM_SENTINEL
		op.imm_hi = 0
	inasm_encode_put(&insn, line, b)
	int field = -1
	for k in range(b.length - 3):
		if (load_int32(b.data + k) == INASM_SENTINEL):
			if (field >= 0): inasm_fail(c"cannot place the symbol operand", line)
			field = k
	if (field < 0): inasm_fail(c"symbol operand needs a 32-bit field", line)
	save_int32(b.data + field, 0)
	inasm_put(b.data, b.length)
	if ((op.kind == ASM_OP_MEM) && (op.base == ASM_BASE_RIP)):
		# disp32 = S + addend - (end of instruction), P being the field.
		inasm_add_fixup(INASM_FIX_PC, inasm_section, start + field, 4, 1, name, 0, addend + field - b.length)
	else:
		int is_signed = 1
		if ((op.kind == ASM_OP_IMM) && (insn.op1.size != 8)): is_signed = 0
		inasm_add_fixup(INASM_FIX_ABS, inasm_section, start + field, 4, is_signed, name, 0, addend)
	asm_buffer_free(b)


################################ directives ##################################

int inasm_space(int c):
	return (c == ' ') || (c == 9)


int inasm_skip(char* s, int i):
	while (inasm_space(s[i])): i = i + 1
	return i


# The span s[i..] up to the first stop character, trimmed.
char* inasm_until(char* s, int i, int stop):
	int start = inasm_skip(s, i)
	int end = start
	while ((s[end] != 0) && (s[end] != stop)): end = end + 1
	while ((end > start) && inasm_space(s[end - 1])): end = end - 1
	return asm_att_slice(s + start, end - start)


# The position after the first stop character at or past i (or the end).
int inasm_after(char* s, int i, int stop):
	while ((s[i] != 0) && (s[i] != stop)): i = i + 1
	if (s[i] == stop): i = i + 1
	return i


int inasm_section_flags(char* flags, char* name):
	if (flags == 0):
		if (object_has_prefix(name, c".text")): return 6
		if (object_has_prefix(name, c".data") || object_has_prefix(name, c".bss")): return 3
		if (object_has_prefix(name, c".rodata")): return 2
		return 0
	int f = 0
	int i = 0
	while (flags[i] != 0):
		int c = flags[i]
		if (c == 'a'): f = f | 2
		else if (c == 'w'): f = f | 1
		else if (c == 'x'): f = f | 4
		else if (c == 'M'): f = f | 16
		else if (c == 'S'): f = f | 32
		else if (c != '"'): inasm_fail(c"unsupported section flag", flags)
		i = i + 1
	return f


# `.pushsection`/`.section` operands: NAME[,"flags"[,@type]].
int inasm_section_operand(char* text, int i):
	inasm_need_object(text)
	char* name = inasm_until(text, i, ',')
	if (name[0] == 0): inasm_fail(c"section directive needs a name", text)
	int at = inasm_after(text, i, ',')
	char* flags = 0
	if (text[at - 1] == ','):
		flags = inasm_until(text, at, ',')
		at = inasm_after(text, at, ',')
		if (text[at - 1] == ','):
			char* type = inasm_until(text, at, ',')
			if ((strcmp(type, c"@progbits") != 0) && (strcmp(type, c"%progbits") != 0)): inasm_fail(c"unsupported section type", text)
	return object_asm_section(name, inasm_section_flags(flags, name))


void inasm_switch(int section):
	inasm_previous = inasm_section
	inasm_section = section


# One data directive operand at the current position: a number, or a
# reference (`A`, `A + N`, `A - .`, `A - B`) left as a fixup.
void inasm_data_value(char* expr, int width, char* line):
	asm_parse parse
	parse.text = expr
	parse.pos = 0
	asm_parse* p = &parse
	int total = 0
	char* plus = 0
	char* minus = 0
	int sign = 1
	while (1 == 1):
		asm_att_skip_spaces(p)
		int c = asm_att_peek(p)
		if (c == 0): break
		if (c == '+'):
			p.pos = p.pos + 1
		else if (c == '-'):
			sign = 0 - sign
			p.pos = p.pos + 1
		else:
			char* tok = asm_att_ident(p)
			if (tok[0] == 0): inasm_fail(c"bad data expression", line)
			if (inasm_symbol_token(tok)):
				if (sign > 0):
					if (plus != 0): inasm_fail(c"too many symbols in data expression", line)
					plus = tok
				else:
					if (minus != 0): inasm_fail(c"too many symbols in data expression", line)
					minus = tok
			else: total = total + sign * asm_parse_number(tok)
			sign = 1
	int here = inasm_here()
	char* zero = c"\x00\x00\x00\x00\x00\x00\x00\x00"
	inasm_put(zero, width)
	if (plus == 0):
		if (minus != 0): inasm_fail(c"unsupported data expression", line)
		if (inasm_fits(total, width, 0) == 0): inasm_fail(c"value out of range", line)
		inasm_patch(inasm_section, here, width, total)
		return
	if (minus == 0): inasm_add_fixup(INASM_FIX_ABS, inasm_section, here, width, 0, plus, 0, total)
	else if (strcmp(minus, c".") == 0): inasm_add_fixup(INASM_FIX_PC, inasm_section, here, width, 1, plus, 0, total)
	else: inasm_add_fixup(INASM_FIX_DIFF, inasm_section, here, width, 1, plus, minus, total)


void inasm_data(char* text, int i, int width):
	while (text[i] != 0):
		char* expr = inasm_until(text, i, ',')
		if (expr[0] == 0): inasm_fail(c"empty data value", text)
		inasm_data_value(expr, width, text)
		i = inasm_after(text, i, ',')


void inasm_align(char* text, int i, int power):
	char* amount = inasm_until(text, i, ',')
	int a = asm_parse_number(amount)
	if (power): a = 1 << a
	if ((a <= 0) || ((a & (a - 1)) != 0)): inasm_fail(c"alignment must be a power of two", text)
	int fill = -1
	int at = inasm_after(text, i, ',')
	if (text[at - 1] == ','): fill = asm_parse_number(inasm_until(text, at, ',')) & 255
	if (inasm_section == INASM_TEXT):
		# The object writer keeps a code piece's offset modulo 16.
		if (a > 16): inasm_fail(c"code alignment above 16 bytes", text)
		if (fill < 0): fill = 0x90
		char* one = c"\x00"
		one[0] = fill
		while ((codepos % a) != 0): emit(1, one)
		return
	if (fill < 0): fill = 0
	object_asm_align(inasm_section, a, fill)


int inasm_data_width(char* d):
	if ((strcmp(d, c".byte") == 0)): return 1
	if ((strcmp(d, c".word") == 0) || (strcmp(d, c".short") == 0) || (strcmp(d, c".2byte") == 0) || (strcmp(d, c".value") == 0)): return 2
	if ((strcmp(d, c".long") == 0) || (strcmp(d, c".int") == 0) || (strcmp(d, c".4byte") == 0)): return 4
	if ((strcmp(d, c".quad") == 0) || (strcmp(d, c".8byte") == 0)): return 8
	return 0


void inasm_directive(char* text, int i):
	int start = i
	while (asm_att_ident_char(text[i])): i = i + 1
	char* d = asm_att_slice(text + start, i - start)
	int width = inasm_data_width(d)
	if (width > 0): inasm_data(text, i, width)
	else if (strcmp(d, c".pushsection") == 0):
		int section = inasm_section_operand(text, i)
		inasm_section_stack.push(inasm_section)
		inasm_switch(section)
	else if (strcmp(d, c".popsection") == 0):
		if (inasm_section_stack.length == 0): inasm_fail(c".popsection without .pushsection", text)
		inasm_switch(inasm_section_stack.pop())
	else if (strcmp(d, c".section") == 0): inasm_switch(inasm_section_operand(text, i))
	else if (strcmp(d, c".previous") == 0): inasm_switch(inasm_previous)
	else if ((strcmp(d, c".balign") == 0) || (strcmp(d, c".align") == 0)): inasm_align(text, i, 0)
	else if (strcmp(d, c".p2align") == 0): inasm_align(text, i, 1)
	else: inasm_fail(c"unsupported directive", text)


################################## lines #####################################

int inasm_is_prefix(char* word):
	char* names = c" lock rep repz repe repnz repne "
	char* key = strjoin(strjoin(c" ", word), c" ")
	return object_contains(names, key)


# One statement of the template: labels, then a directive or an
# instruction (a lone prefix such as `lock;` joins the next one).
void inasm_piece(char* text):
	int i = inasm_skip(text, 0)
	while (1 == 1):
		int j = i
		while (asm_att_ident_char(text[j])): j = j + 1
		if ((j == i) || (text[inasm_skip(text, j)] != ':')): break
		inasm_define_label(asm_att_slice(text + i, j - i))
		i = inasm_skip(text, inasm_skip(text, j) + 1)
	if (text[i] == 0): return
	char* rest = text + i
	if ((rest[0] == '.') && asm_att_ident_char(rest[1])):
		if (inasm_prefix[0] != 0): inasm_fail(c"prefix before a directive", text)
		inasm_directive(rest, 0)
		return
	char* word = inasm_until(rest, 0, ' ')
	if (inasm_is_prefix(word) && (rest[strlen(word)] == 0)):
		inasm_prefix = strjoin(inasm_prefix, strjoin(word, c" "))
		return
	char* line = strjoin(inasm_prefix, rest)
	inasm_prefix = c""
	inasm_instruction(line)


# Split a template string into statements at newlines and ';', dropping
# `#` comments, and assemble each.
void inasm_template_string(char* s):
	int i = 0
	while (1 == 1):
		int start = i
		while ((s[i] != 0) && (s[i] != 10) && (s[i] != ';') && (s[i] != '#')): i = i + 1
		inasm_piece(asm_att_slice(s + start, i - start))
		if (s[i] == '#'):
			while ((s[i] != 0) && (s[i] != 10)): i = i + 1
		if (s[i] == 0): break
		i = i + 1


# Assemble a statement's template lines and resolve its references.
void inasm_template(list[char*] lines):
	inasm_template_reset()
	for i in range(lines.length): inasm_template_string(lines[i])
	if (inasm_prefix[0] != 0): inasm_fail(c"prefix without an instruction", inasm_prefix)
	if (inasm_section != INASM_TEXT): inasm_fail(c"template ends outside its code", c"add a .popsection")
	for i in range(inasm_fix_kind.length): inasm_resolve(i)
