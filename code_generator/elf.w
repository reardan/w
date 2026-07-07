import code_generator.code_emitter
import code_generator.elf_32
import code_generator.elf_64
import code_generator.elf_arm64
import code_generator.macho_64







void be_start(int word_size):
	if (target_isa == 1):
		if (target_os == 1):
			macho_start_arm64()
		else:
			elf_start_arm64()
	else if (word_size == 8):
		elf_start_64()
	else:
		elf_start()


void be_finish(int word_size):
	if (target_isa == 1):
		if (target_os == 1):
			macho_finish_arm64()
		else:
			elf_finish_arm64()
	else if (word_size == 8):
		elf_finish_64()
	else:
		elf_finish()


void elf_save_section_info(int word_size, int header_addr, int num_sections, int string_index):
	if (word_size == 8):
		elf_save_section_info_64(header_addr, num_sections, string_index)
	else:
		elf_save_section_info_32(header_addr, num_sections, string_index)


# Format dispatchers + section-header field setters, so the symbol table
# emitter can stay word-size agnostic. Field offsets and widths follow the
# Elf32_Shdr and Elf64_Shdr layouts.

int elf_section_header_length():
	if (word_size == 8):
		return 64
	return 40


void elf_emit_section_header(int type):
	if (word_size == 8):
		elf_section_header_64(type)
	else:
		elf_section_header(type)


void elf_emit_sym_table_entry(int name, int address, int size, int binding, int symtype, int type):
	if (word_size == 8):
		elf_sym_table_entry_64(name, address, size, binding, symtype, type)
	else:
		elf_sym_table_entry(name, address, size, binding, symtype, type)


void elf_section_set_flags(int header, int v):
	if (word_size == 8):
		save_i(code + header + 8, v, 8)
	else:
		save_int(code + header + 8, v)


void elf_section_set_addr(int header, int v):
	if (word_size == 8):
		save_i(code + header + 16, v, 8)
	else:
		save_int(code + header + 12, v)


void elf_section_set_offset(int header, int v):
	if (word_size == 8):
		save_i(code + header + 24, v, 8)
	else:
		save_int(code + header + 16, v)


void elf_section_set_size(int header, int v):
	if (word_size == 8):
		save_i(code + header + 32, v, 8)
	else:
		save_int(code + header + 20, v)


void elf_section_set_link(int header, int v):
	if (word_size == 8):
		save_int(code + header + 40, v)
	else:
		save_int(code + header + 24, v)


void elf_section_set_info(int header, int v):
	if (word_size == 8):
		save_int(code + header + 44, v)
	else:
		save_int(code + header + 28, v)


void elf_section_set_entsize(int header, int v):
	if (word_size == 8):
		save_i(code + header + 56, v, 8)
	else:
		save_int(code + header + 36, v)




