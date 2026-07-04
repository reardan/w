# Elf32 layout offsets, for introspecting the running binary's own image
# (the test harness walks its section headers and symbol table).
import code_generator.integer


int elf_section_header_offset(int base):
	return load_int(base + 32) /* e_shoff */


int elf_section_header_size(int base):
	return load_i(base + 46, 2) /* e_shentsize */


int elf_section_header_count(int base):
	return load_i(base + 48, 2) /* e_shnum */


int elf_section_type(int header):
	return load_int(header + 4) /* sh_type */


int elf_section_addr(int header):
	return load_int(header + 12) /* sh_addr */


int elf_section_size(int header):
	return load_int(header + 20) /* sh_size */


int elf_symbol_entry_size():
	return 16 /* sizeof(Elf32_Sym) */


int elf_symbol_name_index(int entry):
	return load_int(cast(char*, entry)) /* st_name */


int elf_symbol_value(int entry):
	return load_int(entry + 4) /* st_value */
