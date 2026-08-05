/*
Structural regression test for DWARF address widths (the former
docs/todo.txt x64 limitation "DWARF line info still declares
address_size 4").

The dwarf_addr_size_test build target compiles tests/dwarf_addr_fixture.w
for x86 (bin/dwarf_addr_fixture_32) and x64 (bin/dwarf_addr_fixture_64),
runs both, then runs this program, which parses each ELF from disk and
asserts:
 - .debug_info's compile-unit header declares address_size equal to
   the target word size (4 / 8), and the DW_FORM_addr attribute pair
   really is that wide (checked through the unit_length arithmetic and
   DW_AT_low_pc matching .text's load address);
 - .debug_line's line program opens with a DW_LNE_set_address whose
   length byte covers the opcode plus one target-word-wide address
   (5 / 9) pointing into .text.
*/
import lib.lib
import lib.assert
import libs.asm.binary_reader


# File offset of the named section header's payload; the size is stored
# through size_out. Exits with a diagnostic when the section is missing.
int section_find(char* data, int elf_class, char* want, int* size_out):
	int is64 = 0
	if (elf_class == ASM_ELF_CLASS64()):
		is64 = 1
	int shoff_at = 32
	int shentsize_at = 46
	int shnum_at = 48
	int shstrndx_at = 50
	int sh_offset_at = 16
	int sh_size_at = 20
	if (is64):
		shoff_at = 40
		shentsize_at = 58
		shnum_at = 60
		shstrndx_at = 62
		sh_offset_at = 24
		sh_size_at = 32
	int shoff = asm_read_word(data, shoff_at, elf_class)
	int shentsize = asm_read_u16(data, shentsize_at)
	int shnum = asm_read_u16(data, shnum_at)
	int shstrndx = asm_read_u16(data, shstrndx_at)
	int shstr_header = shoff + shstrndx * shentsize
	int shstr_offset = asm_read_word(data, shstr_header + sh_offset_at, elf_class)
	int index = 0
	while (index < shnum):
		int header = shoff + index * shentsize
		int name_index = asm_read_u32(data, header)
		char* name = data + shstr_offset + name_index
		if (strcmp(name, want) == 0):
			*size_out = asm_read_word(data, header + sh_size_at, elf_class)
			return asm_read_word(data, header + sh_offset_at, elf_class)
		index = index + 1
	print(c"missing section: ")
	println(want)
	exit(1)
	return 0


# Little-endian address field of the given byte width. W output stays
# far below 4 GiB, so an 8-byte address must have a zero high word.
int read_address(char* data, int offset, int width):
	int value = asm_read_u32(data, offset)
	if (width == 8):
		assert_equal(0, asm_read_u32(data, offset + 4))
	return value


void check_binary(char* path, int word_size):
	asm_binary* binary = asm_binary_open(path)
	asserts(c"fixture opens as ELF", cast(int, binary) != 0)
	if (word_size == 8):
		assert_equal(ASM_ELF_CLASS64(), binary.elf_class)
		assert_equal(ASM_EM_X86_64(), binary.machine)
	else:
		assert_equal(ASM_ELF_CLASS32(), binary.elf_class)
		assert_equal(ASM_EM_386(), binary.machine)
	char* data = binary.data

	# .debug_info compile-unit header:
	# +0 unit_length(4) +4 version(2) +6 abbrev_offset(4)
	# +10 address_size(1)
	int info_size = 0
	int info = section_find(data, binary.elf_class, c".debug_info", &info_size)
	assert_equal(2, asm_read_u16(data, info + 4)) /* DWARF version */
	assert_equal(word_size, asm_read_u8(data, info + 10)) /* address_size */

	# The single childless CU (debug_info_emit) is version(2) +
	# abbrev_offset(4) + address_size(1) + abbrev-code uleb(1) +
	# name(n+1) + stmt_list(4) + low_pc/high_pc (word size each) +
	# end-of-children uleb(1): unit_length = 14 + n + 2 * word_size.
	int name_at = info + 12
	int name_length = strlen(data + name_at)
	assert_equal(14 + name_length + 2 * word_size, asm_read_u32(data, info))

	# DW_AT_low_pc (the first DW_FORM_addr) is .text's load address.
	int low_pc_at = name_at + name_length + 1 + 4
	assert_equal(binary.text_vaddr, read_address(data, low_pc_at, word_size))
	int high_pc = read_address(data, low_pc_at + word_size, word_size)
	asserts(c"high_pc above low_pc", high_pc > binary.text_vaddr)

	# .debug_line: +0 unit_length(4) +4 version(2) +6 header_length(4);
	# the line program starts after header_length and opens with
	# DW_LNE_set_address (0x00, length, 0x02, address).
	int line_size = 0
	int line = section_find(data, binary.elf_class, c".debug_line", &line_size)
	assert_equal(2, asm_read_u16(data, line + 4)) /* DWARF version */
	int program = line + 10 + asm_read_u32(data, line + 6)
	asserts(c"line program inside section", program < line + line_size)
	assert_equal(0, asm_read_u8(data, program)) /* extended opcode */
	assert_equal(1 + word_size, asm_read_u8(data, program + 1)) /* length */
	assert_equal(2, asm_read_u8(data, program + 2)) /* DW_LNE_set_address */
	int first = read_address(data, program + 3, word_size)
	asserts(c"set_address at or above .text start", first >= binary.text_vaddr)
	asserts(c"set_address inside .text", first < binary.text_vaddr + binary.text_size)
	println(path)


int main():
	check_binary(c"bin/dwarf_addr_fixture_32", 4)
	check_binary(c"bin/dwarf_addr_fixture_64", 8)
	println(c"dwarf_addr_size_test passed")
	return 0
