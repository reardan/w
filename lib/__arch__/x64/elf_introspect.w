# Elf64 layout offsets, for introspecting the running binary's own image
# (the test harness walks its section headers and symbol table).
import code_generator.integer


int elf_section_header_offset(int base):
	return load_i(base + 40, 8) /* e_shoff */


int elf_section_header_size(int base):
	return load_i(base + 58, 2) /* e_shentsize */


int elf_section_header_count(int base):
	return load_i(base + 60, 2) /* e_shnum */


int elf_section_type(int header):
	return load_int(header + 4) /* sh_type */


int elf_section_addr(int header):
	return load_i(header + 16, 8) /* sh_addr */


int elf_section_size(int header):
	return load_i(header + 32, 8) /* sh_size */


int elf_symbol_entry_size():
	return 24 /* sizeof(Elf64_Sym) */


int elf_symbol_name_index(int entry):
	return load_int(entry) /* st_name */


int elf_symbol_value(int entry):
	return load_i(entry + 8, 8) /* st_value */
