import lib.lib
import lib.assert
import compiler.tokenizer
import codegen


/* stripped version of elf.print_elf_header() todo: refactor/dedupe */
void execute_tests():
	println("Parsing symbol table for 'test_*' symbols.")

	# Use base of executable
	# TODO: dedupe this constant or come up with alternative method
	int base = 134512640 /* 0x00804800 */

	# Get Section Header offset
	int section_header_offset = load_int(base + 32)

	# Get Section Header Size + Count
	int section_header_size = load_i(base + 46, 2)
	int section_header_count = load_i(base + 48, 2)

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

		# Find Symbol Table Section
		else if (section_type == 2):
			symbol_table_addr = section_addr
			symbol_count = section_info
		
		section_index = section_index + 1

	asserts("No symbol table addr", symbol_table_addr > 0)
	asserts("No symbols found", symbol_count > 0)
	asserts("No strings found", string_addr > 0)

	# Process Symbol Table Entries
	int symbol_index = 0
	while (symbol_index < symbol_count):
		int entry_size = 16 /* remove this assertion */
		int symbol_addr = symbol_table_addr + entry_size * symbol_index
		int name_index = load_int(symbol_addr + 0)
		int test_addr = load_int(symbol_addr + 4)
		char* name = string_addr + name_index
		if (starts_with(name, "test_")):
			println("")
			print("Run: '")
			print(name)
			print("()' -> ")
			print(hex(test_addr))
			println("")
			int* test_func = *test_addr

			print_hex("test_func: ", test_func)
			test_func()

			print("Test '")
			print(name)
			println("()' passed!")

		symbol_index = symbol_index + 1



int main(int argc, int argv):
	execute_tests()
	println("")
	println("All tests passed!")
	return 0


