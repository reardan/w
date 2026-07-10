/*
Tests for the assembler/disassembler foundation layer
(docs/projects/assembler_disassembler.md, issue #164): byte buffer,
labels/fixups, register tables, hex/corpus utilities and the
cross-arch binary section reader.

The asm_foundations_test build target compiles bin/asm_elf64_fixture
(an ELF64 binary) before running this, so the reader is exercised on
both ELF classes.
*/
import lib.lib
import lib.assert
import libs.asm.insn
import libs.asm.registers
import libs.asm.hexutil
import libs.asm.binary_reader


void test_buffer_and_labels():
	asm_buffer* b = asm_buffer_new()
	asm_labels* labels = asm_labels_new()

	# jmp rel32 to a forward label, then the label, then ret.
	asm_buffer_byte(b, 0xe9)
	asm_labels_reference(labels, c"target", b.length, ASM_FIX_REL32())
	asm_buffer_int32(b, 0)
	asm_buffer_byte(b, 0x90)
	asm_labels_define(labels, c"target", b.length)
	asm_buffer_byte(b, 0xc3)
	assert_equal(0, asm_labels_resolve(labels, b))

	# e9 <rel32=1> 90 c3: the displacement is from the end of the field
	# (offset 5) to the label (offset 6).
	char* want = malloc(8)
	assert_equal(7, asm_hex_decode(c"e90100000090c3", want, 8))
	asm_assert_bytes_equal(c"label fixup", want, 7, b.data, b.length)

	# Growth: push enough bytes to force several reallocations.
	int i = 0
	while (i < 1000):
		asm_buffer_byte(b, i & 255)
		i = i + 1
	assert_equal(1007, b.length)
	assert_equal(999 & 255, b.data[b.length - 1] & 255)

	# An unresolved fixup is reported, not silently dropped.
	asm_labels_reference(labels, c"missing", 0, ASM_FIX_ABS32())
	assert_equal(1, asm_labels_resolve(labels, b))


void test_insn_model():
	asm_insn insn
	asm_insn_clear(&insn)
	assert_equal(0, asm_insn_operand_count(&insn))
	insn.mnemonic = c"mov"
	insn.op1.kind = ASM_OP_REG()
	insn.op1.reg = 0
	insn.op1.size = 4
	insn.op2.kind = ASM_OP_MEM()
	insn.op2.base = 4
	insn.op2.disp = 16
	insn.op2.size = 4
	assert_equal(2, asm_insn_operand_count(&insn))


void test_registers():
	assert_equal(0, asm_reg_number(asm_reg_lookup_x86(c"eax")))
	assert_equal(4, asm_reg_size(asm_reg_lookup_x86(c"eax")))
	assert_equal(7, asm_reg_number(asm_reg_lookup_x86(c"edi")))
	assert_equal(8, asm_reg_size(asm_reg_lookup_x86(c"r15")))
	assert_equal(15, asm_reg_number(asm_reg_lookup_x86(c"r15")))
	assert_equal(1, asm_reg_size(asm_reg_lookup_x86(c"cl")))
	assert_equal(2, asm_reg_size(asm_reg_lookup_x86(c"sp")))
	assert_equal(-1, asm_reg_lookup_x86(c"xax"))
	assert_strings_equal(c"esp", asm_reg_name(ASM_ARCH_X86(), 4, 4))
	assert_strings_equal(c"r9", asm_reg_name(ASM_ARCH_X64(), 9, 8))

	assert_equal(28, asm_reg_number(asm_reg_lookup_arm64(c"x28")))
	assert_equal(8, asm_reg_size(asm_reg_lookup_arm64(c"x28")))
	assert_equal(4, asm_reg_size(asm_reg_lookup_arm64(c"w0")))
	assert_equal(31, asm_reg_number(asm_reg_lookup_arm64(c"sp")))
	assert_equal(-1, asm_reg_lookup_arm64(c"x31"))
	assert_equal(-1, asm_reg_lookup_arm64(c"q0"))
	assert_strings_equal(c"x28", asm_reg_name(ASM_ARCH_ARM64(), 28, 8))
	assert_strings_equal(c"w7", asm_reg_name(ASM_ARCH_ARM64(), 7, 4))


void test_hex():
	char* bytes = malloc(16)
	assert_equal(4, asm_hex_decode(c"8b442410", bytes, 16))
	assert_equal(0x8b, bytes[0] & 255)
	assert_equal(0x10, bytes[3] & 255)
	assert_strings_equal(c"8b442410", asm_hex_encode(bytes, 4))
	assert_equal(-1, asm_hex_decode(c"8b4", bytes, 16))
	assert_equal(0, asm_hex_decode(c"|text", bytes, 16))


void check_corpus(char* path, int minimum):
	list[asm_corpus_entry] entries = asm_corpus_load(path)
	if (entries.length < minimum):
		print2(c"corpus too small: ")
		print2(path)
		print2(c" has ")
		print2(itoa(entries.length))
		print2(c" entries, want at least ")
		println2(itoa(minimum))
		exit(1)
	int i = 0
	while (i < entries.length):
		asm_corpus_entry entry = entries[i]
		asserts(c"corpus entry has no bytes", entry.length > 0)
		asserts(c"corpus entry has no text", entry.text[0] != 0)
		i = i + 1


void test_corpus_fixtures():
	check_corpus(c"tests/asm/corpus_x86.txt", 50)
	check_corpus(c"tests/asm/corpus_x64.txt", 50)
	check_corpus(c"tests/asm/corpus_arm64.txt", 50)


void test_binary_reader_elf32():
	asm_binary* binary = asm_binary_open(c"bin/wv2")
	asserts(c"cannot open bin/wv2", cast(int, binary) != 0)
	assert_equal(ASM_ELF_CLASS32(), binary.elf_class)
	assert_equal(ASM_EM_386(), binary.machine)
	asserts(c"wv2 .text too small", binary.text_size > 100000)
	asserts(c"wv2 has no symbols", binary.symbols.length > 100)

	# main is a real function symbol whose range contains its own start.
	int main_index = asm_binary_symbol_named(binary, c"main")
	asserts(c"no main symbol", main_index >= 0)
	asm_symbol main_sym = binary.symbols[main_index]
	asserts(c"main has no size", main_sym.size > 0)
	assert_equal(main_index, asm_binary_symbol_at(binary, main_sym.value))

	# .text bytes are readable and land inside the image.
	char* text = asm_binary_text(binary)
	asserts(c"text out of range", binary.text_offset + binary.text_size <= binary.length)
	int check = text[0] & 255
	asserts(c"unreadable text", check >= 0)


void test_binary_reader_elf64():
	asm_binary* binary = asm_binary_open(c"bin/asm_elf64_fixture")
	asserts(c"cannot open bin/asm_elf64_fixture", cast(int, binary) != 0)
	assert_equal(ASM_ELF_CLASS64(), binary.elf_class)
	assert_equal(ASM_EM_X86_64(), binary.machine)
	asserts(c"fixture .text empty", binary.text_size > 0)


void test_binary_reader_rejects_non_elf():
	asm_binary* binary = asm_binary_open(c"tests/asm/corpus_x86.txt")
	assert_equal(0, cast(int, binary))
	binary = asm_binary_open(c"tests/asm/no_such_file")
	assert_equal(0, cast(int, binary))


int main():
	test_buffer_and_labels()
	test_insn_model()
	test_registers()
	test_hex()
	test_corpus_fixtures()
	test_binary_reader_elf32()
	test_binary_reader_elf64()
	test_binary_reader_rejects_non_elf()
	println(c"asm_foundations_test passed")
	return 0
