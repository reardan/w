/*
Compile-time assembly of the runtime stubs (issue #207, follow-up to
#170; docs/projects/assembler_disassembler.md "Runtime stubs").

code_generator/{x86,x64,arm64}_asm.w write each stub as one assembly-text
line per instruction; the helpers here run the line through the libs/asm
text parser + encoder and append the bytes at codepos, so the stubs have
no hand-hexed byte strings to keep in sync with their comments.

Syntax is the libs/asm canonical Intel / A64 text. `db 0xNN, ...` emits
raw bytes for the few x86 instructions the text assembler cannot encode
(segment-register moves, shift by an immediate other than 1, a store of
an immediate to memory). A line the assembler rejects is an internal
compiler error: every stub is assembled on every compile, so it can never
ship broken.

This file and the libs/asm modules it imports are in w.w's import graph:
they are compiled by the pinned seed and must stay seed-syntax-safe
(asm_seed_gate).
*/
import code_generator.code_emitter
import libs.asm.insn
import libs.asm.text
import libs.asm.x86_encode
import libs.asm.arm64_text
import libs.asm.arm64_encode


# Scratch buffer each line is encoded into before it is copied to code.
asm_buffer* asm_text_buffer


void asm_text_fail(char* text):
	print2(c"internal error: cannot assemble runtime stub line: ")
	println2(text)
	exit(1)


asm_buffer* asm_text_reset():
	if (cast(int, asm_text_buffer) == 0): asm_text_buffer = asm_buffer_new()
	asm_text_buffer.length = 0
	return asm_text_buffer


# 'db 0x66, 0x8c, 0xe0': append the listed bytes to b.
void asm_text_raw_bytes(char* text, asm_buffer* b):
	int i = 3
	while (text[i] != 0):
		while (text[i] == ' ' || text[i] == ','): i = i + 1
		if (text[i] == 0): return
		int start = i
		while (text[i] != 0 && text[i] != ',' && text[i] != ' '): i = i + 1
		char* tok = malloc(i - start + 1)
		int j = 0
		while (start + j < i):
			tok[j] = text[start + j]
			j = j + 1
		tok[j] = 0
		asm_buffer_byte(b, asm_parse_number(tok) & 255)
		free(tok)


# Assemble one x86-family line (arch = ASM_ARCH_X86() or ASM_ARCH_X64())
# and emit its bytes.
void asm_text_x86_family(int arch, char* text):
	asm_buffer* b = asm_text_reset()
	if (starts_with(text, c"db ")): asm_text_raw_bytes(text, b)
	else:
		asm_insn insn
		if (asm_x86_parse(text, arch, &insn) == 0): asm_text_fail(text)
		if (asm_x86_encode(b, &insn) <= 0): asm_text_fail(text)
	if (b.length == 0): asm_text_fail(text)
	emit(b.length, b.data)


# One A64 instruction (a little-endian 32-bit word).
void asm_text_a64(char* text):
	asm_buffer* b = asm_text_reset()
	asm_insn insn
	if (asm_arm64_parse(text, &insn) == 0): asm_text_fail(text)
	if (asm_arm64_encode(b, &insn) != 4): asm_text_fail(text)
	emit(b.length, b.data)


# Assemble a stub line of one or more instructions separated by ';'
# for arch (ASM_ARCH_X86(), ASM_ARCH_X64() or ASM_ARCH_ARM64()).
void asm_text_lines(int arch, char* text):
	int start = 0
	int i = 0
	while (1):
		if ((text[i] == ';') || (text[i] == 0)):
			while (text[start] == ' '): start = start + 1
			char* one = malloc(i - start + 1)
			int j = 0
			while (start + j < i):
				one[j] = text[start + j]
				j = j + 1
			while ((j > 0) && (one[j - 1] == ' ')): j = j - 1
			one[j] = 0
			if (arch == ASM_ARCH_ARM64): asm_text_a64(one)
			else: asm_text_x86_family(arch, one)
			free(one)
			if (text[i] == 0): return
			start = i + 1
		i = i + 1


# 32-bit x86 instructions ('mov eax,1; ret').
void x86_asm(char* text):
	asm_text_lines(ASM_ARCH_X86, text)


# x86-64 instructions.
void x64_asm(char* text):
	asm_text_lines(ASM_ARCH_X64, text)


# A64 instructions.
void a64_asm(char* text):
	asm_text_lines(ASM_ARCH_ARM64, text)
