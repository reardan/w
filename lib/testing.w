import lib.lib
import lib.assert
import compiler.tokenizer
import codegen
import lib.__arch__.elf_introspect


/* stripped version of elf.print_elf_header() todo: refactor/dedupe */
void execute_tests():
	println(c"Parsing symbol table for 'test_*' symbols.")

	# Use base of executable
	# TODO: dedupe this constant or come up with alternative method
	int base = 134512640 /* 0x00804800 */

	# Get Section Header offset
	int section_header_offset = elf_section_header_offset(base)

	# Get Section Header Size + Count
	int section_header_size = elf_section_header_size(base)
	int section_header_count = elf_section_header_count(base)

	# Iterate through Sections
	int section_index = 0
	int string_addr = 0
	int symbol_table_addr = 0
	int symbol_count = 0
	while (section_index < section_header_count):
		int section_header_addr = base + section_header_offset + section_index * section_header_size
		int section_type = elf_section_type(section_header_addr)
		int section_size = elf_section_size(section_header_addr)

		int section_addr = base + elf_section_addr(section_header_addr)

		# Find Strings Section
		if (section_type == 3):
			string_addr = section_addr

		# Find Symbol Table Section
		else if (section_type == 2):
			symbol_table_addr = section_addr
			symbol_count = section_size / elf_symbol_entry_size()
		
		section_index = section_index + 1

	asserts(c"No symbol table addr", symbol_table_addr > 0)
	asserts(c"No symbols found", symbol_count > 0)
	asserts(c"No strings found", string_addr > 0)

	# Process Symbol Table Entries
	int symbol_index = 0
	while (symbol_index < symbol_count):
		int symbol_addr = symbol_table_addr + elf_symbol_entry_size() * symbol_index
		int name_index = elf_symbol_name_index(symbol_addr)
		int test_addr = elf_symbol_value(symbol_addr)
		char* name = string_addr + name_index
		if (starts_with(name, c"test_")):
			println(c"")
			print(c"Run: '")
			print(name)
			print(c"()' -> ")
			print(hex(test_addr))
			println(c"")
			int* test_func = cast(int*, test_addr)

			print_hex(c"test_func: ", test_addr)
			test_func()

			print(c"Test '")
			print(name)
			println(c"()' passed!")

		symbol_index = symbol_index + 1



int main(int argc, int argv):
	execute_tests()
	println(c"")
	println(c"All tests passed!")
	return 0


