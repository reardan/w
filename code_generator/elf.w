import code_generator.code_emitter
import code_generator.elf_32
import code_generator.elf_64







void be_start(int word_size):
	if (word_size == 8):
		elf_start_64()
	else:
		elf_start()


void be_finish(int word_size):
	if (word_size == 8):
		elf_finish_64()
	else:
		elf_finish()


void elf_save_section_info(int word_size, int header_addr, int num_sections, int string_index):
	if (word_size == 8):
		# elf_save_section_info_64(header_addr, num_sections, string_index)
		int c = 0
	else:
		elf_save_section_info_32(header_addr, num_sections, string_index)




