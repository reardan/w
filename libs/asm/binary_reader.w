/*
Cross-arch binary section reader for the assembler/disassembler
libraries (docs/projects/assembler_disassembler.md, issue #164,
Phase 0.3).

Reads a compiled binary FROM DISK — unlike lib/__arch__/elf_introspect.w,
which walks the running process's own image — and works for any target's
output regardless of host arch: ELF32 (x86) and ELF64 (x64, arm64).
Returns the .text bytes plus the symbol table, which is what the
disassembler golden tests, the stub drift test and wdbg attach
symbolization all need.

64-bit file offsets/addresses are read as their low 32 bits: W compiler
output stays far below 4 GiB, and the reader asserts nothing overflows.

Compiled by the seed-compat gate (asm_seed_gate): only seed-understood
syntax here.
*/
import lib.lib
import lib.stream
import structures.string


int ASM_ELF_CLASS32():
	return 1


int ASM_ELF_CLASS64():
	return 2


# e_machine values
int ASM_EM_386():
	return 3


int ASM_EM_X86_64():
	return 62


int ASM_EM_AARCH64():
	return 183


struct asm_symbol:
	char* name    # points into the loaded file image
	int value     # st_value (virtual address)
	int size      # st_size


struct asm_binary:
	char* data          # whole file image (malloc'd)
	int length
	int elf_class       # ASM_ELF_CLASS32/64
	int machine         # e_machine
	int text_offset     # file offset of .text
	int text_size
	int text_vaddr      # virtual address .text loads at
	list[asm_symbol] symbols


int asm_read_u8(char* data, int offset):
	return data[offset] & 255


int asm_read_u16(char* data, int offset):
	return asm_read_u8(data, offset) | (asm_read_u8(data, offset + 1) << 8)


int asm_read_u32(char* data, int offset):
	return asm_read_u16(data, offset) | (asm_read_u16(data, offset + 2) << 16)


# Low word of a 32- or 64-bit field, asserting the high word of the
# 64-bit form is zero (see the header comment).
int asm_read_word(char* data, int offset, int elf_class):
	int low = asm_read_u32(data, offset)
	if (elf_class == ASM_ELF_CLASS64()):
		if (asm_read_u32(data, offset + 4) != 0):
			println2(c"asm_binary: 64-bit field exceeds 32 bits")
			exit(1)
	return low


char* asm_binary_read_file(char* path, int* length_out):
	wstream* in = stream_open_read(path)
	if (in == 0):
		return 0
	string_builder* contents = string_new()
	stream_read_all(in, contents)
	stream_close(in)
	char* data = contents.data
	*length_out = contents.length
	free(cast(char*, contents))
	return data


/*
Open and parse a compiled ELF binary. Returns 0 when the file cannot be
read or is not ELF; exits with a diagnostic on a structurally broken
ELF (truncated headers, missing .text) since every caller treats that
as a test failure.
*/
asm_binary* asm_binary_open(char* path):
	int length = 0
	char* data = asm_binary_read_file(path, &length)
	if (cast(int, data) == 0):
		return 0
	if (length < 52):
		return 0
	if (asm_read_u8(data, 0) != 127 | data[1] != 'E' | data[2] != 'L' | data[3] != 'F'):
		return 0
	asm_binary* binary = cast(asm_binary*, malloc(32))
	binary.data = data
	binary.length = length
	binary.elf_class = asm_read_u8(data, 4)
	binary.machine = asm_read_u16(data, 18)
	binary.text_offset = 0
	binary.text_size = 0
	binary.text_vaddr = 0
	binary.symbols = new list[asm_symbol]

	# Header field offsets differ by class.
	int is64 = binary.elf_class == ASM_ELF_CLASS64()
	int shoff_at = 32
	int shentsize_at = 46
	int shnum_at = 48
	int shstrndx_at = 50
	if (is64):
		shoff_at = 40
		shentsize_at = 58
		shnum_at = 60
		shstrndx_at = 62
	int shoff = asm_read_word(data, shoff_at, binary.elf_class)
	int shentsize = asm_read_u16(data, shentsize_at)
	int shnum = asm_read_u16(data, shnum_at)
	int shstrndx = asm_read_u16(data, shstrndx_at)
	if (shoff == 0 | shnum == 0):
		println2(c"asm_binary: no section headers")
		exit(1)

	# Section header field offsets (sh_name/sh_type shared; rest differ).
	int sh_addr_at = 12
	int sh_offset_at = 16
	int sh_size_at = 20
	int sh_link_at = 24
	int sh_entsize = 16   # symtab entry size for this class
	if (is64):
		sh_addr_at = 16
		sh_offset_at = 24
		sh_size_at = 32
		sh_link_at = 40
		sh_entsize = 24

	# Section name string table, for finding .text by name.
	int shstr_header = shoff + shstrndx * shentsize
	int shstr_offset = asm_read_word(data, shstr_header + sh_offset_at, binary.elf_class)

	int symtab_offset = 0
	int symtab_size = 0
	int strtab_offset = 0
	int index = 0
	while (index < shnum):
		int header = shoff + index * shentsize
		int name_index = asm_read_u32(data, header)
		int section_type = asm_read_u32(data, header + 4)
		char* name = data + shstr_offset + name_index
		if (strcmp(name, c".text") == 0):
			binary.text_offset = asm_read_word(data, header + sh_offset_at, binary.elf_class)
			binary.text_size = asm_read_word(data, header + sh_size_at, binary.elf_class)
			binary.text_vaddr = asm_read_word(data, header + sh_addr_at, binary.elf_class)
		if (section_type == 2):
			symtab_offset = asm_read_word(data, header + sh_offset_at, binary.elf_class)
			symtab_size = asm_read_word(data, header + sh_size_at, binary.elf_class)
			# sh_link names the section holding the symbol names.
			int link = asm_read_u32(data, header + sh_link_at)
			int link_header = shoff + link * shentsize
			strtab_offset = asm_read_word(data, link_header + sh_offset_at, binary.elf_class)
		index = index + 1
	if (binary.text_size == 0):
		println2(c"asm_binary: no .text section")
		exit(1)

	# Symbol table (optional: stripped binaries have none).
	if (symtab_offset != 0):
		int count = symtab_size / sh_entsize
		int i = 0
		while (i < count):
			int entry = symtab_offset + i * sh_entsize
			int name_at = asm_read_u32(data, entry)
			int value = 0
			int size = 0
			if (is64):
				value = asm_read_word(data, entry + 8, binary.elf_class)
				size = asm_read_word(data, entry + 16, binary.elf_class)
			else:
				value = asm_read_u32(data, entry + 4)
				size = asm_read_u32(data, entry + 8)
			if (name_at != 0):
				asm_symbol sym
				sym.name = data + strtab_offset + name_at
				sym.value = value
				sym.size = size
				binary.symbols.push(sym)
			i = i + 1
	return binary


# Pointer to the .text bytes inside the loaded image.
char* asm_binary_text(asm_binary* binary):
	return binary.data + binary.text_offset


# Symbol covering the given virtual address, or -1.
int asm_binary_symbol_at(asm_binary* binary, int address):
	int i = 0
	while (i < binary.symbols.length):
		asm_symbol sym = binary.symbols[i]
		if (address >= sym.value & address < sym.value + sym.size):
			return i
		i = i + 1
	return -1


# Named symbol's index, or -1.
int asm_binary_symbol_named(asm_binary* binary, char* name):
	int i = 0
	while (i < binary.symbols.length):
		asm_symbol sym = binary.symbols[i]
		if (strcmp(sym.name, name) == 0):
			return i
		i = i + 1
	return -1
