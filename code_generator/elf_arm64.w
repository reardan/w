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
void define_asm_functions_arm64();   /* arm64_asm.w */
void a64(int w);                     /* arm64.w */


# Codepos of the entry stub's `bl _main`, patched in elf_finish_arm64
# and macho_finish_arm64.
int arm64_entry_bl_pos


# Patch the entry stub's bl to target t (0: no entry, left unpatched):
# imm26 = (target - bl_vaddr) / 4.
void arm64_patch_entry_bl(int t):
	if (t != 0):
		int offset = t - (code_offset + arm64_entry_bl_pos)
		save_int32(code + arm64_entry_bl_pos, op(0x94, 0x000000) | ((offset >> 2) & op(0x03, 0xffffff)))

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
	elf_image_headers(183, 1)

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

	arm64_patch_entry_bl(entry_symbol(0))
	elf_patch_load_segments(1)
