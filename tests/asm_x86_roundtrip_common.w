/*
Shared driver for the x86 and x64 assembler tests
(tests/asm_x86_asm_test.w, tests/asm_x64_test.w; issues #166/#167,
docs/projects/assembler_disassembler.md). Both modes share one
parser/encoder/decoder/formatter family, so each test is one call per
check with its corpus, parse arch and decode mode (4/8):

1. Corpus semantic round-trip: for each single-instruction entry,
   parse(text) -> encode -> decode -> format reproduces the canonical
   text. This proves the parser and encoder are correct inverses of the
   formatter/decoder without depending on the compiler's specific (often
   non-minimal) byte choices.

2. Corpus byte differential (informational): encode(parse(text)) == the
   recorded bytes for the entries the compiler encodes minimally; the
   count of non-minimal entries (e.g. disp32 for a small offset) is
   reported, not hidden.

3. Whole-.text encode identity: for every instruction in a self-host
   build's functions, decode -> encode reproduces the exact original
   bytes. This is the strong differential vs real compiler output; it is
   byte-exact because the decoder records displacement/operand widths.
*/
import lib.lib
import lib.assert
import libs.asm.insn
import libs.asm.hexutil
import libs.asm.binary_reader
import libs.asm.x86_decode
import libs.asm.x86_encode
import libs.asm.text
import libs.asm.format


int asm_text_has_sequence(char* text):
	int i = 0
	while (text[i] != 0):
		if (text[i] == ' ' && text[i + 1] == ';' && text[i + 2] == ' '):
			return 1
		i = i + 1
	return 1 == 2


int asm_bytes_equal(char* a, int an, char* b, int bn):
	if (an != bn):
		return 1 == 2
	for i in range(an):
		if ((a[i] & 255) != (b[i] & 255)):
			return 1 == 2
	return 1


# Encode one parsed instruction into a fresh buffer.
asm_buffer* asm_assemble_one(char* text, int parse_arch):
	asm_insn insn
	asm_x86_parse(text, parse_arch, &insn)
	asm_buffer* b = asm_buffer_new()
	asm_x86_encode(b, &insn)
	return b


# The corpus checks (header items 1 and 2) for one corpus file.
void asm_check_corpus(char* path, int parse_arch, int mode):
	list[asm_corpus_entry] entries = asm_corpus_load(path)
	asserts(c"empty corpus", entries.length > 50)
	int i = 0
	int checked = 0
	int byte_exact = 0
	int non_minimal = 0
	while (i < entries.length):
		asm_corpus_entry entry = entries[i]
		i = i + 1
		# Skip multi-instruction sequence lines (handled by the .text sweep).
		if (asm_text_has_sequence(entry.text)):
			continue
		checked = checked + 1
		asm_buffer* encoded = asm_assemble_one(entry.text, parse_arch)

		# Byte differential (informational): does our minimal encoding match?
		if (asm_bytes_equal(encoded.data, encoded.length, entry.bytes, entry.length)):
			byte_exact = byte_exact + 1
		else:
			non_minimal = non_minimal + 1

		# Semantic round-trip (required): re-decode our bytes and format.
		asm_insn back
		asm_x86_decode(encoded.data, encoded.length, 0, mode, &back)
		char* reformatted = asm_format(&back)
		if (strcmp(reformatted, entry.text) != 0):
			print2(c"semantic round-trip failed on corpus line ")
			println2(itoa(entry.line))
			print2(c"  text:    ")
			println2(entry.text)
			print2(c"  encoded: ")
			println2(asm_hex_encode(encoded.data, encoded.length))
			print2(c"  redecode: ")
			println2(reformatted)
			exit(1)
		asm_buffer_free(encoded)
	print2(c"corpus semantic round-trip: ")
	print2(itoa(checked))
	print2(c" entries (")
	print2(itoa(byte_exact))
	print2(c" byte-exact, ")
	print2(itoa(non_minimal))
	println2(c" non-minimal compiler forms)")


int asm_test_in_text(asm_binary* binary, int value):
	if (value < binary.text_vaddr):
		return 1 == 2
	if (value >= binary.text_vaddr + binary.text_size):
		return 1 == 2
	return 1


# decode -> encode every instruction in every function of the
# self-host build at path (header item 3); the bytes must come back
# identical, with no unknown opcodes. Inline string data (the
# call-over-data idiom) is skipped exactly as in the disassembler golden
# test.
void asm_check_encode_identity(char* path, int mode):
	asm_binary* binary = asm_binary_open(path)
	asserts(c"cannot open the self-host build", cast(int, binary) != 0)
	if (mode == 8):
		assert_equal(ASM_ELF_CLASS64, binary.elf_class)
	char* text = asm_binary_text(binary)
	int functions = 0
	int count = 0
	int unknown = 0
	int mismatch = 0
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
			char* here = text + func_off + pos
			asm_insn insn
			int n = asm_x86_decode(here, sym.size - pos, sym.value + pos, mode, &insn)
			if (strcmp(insn.mnemonic, c"call") == 0 & insn.branch_target > sym.value + pos + n && insn.branch_target <= sym.value + sym.size):
				# re-encode the call itself, then skip the inline data.
				asm_buffer* eb = asm_buffer_new()
				asm_x86_encode(eb, &insn)
				if (asm_bytes_equal(eb.data, eb.length, here, n) == 0):
					mismatch = mismatch + 1
				asm_buffer_free(eb)
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
					println2(asm_hex_encode(here, n))
				unknown = unknown + 1
				count = count + 1
				pos = pos + n
				continue
			asm_buffer* eb = asm_buffer_new()
			int en = asm_x86_encode(eb, &insn)
			if (en < 0 | asm_bytes_equal(eb.data, eb.length, here, n) == 0):
				if (mismatch < 10):
					print2(c"encode mismatch in ")
					print2(sym.name)
					print2(c" +")
					print2(hex(pos))
					print2(c" (")
					print2(asm_format(&insn))
					println2(c"):")
					print2(c"  original: ")
					println2(asm_hex_encode(here, n))
					print2(c"  encoded:  ")
					println2(asm_hex_encode(eb.data, eb.length))
				mismatch = mismatch + 1
			asm_buffer_free(eb)
			count = count + 1
			pos = pos + n
	print2(path)
	print2(c" encode identity: ")
	print2(itoa(functions))
	print2(c" functions, ")
	print2(itoa(count))
	print2(c" instructions, ")
	print2(itoa(unknown))
	print2(c" unknown, ")
	print2(itoa(mismatch))
	println2(c" mismatch")
	asserts(c"disassembler left unknown opcodes in self-host functions", unknown == 0)
	asserts(c"decode->encode not byte-identical on the self-host build", mismatch == 0)
