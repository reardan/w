import lib.lib
import lib.assert
import compiler.tokenizer
import codegen



void print_elf_header():
	println(c"printing elf header")

	# Use base of executable
	# TODO: dedupe this constant or come up with alternative method
	int base = 134512640 /* 0x00804800 */

	# Magic
	print(c"magic: ")
	print_n(base, 4)
	println(c"")

	# Class
	int class = base[4]
	print(c"class: [")
	print(itoa(class))
	print(c"] ")
	if (class == 0):
		println(c"none")
	else if(class == 1):
		println(c"32 bit")
	else if(class == 2):
		println(c"64 bit")
	else:
		println(c"class not recognized")

	# Data encoding
	int encoding = base[5]
	print(c"encoding: [")
	print(itoa(encoding))
	print(c"] ")
	if (encoding == 0):
		println(c"none")
	else if(encoding == 1):
		println(c"least significant")
	else if(encoding == 2):
		println(c"most significant")
	else:
		println(c"encoding not recognized")

	# Get Program Header offset
	int program_header_offset = load_int(base + 28)
	print_int(c"program_header_offset = ", program_header_offset)

	# Get Section Header offset
	int section_header_offset = load_int(base + 32)
	print_int(c"section_header_offset = ", section_header_offset)

	# Get Section Header Size + Count
	int section_header_size = load_i(base + 46, 2)
	print_int(c"section_header_size = ", section_header_size)
	int section_header_count = load_i(base + 48, 2)
	print_int(c"section_header_count = ", section_header_count)


	# Iterate through Sections
	int section_index = 0
	int string_addr = 0
	int symbol_table_addr = 0
	int symbol_count = 0
	while (section_index < section_header_count):
		int section_header_addr = base + section_header_offset + section_index * section_header_size
		int section_type = load_int(section_header_addr + 4)
		int section_info = load_int(section_header_addr + 28)

		int section_addr = base + load_int(section_header_addr + 12)

		# Find Strings Section
		if (section_type == 3):
			string_addr = section_addr
			print_hex(c"strings section: ", string_addr)

		# Find Symbol Table Section
		else if (section_type == 2):
			symbol_table_addr = section_addr
			print_hex(c"symbol table section: ", symbol_table_addr)
			symbol_count = section_info
		
		section_index = section_index + 1

	# Process Symbol Table Entries
	int symbol_index = 0
	while (symbol_index < symbol_count):
		int entry_size = 16 /* remove this assertion */
		int symbol_addr = symbol_table_addr + entry_size * symbol_index
		print_hex(c"symbol_addr: ", symbol_addr)
		int name_index = load_int(symbol_addr + 0)
		print_int(c"name_index: ", name_index)
		int address = load_int(symbol_addr + 4)
		print(c"name: ")
		print(string_addr + name_index)
		print_hex(c", address: ", address)
		int size = load_int(symbol_addr + 8)
		print_int(c"size: ", size)
		int symbol_info = load_int(symbol_addr + 12)
		print_hex(c"symbol_info: ", symbol_info)

		symbol_index = symbol_index + 1


int main():
	print_elf_header()
	return 0

