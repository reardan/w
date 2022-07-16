import lib
import assert
import compiler.tokenizer
import codegen



void print_elf_header():
	println("printing elf header")

	# Use base of executable
	# TODO: dedupe this constant or come up with alternative method
	int base = 134512640 /* 0x00804800 */

	# Magic
	print("magic: ")
	print_n(base, 4)
	println("")

	# Class
	int class = base[4]
	print("class: [")
	print(itoa(class))
	print("] ")
	if (class == 0):
		println("none")
	else if(class == 1):
		println("32 bit")
	else if(class == 2):
		println("64 bit")
	else:
		println("class not recognized")

	# Data encoding
	int encoding = base[5]
	print("encoding: [")
	print(itoa(encoding))
	print("] ")
	if (encoding == 0):
		println("none")
	else if(encoding == 1):
		println("least significant")
	else if(encoding == 2):
		println("most significant")
	else:
		println("encoding not recognized")

	# Get Program Header offset
	int program_header_offset = load_int(base + 28)
	print_int("program_header_offset = ", program_header_offset)

	# Get Section Header offset
	int section_header_offset = load_int(base + 32)
	print_int("section_header_offset = ", section_header_offset)

	# Get Section Header Size + Count
	int section_header_size = load_i(base + 46, 2)
	print_int("section_header_size = ", section_header_size)
	int section_header_count = load_i(base + 48, 2)
	print_int("section_header_count = ", section_header_count)


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
			print_hex("strings section: ", string_addr)

		# Find Symbol Table Section
		else if (section_type == 2):
			symbol_table_addr = section_addr
			print_hex("symbol table section: ", symbol_table_addr)
			symbol_count = section_info
		
		section_index = section_index + 1

	# Process Symbol Table Entries
	int symbol_index = 0
	while (symbol_index < symbol_count):
		int entry_size = 16 /* remove this assertion */
		int symbol_addr = symbol_table_addr + entry_size * symbol_index
		print_hex("symbol_addr: ", symbol_addr)
		int name_index = load_int(symbol_addr + 0)
		print_int("name_index: ", name_index)
		int address = load_int(symbol_addr + 4)
		print("name: ")
		print(string_addr + name_index)
		print_hex(", address: ", address)
		int size = load_int(symbol_addr + 8)
		print_int("size: ", size)
		int symbol_info = load_int(symbol_addr + 12)
		print_hex("symbol_info: ", symbol_info)

		symbol_index = symbol_index + 1


int main():
	print_elf_header()
	return 0

