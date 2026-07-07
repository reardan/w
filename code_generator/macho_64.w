/*
Mach-O (Darwin) container writer for the arm64_darwin target — Stage 4 of
docs/projects/arm64.md. This is the placeholder half: macho_start_arm64
mirrors elf_start_arm64's buffer/vaddr setup so the whole compiler pipeline
(imports, lib/, codegen, the W^X data split) runs end to end for the new
target, and macho_finish_arm64 fails with a clear error until the real
MH_EXECUTE + LC_UNIXTHREAD writer lands.
*/
import code_generator.code_emitter


void error(char *s);                 /* diagnostics.w */
void define_asm_functions_arm64();   /* arm64_asm.w */
void a64(int w);                     /* arm64.w */
void arm64_entry_rebase_stub();      /* elf_arm64.w */


void macho_start_arm64():
	# Same image layout the arm64 ELF writer uses, so symbol addressing
	# and the data split behave identically while the container is a
	# placeholder. The real Mach-O writer rebases to 0x100000000 (past
	# __PAGEZERO) and emits the load commands here.
	base_code_offset = 134512640 /* 0x08048000 */
	code_offset = base_code_offset

	# The read-write data segment loads 16 MB above the image, matching
	# elf_start_arm64; global-variable storage is emitted here.
	data_offset = base_code_offset + 16777216 /* +0x1000000 */
	datapos = 0
	data_size = 4096
	data = malloc(data_size)

	# Entry stub, identical to the arm64 ELF one for now (the Darwin
	# initial stack layout and exit syscall differ; the real writer
	# replaces this). The rebase walk is mandatory on Darwin: the kernel
	# slides the PIE image and nothing else applies rebases. The finish
	# pass must call arm64_emit_rebase_table() to place the table and
	# patch the stub's literal. bl _main's offset is patched in finish.
	a64(op(0x91, 0x0003fc))   # mov x28, sp
	a64(op(0x91, 0x002389))   # add x9, x28, #8   (&argv[0])
	a64(op(0xf8, 0x1f8f89))   # str x9, [x28, #-8]!
	arm64_entry_rebase_stub()
	arm64_entry_bl_pos = codepos
	a64(op(0x94, 0x000000))   # bl _main  (offset patched in finish)
	# exit(_main's return value) if it ever returns: Darwin exit is BSD
	# syscall 1, number in x16, svc #0x80.
	a64(op(0xd2, 0x800030))   # movz x16, #1
	a64(op(0xd4, 0x001001))   # svc #0x80

	define_asm_functions_arm64()


void macho_finish_arm64():
	error(c"arm64_darwin: Mach-O writer not implemented yet")
