import code_generator.code_emitter
import code_generator.elf_all
import code_generator.x64_asm


int sym_address(char *s);  /* from symbol_table.w */
void elf_emit_dynamic();   /* from elf_dynamic.w */


# Number of program headers: a read-execute text load, a read-write data
# load (W^X, docs/projects/wx_split.md Stage B), and three slots reserved
# for PT_INTERP / PT_DYNAMIC when the program imports shared libraries;
# they stay PT_NULL (ignored) otherwise.
int elf_phdr_count_64():
	return 5


void elf_header_64():
	/* ElfHeader64: 48 bytes */
	int header_size = 48 + 16
	int program_header_size = 56
	int section_header_size = 64
	emit_int16(2) /* type */
	emit_int16(62)  /* machine  3:x86, 62: x64, ?:ARM */
	emit_int32(1) /* version */
	emit_int64(base_code_offset + header_size + program_header_size * elf_phdr_count_64()) /* entry */
	emit_int64(64) /* program header offset */
	emit_int64(0) /* segment header offset */
	emit_int32(0) /* flags */
	emit_int16(header_size) /* size of this elf header */
	emit_int16(program_header_size) /* size per program header */
	emit_int16(elf_phdr_count_64()) /* number of program headers */
	emit_int16(section_header_size) /* size per section header  */
	emit_int16(0) /* number of section headers */
	emit_int16(0) /* section header string table index */


/* ProgramHeader64: 56 bytes. flags: RX text = 5, RW data = 6. */
void elf_program_header_64(int type, int flags):
	emit_int32(type) /* type: 0: NULL, 1: LOAD, 2: DYNAMIC, ... */
	emit_int32(flags) /* flags: 0x4: R, 0x2: W, 0x1: X */
	emit_int64(0) /* offset: where in the elf file the content of this segment is located */
	emit_int64(base_code_offset) /* vaddr: where first byte will be in memory */
	emit_int64(base_code_offset) /* paddr: physical memory address, not usually used (e.g. firmware) */
	emit_int64(0) /* filesz: size of segment in file, 0=no content OVERWRITTEN in be_finish() */
	emit_int64(0) /* memsz: size of the segment in memory OVERWRITTEN in be_finish() */
	emit_int64(4096) /* align: byte boundary e.g. 1/2/4/8/16/32/64/128/256/512/1024/2048/4096 */


/* SectionHeader64: 64 bytes */
void elf_section_header_64(int type):
	emit_int32(0) /* name: string index */
	emit_int32(type) /* type: 2: sym_table, 3: string table */
	emit_int64(0) /* flags: 0x1: write, 0x2: alloc, 0x4: exec */
	emit_int64(0) /* addr */
	emit_int64(0) /* offset */
	emit_int64(0) /* size */
	emit_int32(1) /* link: strings section that we're linked with */
	emit_int32(0) /* info (num symbols in symtable, etc.) */
	emit_int64(1) /* addralign (1,2,4,8,16,32 typically used) */
	emit_int64(24) /* entry size */
	/* # entries = size / entry size */


/* SymbolTableEntry64: 24 bytes */
void elf_sym_table_entry_64(int name, int address, int size, int binding, int symtype, int type):
	emit_int32(name) /* name */
	/* binding: 0:local, 1:global, 2:weak */
	/* symtype: 0:none, 1:object, 2:func, ... */
	int info = (binding << 4) + (symtype & 15)
	emit_int8(info) /* info */
	emit_int8(0) /* other: visibility */
	emit_int16(type) /* shndx: index into section header table */
	emit_int64(address) /* address */
	emit_int64(size) /* size */


void elf_start_64():
	base_code_offset = 134512640 /* 0x08048000 */
	code_offset = base_code_offset

	# The read-write data segment loads 16 MB above the image, clear of the
	# code + section tables (~1.5 MB). Mutable globals, GOT slots and
	# extern-data copy space are emitted here (data_split, set by the x64
	# selector) at data_offset+datapos, mirroring elf_arm64.w.
	data_offset = base_code_offset + 16777216 /* +0x1000000 */
	datapos = 0
	data_size = 4096
	data = malloc(data_size)

	/* ELF Header: 88 bytes */
	elf_header(2)
	elf_header_64()

	# phdr[0] text (R+X), phdr[1] data (R+W, patched in elf_finish_64);
	# the rest start as PT_NULL and are filled in by elf_emit_dynamic()
	# when there are imports.
	phdr_table_pos = codepos
	elf_program_header_64(1, 5)
	elf_program_header_64(0, 6)
	elf_program_header_64(0, 0)
	elf_program_header_64(0, 0)
	elf_program_header_64(0, 0)

	/* setup command line args */
	emit(6, c"\x48\x8d\x44\x24\x08\x50")
	/* lea rax, [rsp+8]; push rax */

	emit(5, c"\xe8....")
	/* call [first function ] - set with the save_int() at the end of this func */
	entry_call_disp_pos = codepos - 4

	/* exit cleanly if _main returns: mov edi,eax ; mov eax,231 (exit_group) ; syscall */
	emit(9, c"\x89\xc7\xb8\xe7\x00\x00\x00\x0f\x05")

	define_asm_functions_x64()


void elf_finish_64():
	elf_finish_entry_patch()

	# Text segment (phdr[0], R+X): offset 0, vaddr base, size = codepos.
	save_int64(code + phdr_table_pos + 32, codepos) /* p_filesz */
	save_int64(code + phdr_table_pos + 40, codepos) /* p_memsz */

	if (datapos > 0):
		# Place the data segment on its own file page after the code; its
		# vaddr (data_offset) is already page-aligned and 16 MB above base,
		# so (vaddr - file_offset) stays page-congruent as the loader
		# requires. phdr[1] is the R+W data load.
		int data_file_off = (codepos + 4095) & (0 - 4096)
		int p = phdr_table_pos + 56
		save_int32(code + p + 0, 1)              /* p_type = PT_LOAD */
		save_int64(code + p + 8, data_file_off)  /* p_offset */
		save_int64(code + p + 16, data_offset)   /* p_vaddr */
		save_int64(code + p + 24, data_offset)   /* p_paddr */
		save_int64(code + p + 32, datapos)       /* p_filesz */
		save_int64(code + p + 40, datapos)       /* p_memsz */
		# Pad the file to the data segment's page offset, then write code
		# and data as two segments in one file.
		while (codepos < data_file_off):
			emit_int8(0)
		if (write(output_fd, code, codepos) != codepos):
			error(c"could not write output file")
		if (write(output_fd, data, datapos) != datapos):
			error(c"could not write output file")
	else:
		if (write(output_fd, code, codepos) != codepos):
			error(c"could not write output file")


void elf_save_section_info_64(int header_addr, int num_sections, int string_index):
	save_int64(code + 40, header_addr) /* e_shoff */
	save_i(code + 60, num_sections, 2) /* e_shnum */
	save_i(code + 62, string_index, 2) /* e_shstrndx */
