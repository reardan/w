/*
AArch64 static-ELF writer, the twin of code_generator/elf_64.w. Same ELF64
container (class 2, one PT_LOAD covering the image, three reserved program
headers for optional dynamic sections) with e_machine = 183 (EM_AARCH64) and
an A64 entry stub.

The base address, program-header layout and finish-time patching all match
elf_64.w so the symbol-table / DWARF emitter and the test harness
(lib.testing, which hardcodes the load base) work unchanged across targets.
*/
import code_generator.code_emitter
import code_generator.elf_all


int sym_address(char *s);            /* symbol_table.w */
void elf_emit_dynamic();             /* elf_dynamic.w */
void elf_program_header_64(int t);   /* elf_64.w */
void define_asm_functions_arm64();   /* arm64_asm.w */
void a64(int w);                     /* arm64.w */


void elf_header_arm64():
	/* ElfHeader64: 48 bytes after the 16-byte ident */
	int header_size = 48 + 16
	int program_header_size = 56
	int section_header_size = 64
	emit_int16(2)   /* type: ET_EXEC */
	emit_int16(183) /* machine: EM_AARCH64 */
	emit_int32(1)   /* version */
	emit_int64(base_code_offset + header_size + program_header_size * 4) /* entry */
	emit_int64(64)  /* program header offset */
	emit_int64(0)   /* section header offset */
	emit_int32(0)   /* flags */
	emit_int16(header_size)
	emit_int16(program_header_size)
	emit_int16(4)   /* number of program headers */
	emit_int16(section_header_size)
	emit_int16(0)   /* number of section headers */
	emit_int16(0)   /* section header string table index */


# Codepos of the entry stub's `bl _main`, patched in elf_finish_arm64.
int arm64_entry_bl_pos


void elf_start_arm64():
	base_code_offset = 134512640 /* op(0x08, 0x048000) */
	code_offset = base_code_offset

	elf_header(2)
	elf_header_arm64()

	# PT_LOAD covers the whole image; the rest start as PT_NULL and are
	# filled in by elf_emit_dynamic() when there are imports.
	phdr_table_pos = codepos
	elf_program_header_64(1)
	elf_program_header_64(0)
	elf_program_header_64(0)
	elf_program_header_64(0)

	# Entry stub. The kernel enters with sp pointing at [argc][argv0]...;
	# adopt sp as the W stack, push &argv[0] so _main(argc, argv) sees argc
	# at the initial stack slot and argv one word above (matching the x86
	# entry). bl _main sets x30, and _main's prologue pushes it.
	a64(op(0x91, 0x0003fc))   # mov x28, sp
	a64(op(0x91, 0x002389))   # add x9, x28, #8   (&argv[0])
	a64(op(0xf8, 0x1f8f89))   # str x9, [x28, #-8]!
	arm64_entry_bl_pos = codepos
	a64(op(0x94, 0x000000))   # bl _main  (offset patched in finish)
	# exit_group(_main's return value) if it ever returns.
	a64(op(0xd2, 0x800bc8))   # movz x8, #94
	a64(op(0xd4, 0x000001))   # svc #0

	define_asm_functions_arm64()


void elf_finish_arm64():
	if (verbosity > 0):
		print_error(c"codepos: '")
		print_error(hex(codepos))
		print_error(c"'\x0a")

	# Append .interp/.dynamic/relocations if the program imported anything;
	# a no-op otherwise.
	elf_emit_dynamic()

	int t = sym_address(c"_main")
	if (t == 0):
		t = sym_address(c"main")
	if (t == 0):
		error(c"Failed to find a _main() function. Did you import lib/testing?")

	# Patch the bl: imm26 = (target - bl_vaddr) / 4.
	int bl_vaddr = code_offset + arm64_entry_bl_pos
	int offset = t - bl_vaddr
	save_int32(code + arm64_entry_bl_pos, op(0x94, 0x000000) | ((offset >> 2) & op(0x03, 0xffffff)))

	# PT_LOAD p_filesz / p_memsz (same 64-bit phdr layout as elf_64.w).
	save_int64(code + phdr_table_pos + 32, codepos)
	save_int64(code + phdr_table_pos + 40, codepos)

	write(output_fd, code, codepos)
