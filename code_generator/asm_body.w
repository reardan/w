/*
Assembly function bodies (docs/projects/asm_functions.md): assembles the
string lines of the `asm <isa>:` block that matched the compile target
and emits them at codepos as the function's entry.

The lines use the runtime stubs' text syntax (code_generator/asm_text.w:
the libs/asm canonical Intel / A64 text, ';' separating several
instructions on one line, `db 0xNN, ...` for raw bytes on every ISA --
arm64 instructions after db bytes must stay 4-byte aligned) plus named
labels, which the stubs do without:

	"loop:"              defines label 'loop' at the next instruction
	"jne loop"           branches to it (any operand word naming a label)
	"jmp portable"       'portable' is the reserved label just past the
	                     block: the function's portable W body, entered
	                     with the stack exactly as at the call

Label references are rewritten to the assembler's dot-relative form
('.+N' / '.-N') once every instruction's position is known. x86 Jcc is
the only variable-width branch: every one starts in its rel32 form and
the passes below shrink those whose target lies within rel8 reach until
nothing changes. Shrinking never lengthens another branch's distance,
so a branch that fits once keeps fitting and the loop terminates.

This file is in w.w's import graph, so it is compiled by the pinned seed
and must stay seed-syntax-safe.
*/
import code_generator.code_emitter
import code_generator.asm_text


# The matched block, one instruction or label per entry (lines are split
# on ';' as they are added), with the source position of each entry's
# string literal for diagnostics.
list[int] asm_body_texts
list[int] asm_body_lines
list[int] asm_body_columns
# Per entry: 0 instruction, 2 raw 'db' bytes.
list[int] asm_body_kinds
# Per entry: the label an instruction branches to (-1 when none), the
# start/end of that label word in the entry's text, the current encoded
# size and, for x86 Jcc, 1 once the rel8 form has been chosen.
list[int] asm_body_targets
list[int] asm_body_ref_starts
list[int] asm_body_ref_ends
list[int] asm_body_sizes
list[int] asm_body_short
list[int] asm_body_positions
# Defined label names and the entry each one precedes.
list[int] asm_body_label_names
list[int] asm_body_label_entries
int asm_body_ready


void asm_body_reset():
	if (asm_body_ready == 0):
		asm_body_texts = new list[int]
		asm_body_lines = new list[int]
		asm_body_columns = new list[int]
		asm_body_kinds = new list[int]
		asm_body_targets = new list[int]
		asm_body_ref_starts = new list[int]
		asm_body_ref_ends = new list[int]
		asm_body_sizes = new list[int]
		asm_body_short = new list[int]
		asm_body_positions = new list[int]
		asm_body_label_names = new list[int]
		asm_body_label_entries = new list[int]
		asm_body_ready = 1
	asm_body_texts.clear()
	asm_body_lines.clear()
	asm_body_columns.clear()
	asm_body_kinds.clear()
	asm_body_targets.clear()
	asm_body_ref_starts.clear()
	asm_body_ref_ends.clear()
	asm_body_sizes.clear()
	asm_body_short.clear()
	asm_body_positions.clear()
	asm_body_label_names.clear()
	asm_body_label_entries.clear()


int asm_body_ident_start(int c):
	return ((c >= 'a') && (c <= 'z')) || ((c >= 'A') && (c <= 'Z')) || (c == '_')


int asm_body_ident_char(int c):
	return asm_body_ident_start(c) || ((c >= '0') && (c <= '9'))


# Copy text[start, end) into a fresh NUL-terminated string.
char* asm_body_slice(char* text, int start, int end):
	char* out = cast(char*, malloc(end - start + 1))
	int i = 0
	while (start + i < end):
		out[i] = text[start + i]
		i = i + 1
	out[i] = 0
	return out


# Point the diagnostics at entry i's string literal and report. The
# block has been read by now, so the tokenizer's line is moved back too
# (as compiler/lint.w does) for the human form's location and context.
void asm_body_error(int i, char* a, char* b, char* c):
	diag_token_line = asm_body_lines[i]
	diag_token_column = asm_body_columns[i]
	line_number = diag_token_line - 1
	error3(a, b, c)


void asm_body_push(char* text, int kind, int line, int column):
	asm_body_texts.push(cast(int, text))
	asm_body_kinds.push(kind)
	asm_body_lines.push(line)
	asm_body_columns.push(column)
	asm_body_targets.push(-1)
	asm_body_ref_starts.push(0)
	asm_body_ref_ends.push(0)
	asm_body_sizes.push(0)
	asm_body_short.push(0)
	asm_body_positions.push(0)


int asm_body_label_find(char* name):
	int i = 0
	while (i < asm_body_label_names.length):
		if (strcmp(cast(char*, asm_body_label_names[i]), name) == 0): return i
		i = i + 1
	return -1


# One ';'-free piece of a line: an optional leading 'name:' label, then
# an optional instruction.
void asm_body_add_piece(char* text, int start, int end, int line, int column):
	while ((start < end) && ((text[start] == ' ') || (text[start] == 9))): start = start + 1
	while ((end > start) && ((text[end - 1] == ' ') || (text[end - 1] == 9))): end = end - 1
	if (start == end): return
	int i = start
	if (asm_body_ident_start(text[i])):
		while ((i < end) && asm_body_ident_char(text[i])): i = i + 1
		if ((i < end) && (text[i] == ':')):
			char* name = asm_body_slice(text, start, i)
			if (strcmp(name, c"portable") == 0):
				diag_token_line = line
				diag_token_column = column
				error3(c"asm label '", name, c"' is reserved for the portable W body")
			if (asm_body_label_find(name) >= 0):
				diag_token_line = line
				diag_token_column = column
				error3(c"asm label '", name, c"' is defined twice")
			asm_body_label_names.push(cast(int, name))
			asm_body_label_entries.push(asm_body_texts.length)
			asm_body_add_piece(text, i + 1, end, line, column)
			return
	char* piece = asm_body_slice(text, start, end)
	int kind = 0
	if (starts_with(piece, c"db ")): kind = 2
	asm_body_push(piece, kind, line, column)


# Add one decoded string literal of the block (may hold several
# ';'-separated instructions and labels).
void asm_body_add(char* text, int line, int column):
	int start = 0
	int i = 0
	while (1):
		if ((text[i] == ';') || (text[i] == 0)):
			asm_body_add_piece(text, start, i, line, column)
			if (text[i] == 0): return
			start = i + 1
		i = i + 1


# Find the operand word of entry i that names a label (or 'portable').
# Returns the label index (asm_body_label_names.length for 'portable')
# or -1, recording the word's span.
int asm_body_find_reference(int i):
	char* text = cast(char*, asm_body_texts[i])
	int p = 0
	# skip the mnemonic
	while ((text[p] != 0) && (text[p] != ' ') && (text[p] != 9)): p = p + 1
	while (text[p] != 0):
		if (asm_body_ident_start(text[p]) && ((p == 0) || (asm_body_ident_char(text[p - 1]) == 0))):
			int start = p
			while (asm_body_ident_char(text[p])): p = p + 1
			char* word = asm_body_slice(text, start, p)
			int found = asm_body_label_find(word)
			if ((found < 0) && (strcmp(word, c"portable") == 0)): found = asm_body_label_names.length
			free(word)
			if (found >= 0):
				asm_body_ref_starts[i] = start
				asm_body_ref_ends[i] = p
				return found
		else: p = p + 1
	return -1


# Entry index a label index resolves to (entries.length past the end).
int asm_body_label_entry(int label):
	if (label == asm_body_label_names.length): return asm_body_texts.length
	return asm_body_label_entries[label]


# Byte position of entry e (or of the end of the block).
int asm_body_entry_position(int e):
	if (e < asm_body_texts.length): return asm_body_positions[e]
	if (asm_body_texts.length == 0): return 0
	int last = asm_body_texts.length - 1
	return asm_body_positions[last] + asm_body_sizes[last]


# Entry i's text with its label reference replaced by '.+disp'/'.-disp'.
char* asm_body_resolved_text(int i, int disp):
	char* text = cast(char*, asm_body_texts[i])
	if (asm_body_targets[i] < 0): return strclone(text)
	char* head = asm_body_slice(text, 0, asm_body_ref_starts[i])
	char* sign = c".+"
	if (disp < 0):
		sign = c".-"
		disp = 0 - disp
	char* number = itoa(disp)
	char* tail = text + asm_body_ref_ends[i]
	char* out = strjoin(head, strjoin(sign, strjoin(number, tail)))
	free(head)
	free(number)
	return out


int asm_body_is_jcc(char* text):
	if (text[0] != 'j'): return 0
	if ((text[1] == 'm') && (text[2] == 'p')): return 0
	return 1


# 1 when operand op holds a word the assembler could not resolve (a bare
# word that names no asm label, an unknown register inside [...]) or a
# register the ISA lacks (x86 has no r8..r15 and no 64-bit registers).
int asm_body_bad_operand(int arch, asm_operand* op):
	if (op.kind == ASM_OP_LABEL):
		if (op.label[0] == '.'): return 0
		if ((arch == ASM_ARCH_ARM64) && (arm64_cond_lookup_cset(op.label) >= 0)): return 0
		return 1
	if (arch == ASM_ARCH_ARM64): return 0
	int limit = 15
	if (arch == ASM_ARCH_X86): limit = 7
	if (op.kind == ASM_OP_REG):
		if (op.rclass != ASM_RCLASS_GP): return 0
		if ((arch == ASM_ARCH_X86) && (op.size == 8)): return 1
		return op.reg > limit
	if (op.kind == ASM_OP_MEM):
		if ((op.base < -1) || (op.base > limit)): return 1
		if ((op.index < -1) || (op.index > limit)): return 1
	return 0


void asm_body_check_operands(int arch, int i, asm_insn* insn):
	if (asm_body_bad_operand(arch, &insn.op1) || asm_body_bad_operand(arch, &insn.op2) || asm_body_bad_operand(arch, &insn.op3)):
		char* what = c"unknown register or asm label in '"
		if (asm_body_targets[i] < 0):
			if (asm_body_is_jcc(insn.mnemonic) || (strcmp(insn.mnemonic, c"jmp") == 0) || (strcmp(insn.mnemonic, c"call") == 0)):
				what = c"undefined asm label in '"
		asm_body_error(i, what, cast(char*, asm_body_texts[i]), c"'")


# Encode entry i into the scratch buffer for arch; disp is the label
# displacement (ignored without a reference). Returns the byte count.
int asm_body_encode(int arch, int i, int disp, asm_buffer* b):
	b.length = 0
	if (asm_body_kinds[i] == 2):
		asm_text_raw_bytes(cast(char*, asm_body_texts[i]), b)
		return b.length
	char* text = asm_body_resolved_text(i, disp)
	asm_insn insn
	if (arch == ASM_ARCH_ARM64):
		if (asm_arm64_parse(text, &insn) == 0): asm_body_error(i, c"cannot assemble arm64 instruction '", cast(char*, asm_body_texts[i]), c"'")
		asm_body_check_operands(arch, i, &insn)
		if ((insn.mnemonic[0] == 'b') && (insn.mnemonic[1] == '.') && (arm64_cond_lookup_branch(insn.mnemonic + 2) < 0)):
			asm_body_error(i, c"unknown arm64 branch condition in '", cast(char*, asm_body_texts[i]), c"'")
		insn.address = 0
		# An unknown mnemonic or operand form comes back as a placeholder
		# word with arm64_encode_reconstructed cleared.
		if ((asm_arm64_encode(b, &insn) != 4) || (arm64_encode_reconstructed == 0)):
			asm_body_error(i, c"cannot assemble arm64 instruction '", cast(char*, asm_body_texts[i]), c"'")
	else:
		if (asm_x86_parse(text, arch, &insn) == 0): asm_body_error(i, c"cannot assemble x86 instruction '", cast(char*, asm_body_texts[i]), c"'")
		asm_body_check_operands(arch, i, &insn)
		if (asm_body_targets[i] >= 0):
			if (asm_body_is_jcc(insn.mnemonic)):
				if (asm_body_short[i]): insn.length = 2
				else: insn.length = 6
		if (asm_x86_encode(b, &insn) <= 0): asm_body_error(i, c"cannot assemble x86 instruction '", cast(char*, asm_body_texts[i]), c"'")
	free(text)
	return b.length


# Lay out every entry at its current size choice.
void asm_body_layout(int arch, asm_buffer* b):
	int position = 0
	int i = 0
	while (i < asm_body_texts.length):
		asm_body_positions[i] = position
		asm_body_sizes[i] = asm_body_encode(arch, i, 0x10000, b)
		position = position + asm_body_sizes[i]
		i = i + 1


# Assemble the collected block for arch (ASM_ARCH_X86/X64/ARM64) and emit
# it at codepos. Returns 1 when some instruction branches to 'portable'.
int asm_body_emit(int arch):
	asm_buffer* b = asm_buffer_new()
	int uses_portable = 0
	int i = 0
	while (i < asm_body_texts.length):
		int label = asm_body_find_reference(i)
		asm_body_targets[i] = label
		if (label == asm_body_label_names.length): uses_portable = 1
		i = i + 1
	# Size pass with every Jcc long, then shrink until stable.
	asm_body_layout(arch, b)
	int changed = 1
	while (changed && (arch != ASM_ARCH_ARM64)):
		changed = 0
		i = 0
		while (i < asm_body_texts.length):
			if ((asm_body_targets[i] >= 0) && (asm_body_short[i] == 0) && asm_body_is_jcc(cast(char*, asm_body_texts[i]))):
				int disp = asm_body_entry_position(asm_body_label_entry(asm_body_targets[i])) - asm_body_positions[i]
				if (((disp - 2) >= -128) && ((disp - 2) <= 127)):
					asm_body_short[i] = 1
					changed = 1
			i = i + 1
		if (changed): asm_body_layout(arch, b)
	# Final pass: encode with the real displacements and emit. A64
	# instructions are words: 'db' data must keep them 4-byte aligned.
	i = 0
	while (i < asm_body_texts.length):
		if ((arch == ASM_ARCH_ARM64) && (asm_body_kinds[i] == 0) && ((asm_body_positions[i] & 3) != 0)):
			asm_body_error(i, c"arm64 instruction '", cast(char*, asm_body_texts[i]), c"' is not 4-byte aligned (pad the db bytes before it)")
		int disp = 0
		if (asm_body_targets[i] >= 0):
			disp = asm_body_entry_position(asm_body_label_entry(asm_body_targets[i])) - asm_body_positions[i]
		int n = asm_body_encode(arch, i, disp, b)
		if (n != asm_body_sizes[i]): asm_body_error(i, c"internal error: asm instruction '", cast(char*, asm_body_texts[i]), c"' changed size between passes")
		emit(n, b.data)
		i = i + 1
	asm_buffer_free(b)
	return uses_portable
