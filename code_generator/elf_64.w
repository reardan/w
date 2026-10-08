import code_generator.code_emitter
import code_generator.elf_all
import code_generator.x64_asm


int sym_address(char *s);  /* from symbol_table.w */
void elf_emit_dynamic();   /* from elf_dynamic.w */


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


# Static PIE startup: rdx = load bias, rsi = table, rcx = count.
# Dynamic PIE uses loader RELATIVE relocations; its table count is zero.
int x64_rebase_table_disp


void x64_entry_rebase_stub():
	emit(7, c"\x48\x8d\x15\x00\x00\x00\x00") /* lea rdx,[rip] */
	int linked_pc = code_offset + codepos
	emit(3, c"\x48\x81\xea") /* sub rdx,linked_pc */
	emit_int32(linked_pc)
	emit(7, c"\x48\x8d\x35....") /* lea rsi,[rip+table] */
	x64_rebase_table_disp = codepos - 4
	emit(7, c"\x48\x8b\x0e\x48\x83\xc6\x08") /* count; advance */
	emit(5, c"\x48\x85\xc9\x74\x12") /* test rcx; jz done */
	emit(3, c"\x48\x8b\x06") /* loop: mov rax,[rsi] */
	emit(3, c"\x48\x01\xd0") /* add rax,rdx */
	emit(3, c"\x48\x01\x10") /* add [rax],rdx */
	emit(4, c"\x48\x83\xc6\x08")
	emit(3, c"\x48\xff\xc9")
	emit(2, c"\x75\xee") /* jnz loop */


void x64_emit_rebase_table():
	int table = data_offset + datapos
	int count = rebase_count
	if (dyn_has_imports()): count = 0
	emit_data_word(count)
	for r in range(count): emit_data_word(load_i(rebase_table + r * 8, 8))
	save_int32(code + x64_rebase_table_disp, table - code_offset - x64_rebase_table_disp - 4)


void elf_start_64():
	elf_image_headers(62, 1)
	if (elf_pie): x64_entry_rebase_stub()

	/* setup command line args */
	emit(6, c"\x48\x8d\x44\x24\x08\x50")
	/* lea rax, [rsp+8]; push rax */

	emit(5, c"\xe8....")
	/* call [first function ] - set with the save_int() at the end of this func */
	entry_call_disp_pos = codepos - 4

	/* exit cleanly if _main returns: mov edi,eax ; mov eax,231 (exit_group) ; syscall */
	emit(7, c"\x89\xc7\xb8\xe7\x00\x00\x00")
	x64_runtime_syscall()

	define_asm_functions_x64()


void elf_finish_64():
	elf_finish_entry_patch()
	if (x64_syscall_abi):
		save_int32(code + elf_hypercall_note_pos + 20, x64_hypercall_count)
		for i in range(x64_hypercall_count):
			save_int64(code + elf_hypercall_note_pos + 24 + i * 8, code_offset + x64_hypercall_sites[i])
	if (elf_pie): x64_emit_rebase_table()
	elf_patch_load_segments(1)


void elf_save_section_info_64(int header_addr, int num_sections, int string_index):
	save_int64(code + debug_elf_origin + 40, header_addr - debug_elf_origin) /* e_shoff */
	save_i(code + debug_elf_origin + 60, num_sections, 2) /* e_shnum */
	save_i(code + debug_elf_origin + 62, string_index, 2) /* e_shstrndx */
