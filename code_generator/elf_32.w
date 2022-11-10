import code_generator.code_emitter
import code_generator.elf_all


int sym_address(char *s);  /* from symbol_table.w */


void elf_header_32():
	/* ElfHeader32: 36 bytes */
	int header_size = 36 + 16
	int program_header_size = 32
	int section_header_size = 40
	emit_int16(2) /* type */
	emit_int16(3)  /* machine */
	emit_int(1) /* version */
	emit_int(base_code_offset + header_size + program_header_size) /* entry */
	emit_int(header_size) /* program header offset */
	emit_int(0) /* segment header offset */
	emit_int(0) /* flags */
	emit_int16(header_size) /* size of this elf header */
	emit_int16(program_header_size) /* size per program header */
	emit_int16(1) /* number of program headers */
	emit_int16(section_header_size) /* size per section header  */
	emit_int16(0) /* number of section headers */
	emit_int16(0) /* section header string table index */


/* ProgramHeader32: 32 bytes */
void elf_program_header(int type):
	emit_int(type) /* type: 0: NULL, 1: LOAD, 2: DYNAMIC, ... */
	emit_int(0) /* offset: where in the elf file the content of this segment is located */
	emit_int(base_code_offset) /* vaddr: where first byte will be in memory */
	emit_int(base_code_offset) /* paddr: physical memory address, not usually used (e.g. firmware) */
	emit_int(0) /* filesz: size of segment in file, 0=no content OVERWRITTEN in be_finish() */
	emit_int(0) /* memsz: size of the segment in memory OVERWRITTEN in be_finish() */
	emit_int(7) /* flags: X, W, R */
	emit_int(4096) /* align: byte boundary e.g. 1/2/4/8/16/32/64/128/256/512/1024/2048/4096 */


/* SectionHeader32: 40 bytes */
void elf_section_header(int type):
	emit_int(0) /* name: string index */
	emit_int(type) /* type: 2: sym_table, 3: string table */
	emit_int(0) /* flags: 0x1: write, 0x2: alloc, 0x4: exec */
	emit_int(0) /* addr */
	emit_int(0) /* offset */
	emit_int(0) /* size */
	emit_int(1) /* link: strings section that we're linked with */
	emit_int(0) /* info (num symbols in symtable, etc.) */
	emit_int(1) /* addralign (1,2,4,8,16,32 typically used) */
	emit_int(16) /* entry size */
	/* # entries = size / entry size */


/* SymbolTableEntry32: 16 bytes */
void elf_sym_table_entry(int name, int address, int size, int binding, int symtype, int type):
	emit_int(name) /* name */
	emit_int(address) /* address */
	emit_int(size) /* size */
	/* binding: 0:local, 1:global, 2:weak */
	/* symtype: 0:none, 1:object, 2:func, ... */
	int info = (binding << 4) + (symtype & 15)
	emit_int8(info) /* info */
	emit_int8(0) /* other: visibility */
	emit_int16(type) /* shndx: index into section header table */



void elf_start():
	base_code_offset = 134512640 /* 0x08048000 */
	code_offset = base_code_offset

	/* ELF Header: 52 bytes */
	elf_header(1)
	elf_header_32()

	elf_program_header(1)

	/* setup command line args */
	emit(5, "\x8d\x44\x24\x04\x50")
	/* lea eax, [esp+4]; push eax */

	emit(5, "\xe8....")
	/* call [first function ] - set with the save_int() at the end of this func */

	define_asm_functions()


void elf_finish():
	if (verbosity > 0):
		print_error("codepos: '")
		print_error(hex(codepos))
		print_error("'\x0a")

	# Store pointer to library _main()
	int t = sym_address("_main")
	# As a backup, try to use main()
	# TODO: should we allow this?
	if (t == 0):
		t = sym_address("main")
	if (t == 0):
		error("Failed to find a _main() function. Did you import lib/testing?")
	# TODO: fix the asm so it does not crash on return
	t = t - code_offset - 94

	if (verbosity >= 1):
		print_error("looking up _main() t = ")
		print_error(itoa(t))
		print_error("\x0aold start = ")
		print_error(itoa(load_int(code + 90)))
		print_error("\x0a")

	save_int(code + 90, t)

	# Save the size
	save_int(code + 68, codepos) /* FileSize */
	save_int(code + 72, codepos) /* MemSize */

	write(1, code, codepos)


void elf_save_section_info_32(int header_addr, int num_sections, int string_index):
	save_int(code + 32, header_addr)
	save_i(code + 48, 3, 2) /* number of section headers */
	save_i(code + 50, 1, 2) /* string index */
