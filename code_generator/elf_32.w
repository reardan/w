import code_generator.code_emitter
import code_generator.elf_all


int sym_address(char *s);  /* from symbol_table.w */
void elf_emit_dynamic();   /* from elf_dynamic.w */


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
	elf_image_headers(3, 0)

	/* setup command line args */
	emit(5, c"\x8d\x44\x24\x04\x50")
	/* lea eax, [esp+4]; push eax */

	emit(5, c"\xe8....")
	/* call [first function ] - set with the save_int() at the end of this func */
	entry_call_disp_pos = codepos - 4

	/* exit cleanly if _main returns: mov ebx,eax ; mov eax,252 (exit_group) ; int 0x80 */
	emit(9, c"\x89\xc3\xb8\xfc\x00\x00\x00\xcd\x80")

	define_asm_functions()


# Thread-local storage (docs/projects/thread_local.md): once every
# thread_local is declared, patch the final block size into the
# __w_tls_size stub, reserve the main thread's block in the data segment
# and emit the entry thunk the entry stub calls instead of _main:
#	push block ; call __w_tls_set ; add esp,word ; jmp _main
# The jmp keeps the entry stub's return address and argument in place,
# so _main sees exactly the frame it would have without the thunk.
# Returns the thunk's address for the entry call patch.
int elf_emit_tls_entry_thunk(int main_addr):
	if (tls_size > 1048576):
		error(c"thread_local storage exceeds 1MB")
	if (tls_size_patch_pos == 0):
		error(c"thread_local: no __w_tls_size stub on this target")
	tls_size = (tls_size + 15) & (0 - 16)
	save_int32(code + tls_size_patch_pos, tls_size)
	while ((datapos & 15) != 0):
		emit_data_zeros(1)
	int block = emit_data_zeros(tls_size)
	int set_addr = sym_address(c"__w_tls_set")
	int thunk = code_offset + codepos
	emit(1, c"\x68")  /* push imm32 */
	emit_int(0)
	save_int32(code + codepos - 4, block)
	emit(1, c"\xe8")  /* call __w_tls_set */
	emit_int(0)
	save_int32(code + codepos - 4, set_addr - code_offset - codepos)
	if (word_size == 8):
		emit(4, c"\x48\x83\xc4\x08")  /* add rsp,8 */
	else:
		emit(3, c"\x83\xc4\x04")  /* add esp,4 */
	emit(1, c"\xe9")  /* jmp _main */
	emit_int(0)
	save_int32(code + codepos - 4, main_addr - code_offset - codepos)
	return thunk


# Shared elf_finish head for the 32- and 64-bit writers: the codepos
# trace, the dynamic-section append, and the entry-point call patch
# (rel32 to _main, falling back to main). The width-specific PT_LOAD
# size saves stay in each writer.
void elf_finish_entry_patch():
	if (verbosity > 0):
		print_error(c"codepos: '")
		print_error(hex(codepos))
		print_error(c"'\x0a")

	# Append .interp/.dynamic/relocations and fill the reserved program
	# headers; a no-op when nothing was imported with c_lib/extern.
	elf_emit_dynamic()

	int t = entry_symbol(0)
	if (t == 0):
		return
	if (tls_size > 0):
		t = elf_emit_tls_entry_thunk(t)
	# rel32 = target - address of the instruction after the 5-byte call
	t = t - code_offset - entry_call_disp_pos - 4

	save_int32(code + entry_call_disp_pos, t)


void elf_finish():
	elf_finish_entry_patch()
	elf_patch_load_segments(0)


void elf_save_section_info_32(int header_addr, int num_sections, int string_index):
	save_int(code + 32, header_addr)
	save_i(code + 48, num_sections, 2) /* number of section headers */
	save_i(code + 50, string_index, 2) /* string index */
