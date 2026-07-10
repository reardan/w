/*
x86 (32-bit) disassembler tests (issue #165):

1. Corpus round-trip: every single-instruction entry in
   tests/asm/corpus_x86.txt decodes to the recorded byte length and
   formats back to the recorded canonical text.
2. Zero-unknown golden test: the entire .text of the self-hosted
   compiler bin/wv2 disassembles with no `.byte` fallbacks, proving the
   decoder covers everything the compiler actually emits.

docs/projects/assembler_disassembler.md.
*/
import lib.lib
import lib.assert
import libs.asm.insn
import libs.asm.hexutil
import libs.asm.binary_reader
import libs.asm.x86_decode
import libs.asm.format


void nl2():
	println2(c"")


int min_int(int a, int b):
	if (a < b):
		return a
	return b


# Corpus entries whose text is a ' ; '-joined multi-instruction sequence
# are decoded instruction-by-instruction and rejoined, so sequence lines
# round-trip too.
char* asm_disasm_sequence(char* bytes, int length):
	char* out = 0
	int pos = 0
	while (pos < length):
		asm_insn insn
		int n = asm_x86_decode(bytes + pos, length - pos, pos, 4, &insn)
		char* piece = asm_format(&insn)
		if (cast(int, out) == 0):
			out = piece
		else:
			out = strjoin(out, strjoin(c" ; ", piece))
		pos = pos + n
	return out


void test_corpus_roundtrip():
	list[asm_corpus_entry] entries = asm_corpus_load(c"tests/asm/corpus_x86.txt")
	asserts(c"empty x86 corpus", entries.length > 50)
	int i = 0
	int checked = 0
	while (i < entries.length):
		asm_corpus_entry entry = entries[i]
		i = i + 1
		char* got = asm_disasm_sequence(entry.bytes, entry.length)
		if (strcmp(got, entry.text) != 0):
			print2(c"corpus line ")
			print2(itoa(entry.line))
			print2(c": bytes ")
			print2(asm_hex_encode(entry.bytes, entry.length))
			nl2()
			print2(c"  want: ")
			println2(entry.text)
			print2(c"  got:  ")
			println2(got)
			exit(1)
		checked = checked + 1
	print2(c"corpus round-trip: ")
	print2(itoa(checked))
	println2(c" entries")


# Disassemble every function symbol in bin/wv2 (the W compiler's ELF
# maps its headers into .text, so a raw linear walk would try to decode
# the ELF header; iterating symbol ranges is both correct and exactly
# what wdbg's `disas` will do). Every instruction must decode to a known
# mnemonic — zero `.byte` fallbacks proves the decoder covers everything
# the compiler emits.
int asm_test_in_text(asm_binary* binary, int value):
	if (value < binary.text_vaddr):
		return 0
	if (value >= binary.text_vaddr + binary.text_size):
		return 0
	return 1


void test_zero_unknown_wv2():
	asm_binary* binary = asm_binary_open(c"bin/wv2")
	asserts(c"cannot open bin/wv2", cast(int, binary) != 0)
	assert_equal(ASM_ELF_CLASS32(), binary.elf_class)
	char* text = asm_binary_text(binary)
	int functions = 0
	int count = 0
	int unknown = 0
	int i = 0
	while (i < binary.symbols.length):
		asm_symbol sym = binary.symbols[i]
		i = i + 1
		if (sym.size <= 0):
			continue
		if (asm_test_in_text(binary, sym.value) == 0):
			continue
		functions = functions + 1
		int func_off = sym.value - binary.text_vaddr
		int pos = 0
		while (pos < sym.size):
			asm_insn insn
			int n = asm_x86_decode(text + func_off + pos, sym.size - pos, sym.value + pos, 4, &insn)
			# The W codegen embeds string literals inline in .text: a
			# `call` jumps over (len+1) c-string bytes (or an 8-byte
			# descriptor + string) to the following pop. A forward `call`
			# whose target stays inside this function is that idiom, not a
			# real call — skip the data bytes between the call and its
			# target so the sweep resumes at real code.
			if (strcmp(insn.mnemonic, c"call") == 0 & insn.branch_target > sym.value + pos + n & insn.branch_target <= sym.value + sym.size):
				count = count + 1
				pos = insn.branch_target - sym.value
				continue
			if (strcmp(insn.mnemonic, c".byte") == 0):
				if (unknown < 10):
					print2(c"unknown in ")
					print2(sym.name)
					print2(c" +")
					print2(hex(pos))
					print2(c": ")
					println2(asm_hex_encode(text + func_off + pos, min_int(16, sym.size - pos)))
				unknown = unknown + 1
			count = count + 1
			pos = pos + n
	print2(c"wv2: ")
	print2(itoa(functions))
	print2(c" functions, ")
	print2(itoa(count))
	print2(c" instructions, ")
	print2(itoa(unknown))
	println2(c" unknown")
	asserts(c"functions found in wv2 .text", functions > 100)
	asserts(c"disassembler left unknown opcodes in wv2 functions", unknown == 0)


int main():
	test_corpus_roundtrip()
	test_zero_unknown_wv2()
	println(c"asm_x86_disasm_test passed")
	return 0
