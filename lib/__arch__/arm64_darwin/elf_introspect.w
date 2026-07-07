# Introspection stub for the arm64_darwin target: the binary is a Mach-O,
# not an ELF, so the ELF64 walk lib/testing.w does has nothing to read.
# Same function surface as lib/__arch__/arm64/elf_introspect.w with
# not-found/zero results: the section count of 0 means the test harness's
# section loop never runs and its "No symbol table" assert reports the
# missing support loudly instead of reading wild memory. A Mach-O symbol
# table walk replaces this in a later Stage 4 step.
import code_generator.integer


int elf_section_header_offset(int base):
	return 0


int elf_section_header_size(int base):
	return 0


int elf_section_header_count(int base):
	return 0


int elf_section_type(int header):
	return 0


int elf_section_addr(int header):
	return 0


int elf_section_size(int header):
	return 0


int elf_symbol_entry_size():
	return 24 /* keep the divisor nonzero for any caller that divides */


int elf_symbol_name_index(int entry):
	return 0


int elf_symbol_value(int entry):
	return 0
