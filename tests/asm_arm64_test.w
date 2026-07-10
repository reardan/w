/*
AArch64 (A64) decoder + encoder tests (issue #168):

1. Corpus round-trip: every entry in tests/asm/corpus_arm64.txt decodes to
   the recorded canonical text, and the text parses + encodes back to the
   recorded little-endian word (byte-exact; the arm64 subset the compiler
   emits is deterministic).

2. Golden decode->encode identity over an arm64 self-host binary built
   host-side (no qemu; nothing executes). Every function symbol's words
   decode with zero `.word` unknowns, and decode->encode reproduces each
   word. Inline string-literal / literal-pool data (the compiler branches
   over it with b/bl) is recognized and skipped. Reconstructed-from-operands
   vs raw-passthrough encodes are counted and reported.

docs/projects/assembler_disassembler.md.
*/
import lib.lib
import lib.assert
import libs.asm.insn
import libs.asm.hexutil
import libs.asm.binary_reader
import libs.asm.arm64_decode
import libs.asm.arm64_format
import libs.asm.arm64_encode
import libs.asm.arm64_text


int min_int(int a, int b):
	if (a < b):
		return a
	return b


int bytes4_equal(char* a, char* b):
	int i = 0
	while (i < 4):
		if ((a[i] & 255) != (b[i] & 255)):
			return 1 == 2
		i = i + 1
	return 1


void test_corpus():
	list[asm_corpus_entry] entries = asm_corpus_load(c"tests/asm/corpus_arm64.txt")
	asserts(c"empty arm64 corpus", entries.length > 100)
	int i = 0
	int decoded = 0
	int encoded_exact = 0
	int encode_mismatch = 0
	while (i < entries.length):
		asm_corpus_entry entry = entries[i]
		i = i + 1
		# decode -> format
		asm_insn insn
		asm_arm64_decode(entry.bytes, entry.length, 0, &insn)
		char* got = asm_arm64_format(&insn)
		if (strcmp(got, entry.text) != 0):
			print2(c"corpus line ")
			print2(itoa(entry.line))
			print2(c": bytes ")
			println2(asm_hex_encode(entry.bytes, entry.length))
			print2(c"  want: ")
			println2(entry.text)
			print2(c"  got:  ")
			println2(got)
			exit(1)
		decoded = decoded + 1
		# parse -> encode
		asm_insn parsed
		asm_arm64_parse(entry.text, &parsed)
		asm_buffer* b = asm_buffer_new()
		asm_arm64_encode(b, &parsed)
		if (b.length == 4 & bytes4_equal(b.data, entry.bytes)):
			encoded_exact = encoded_exact + 1
		else:
			encode_mismatch = encode_mismatch + 1
			if (encode_mismatch <= 10):
				print2(c"encode mismatch line ")
				print2(itoa(entry.line))
				print2(c" (")
				print2(entry.text)
				print2(c"): want ")
				print2(asm_hex_encode(entry.bytes, entry.length))
				print2(c" got ")
				println2(asm_hex_encode(b.data, b.length))
		asm_buffer_free(b)
	print2(c"corpus: ")
	print2(itoa(decoded))
	print2(c" decoded+formatted, ")
	print2(itoa(encoded_exact))
	print2(c" byte-exact re-encodes, ")
	print2(itoa(encode_mismatch))
	println2(c" mismatch")
	asserts(c"corpus parse->encode not byte-exact", encode_mismatch == 0)


int in_text(asm_binary* binary, int value):
	if (value < binary.text_vaddr):
		return 1 == 2
	if (value >= binary.text_vaddr + binary.text_size):
		return 1 == 2
	return 1


# Decode the word at text+off; return 1 if it is a `.word` unknown.
int word_is_unknown(char* text, int off, int address):
	asm_insn probe
	asm_arm64_decode(text + off, 4, address, &probe)
	if (strcmp(probe.mnemonic, c".word") == 0):
		return 1
	return 1 == 2


void test_golden():
	asm_binary* binary = asm_binary_open(c"bin/asm_arm64_selfhost")
	asserts(c"cannot open bin/wv2_arm64", cast(int, binary) != 0)
	assert_equal(ASM_EM_AARCH64(), binary.machine)
	char* text = asm_binary_text(binary)
	int functions = 0
	int count = 0
	int unknown = 0
	int reconstructed = 0
	int passthrough = 0
	int mismatch = 0
	int i = 0
	while (i < binary.symbols.length):
		asm_symbol sym = binary.symbols[i]
		i = i + 1
		if (sym.size <= 0):
			continue
		if (in_text(binary, sym.value) == 0):
			continue
		functions = functions + 1
		int func_off = sym.value - binary.text_vaddr
		int end = sym.size
		int pos = 0
		int prev_pcrel_ldr = 0
		while (pos < end):
			int off = func_off + pos
			int address = sym.value + pos
			asm_insn insn
			asm_arm64_decode(text + off, end - pos, address, &insn)
			int bt = insn.branch_target
			int forward = bt > address + 4 & bt <= sym.value + end
			int over = 0
			if (strcmp(insn.mnemonic, c"bl") == 0 & forward):
				over = 1
			else if (strcmp(insn.mnemonic, c"b") == 0 & forward):
				if (prev_pcrel_ldr):
					over = 1
				else if (pos + 8 <= end & word_is_unknown(text, off + 4, address + 4)):
					over = 1
			# encode-compare this instruction
			if (strcmp(insn.mnemonic, c".word") == 0):
				if (unknown < 12):
					print2(c"unknown in ")
					print2(sym.name)
					print2(c" +")
					print2(hex(pos))
					print2(c": ")
					println2(asm_hex_encode(text + off, 4))
				unknown = unknown + 1
			asm_buffer* eb = asm_buffer_new()
			asm_arm64_encode(eb, &insn)
			if (arm64_encode_reconstructed):
				reconstructed = reconstructed + 1
			else:
				passthrough = passthrough + 1
			if (eb.length != 4 | bytes4_equal(eb.data, text + off) == 0):
				if (mismatch < 12):
					print2(c"encode mismatch in ")
					print2(sym.name)
					print2(c" +")
					print2(hex(pos))
					print2(c" (")
					print2(asm_arm64_format(&insn))
					println2(c"):")
					print2(c"  original: ")
					println2(asm_hex_encode(text + off, 4))
					print2(c"  encoded:  ")
					println2(asm_hex_encode(eb.data, eb.length))
				mismatch = mismatch + 1
			asm_buffer_free(eb)
			count = count + 1
			if (over):
				pos = bt - sym.value
				prev_pcrel_ldr = 0
				continue
			prev_pcrel_ldr = 0
			if (strcmp(insn.mnemonic, c"ldr") == 0 & insn.op2.kind == ASM_OP_MEM()):
				if (insn.op2.disp_size == ARM64_ADDR_PCREL()):
					prev_pcrel_ldr = 1
			pos = pos + 4
	print2(c"wv2_arm64: ")
	print2(itoa(functions))
	print2(c" functions, ")
	print2(itoa(count))
	print2(c" instructions, ")
	print2(itoa(unknown))
	println2(c" unknown")
	print2(c"  encode identity: ")
	print2(itoa(reconstructed))
	print2(c" reconstructed, ")
	print2(itoa(passthrough))
	print2(c" raw-passthrough, ")
	print2(itoa(mismatch))
	println2(c" mismatch")
	asserts(c"functions found in wv2_arm64 .text", functions > 100)
	asserts(c"decoder left unknown words in wv2_arm64 functions", unknown == 0)
	asserts(c"decode->encode not byte-identical on wv2_arm64", mismatch == 0)


int main():
	test_corpus()
	test_golden()
	println(c"asm_arm64_test passed")
	return 0
