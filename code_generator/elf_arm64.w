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


# Number of program headers: a read-execute text load, a read-write data
# load (W^X, Stage 3), and three reserved slots for future PT_INTERP /
# PT_DYNAMIC dynamic-linking records.
int elf_phdr_count_arm64():
	return 5


void elf_header_arm64():
	/* ElfHeader64: 48 bytes after the 16-byte ident */
	int header_size = 48 + 16
	int program_header_size = 56
	int section_header_size = 64
	emit_int16(2)   /* type: ET_EXEC */
	emit_int16(183) /* machine: EM_AARCH64 */
	emit_int32(1)   /* version */
	emit_int64(base_code_offset + header_size + program_header_size * elf_phdr_count_arm64()) /* entry */
	emit_int64(64)  /* program header offset */
	emit_int64(0)   /* section header offset */
	emit_int32(0)   /* flags */
	emit_int16(header_size)
	emit_int16(program_header_size)
	emit_int16(elf_phdr_count_arm64())   /* number of program headers */
	emit_int16(section_header_size)
	emit_int16(0)   /* number of section headers */
	emit_int16(0)   /* section header string table index */


# One 64-bit program header with an explicit flags field (RX text = 5,
# RW data = 6). offset/vaddr/filesz/memsz are patched in elf_finish_arm64.
void elf_phdr_arm64(int type, int flags):
	emit_int32(type)
	emit_int32(flags)
	emit_int64(0)                /* offset */
	emit_int64(base_code_offset) /* vaddr */
	emit_int64(base_code_offset) /* paddr */
	emit_int64(0)                /* filesz */
	emit_int64(0)                /* memsz */
	emit_int64(4096)             /* align */


# Codepos of the entry stub's `bl _main`, patched in elf_finish_arm64.
int arm64_entry_bl_pos

# Codepos of the 8-byte literal in the entry stub that holds the rebase
# table's linked vaddr; patched once the table's position is known
# (arm64_emit_rebase_table).
int arm64_rebase_lit_pos


# Entry-stub rebase walk (PIE groundwork, docs/projects/arm64.md D5).
# Computes the load slide as the difference between an adr's runtime
# result and its linked address (a plain constant in a literal pool, NOT
# a pointer, so it needs no rebasing itself), then adds the slide to
# every data cell listed in the compiler-built rebase table. Under the
# ET_EXEC ELF the slide is always 0, so the walk is exercised as a no-op;
# the Mach-O target is mandatorily PIE and relies on it. Clobbers x9-x13,
# which are scratch at process entry.
void arm64_entry_rebase_stub():
	a64(op(0x10, 0x000009))   # adr x9, .  (runtime address of this insn)
	int adr_vaddr = code_offset + codepos - 4
	a64(op(0x58, 0x00004a))   # ldr x10, [pc, #8]  (its linked address)
	a64(op(0x14, 0x000003))   # b .+12 (skip the 8-byte literal)
	emit_int64(adr_vaddr)
	a64(op(0xcb, 0x0a0129))   # sub x9, x9, x10  (x9 = slide)
	a64(op(0x58, 0x00004a))   # ldr x10, [pc, #8]  (linked table vaddr)
	a64(op(0x14, 0x000003))   # b .+12
	arm64_rebase_lit_pos = codepos
	emit_int64(0)             # patched in arm64_emit_rebase_table
	a64(op(0x8b, 0x09014a))   # add x10, x10, x9  (runtime table address)
	a64(op(0xf8, 0x40854b))   # ldr x11, [x10], #8  (entry count)
	# loop: add the slide to each listed cell's stored value
	a64(op(0xb4, 0x00010b))   # cbz x11, .+32 (done)
	a64(op(0xf8, 0x40854c))   # ldr x12, [x10], #8  (cell's linked vaddr)
	a64(op(0x8b, 0x09018c))   # add x12, x12, x9    (cell's runtime address)
	a64(op(0xf9, 0x40018d))   # ldr x13, [x12]
	a64(op(0x8b, 0x0901ad))   # add x13, x13, x9    (slide the pointer)
	a64(op(0xf9, 0x00018d))   # str x13, [x12]
	a64(op(0xd1, 0x00056b))   # sub x11, x11, #1
	a64(op(0x17, 0xfffff9))   # b .-28 (loop)


# Append the rebase table (count + one word per cell vaddr) to the data
# segment and point the entry stub's literal at it. Runs in the finish
# pass, after all code and data have been emitted.
void arm64_emit_rebase_table():
	int table_vaddr = data_offset + datapos
	emit_data_word(rebase_count)
	int r = 0
	while (r < rebase_count):
		emit_data_word(load_i(rebase_table + r * 8, 8))
		r = r + 1
	save_int64(code + arm64_rebase_lit_pos, table_vaddr)


void elf_start_arm64():
	base_code_offset = 134512640 /* 0x08048000 */
	code_offset = base_code_offset

	# The read-write data segment loads 16 MB above the image, clear of the
	# code + section tables (~1.5 MB). Global-variable storage is emitted
	# here (grammar/program.w define_global_variable) at data_offset+datapos.
	data_offset = base_code_offset + 16777216 /* +0x1000000 */
	datapos = 0
	data_size = 4096
	data = malloc(data_size)

	elf_header(2)
	elf_header_arm64()

	# phdr[0] text (R+X), phdr[1] data (R+W); the rest stay PT_NULL until
	# dynamic linking needs them.
	phdr_table_pos = codepos
	elf_phdr_arm64(1, 5)
	elf_phdr_arm64(0, 6)
	elf_phdr_arm64(0, 0)
	elf_phdr_arm64(0, 0)
	elf_phdr_arm64(0, 0)

	# Entry stub. The kernel enters with sp pointing at [argc][argv0]...;
	# adopt sp as the W stack, push &argv[0] so _main(argc, argv) sees argc
	# at the initial stack slot and argv one word above (matching the x86
	# entry). The rebase walk runs before _main so every recorded data
	# pointer is slid before user code reads it. bl _main sets x30, and
	# _main's prologue pushes it.
	a64(op(0x91, 0x0003fc))   # mov x28, sp
	a64(op(0x91, 0x002389))   # add x9, x28, #8   (&argv[0])
	a64(op(0xf8, 0x1f8f89))   # str x9, [x28, #-8]!
	arm64_entry_rebase_stub()
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

	# The rebase table lands at the end of the data segment, after every
	# data cell it lists has been reserved.
	arm64_emit_rebase_table()

	int t = sym_address(c"_main")
	if (t == 0):
		t = sym_address(c"main")
	if (t == 0):
		# 'w check' on a main-less library module: not an error, and the
		# entry bl stays unpatched (the output is discarded)
		if (entry_optional == 0):
			error(c"Failed to find a _main() function. Did you import lib/testing?")

	if (t != 0):
		# Patch the bl: imm26 = (target - bl_vaddr) / 4.
		int bl_vaddr = code_offset + arm64_entry_bl_pos
		int offset = t - bl_vaddr
		save_int32(code + arm64_entry_bl_pos, op(0x94, 0x000000) | ((offset >> 2) & op(0x03, 0xffffff)))

	# Text segment (phdr[0], R+X): offset 0, vaddr base, size = codepos.
	save_int64(code + phdr_table_pos + 32, codepos)   /* p_filesz */
	save_int64(code + phdr_table_pos + 40, codepos)   /* p_memsz */

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
