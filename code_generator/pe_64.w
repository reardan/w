/*
PE32+ container for the win64 target (docs/projects/windows.md).

Layout keeps W's absolute-address model intact: ImageBase is the fixed
0x400000, relocations are stripped and ASLR stays off, and section
alignment equals file alignment (0x1000), so every RVA equals its file
offset and a buffer position p lives at vaddr code_offset + p -- the same
single-buffer scheme the ELF writers use with 0x08048000.

Windows has no stable raw-syscall ABI, so even trivial programs need the
import table: OS services arrive through kernel32.dll imports declared
with c_lib/extern in lib/__arch__/win64/syscalls.w. Each import's inline
slot (dyn_emit_import_slot) is its own one-entry IAT; pe_emit_imports()
points one import descriptor per import at it, so the scattered slots
never need to be contiguous.

The image is a single RWX .text section, matching the single RWX PT_LOAD
the Linux x86/x64 targets use. Stack commit equals the 8MB reserve so
large W frames never need __chkstk-style stack probes.
*/
import code_generator.code_emitter
import code_generator.integer
import code_generator.x64_asm
import code_generator.dynamic_registry
import lib.lib


int sym_address(char *s);  /* from symbol_table.w */
void error(char *s);       /* from diagnostics.w */


# File positions of the optional header and the .text section header,
# recorded at start time so the finish pass can patch sizes and the
# import directory without hardcoded offsets.
int pe_opt_header_pos
int pe_section_header_pos

# Vaddrs of the entry stub's support data: the empty argv/env block the
# stub passes when no runtime startup takes over, and the ExitProcess
# import slot the stub calls through when the entry function returns.
int pe_empty_args_vaddr
int pe_exit_process_slot


int pe_image_base():
	return 4194304 /* 0x00400000 */


int pe_file_align():
	return 4096


void pe_align(int a):
	while ((codepos % a) != 0):
		emit_int8(0)


# IMAGE_DOS_HEADER: only e_magic and e_lfanew matter to the loader; the
# real-mode stub program is omitted (e_lfanew points at byte 64).
void pe_dos_header():
	emit(2, c"MZ")
	emit_zeros(58)
	emit_int32(64) /* e_lfanew: file offset of the PE signature */


# PE signature + IMAGE_FILE_HEADER (COFF).
void pe_coff_header():
	emit(4, c"PE\x00\x00")
	emit_int16(34404) /* machine: 0x8664 x86-64 */
	emit_int16(1) /* number of sections */
	emit_int32(0) /* time date stamp */
	emit_int32(0) /* pointer to symbol table (deprecated) */
	emit_int32(0) /* number of symbols (deprecated) */
	emit_int16(240) /* size of optional header (PE32+) */
	# characteristics: 0x1 RELOCS_STRIPPED | 0x2 EXECUTABLE_IMAGE. Not
	# LARGE_ADDRESS_AWARE, so the loader keeps every user address below
	# 2GB -- the same low-address world the fixed ELF base gives us.
	emit_int16(3)


# IMAGE_OPTIONAL_HEADER64 (240 bytes with 16 data directories). Size
# fields are patched by pe_finish_64(); everything else is final.
void pe_optional_header():
	emit_int16(523) /* magic: 0x20b PE32+ */
	emit_int8(0) /* major linker version */
	emit_int8(0) /* minor linker version */
	emit_int32(0) /* size of code OVERWRITTEN in pe_finish_64() */
	emit_int32(0) /* size of initialized data */
	emit_int32(0) /* size of uninitialized data */
	emit_int32(0) /* address of entry point OVERWRITTEN below in pe_start_64() */
	emit_int32(4096) /* base of code */
	emit_int64(pe_image_base()) /* image base */
	emit_int32(4096) /* section alignment */
	emit_int32(4096) /* file alignment: equal, so RVA == file offset */
	emit_int16(6) /* major OS version (Vista+) */
	emit_int16(0) /* minor OS version */
	emit_int16(0) /* major image version */
	emit_int16(0) /* minor image version */
	emit_int16(6) /* major subsystem version */
	emit_int16(0) /* minor subsystem version */
	emit_int32(0) /* win32 version (reserved) */
	emit_int32(0) /* size of image OVERWRITTEN in pe_finish_64() */
	emit_int32(4096) /* size of headers */
	emit_int32(0) /* checksum (only required for drivers) */
	emit_int16(3) /* subsystem: console */
	emit_int16(0) /* dll characteristics: no dynamic base, image loads at ImageBase */
	emit_int64(8388608) /* stack reserve: 8MB */
	emit_int64(8388608) /* stack commit == reserve: no stack probes needed */
	emit_int64(1048576) /* heap reserve */
	emit_int64(4096) /* heap commit */
	emit_int32(0) /* loader flags (reserved) */
	emit_int32(16) /* number of data directories */
	# 16 data directories (RVA, size); entry 1 (import table) is patched
	# by pe_emit_imports(), the rest stay empty.
	emit_zeros(128)


# IMAGE_SECTION_HEADER for the single RWX .text section covering
# everything after the headers. Sizes are patched by pe_finish_64().
void pe_section_header():
	emit(6, c".text\x00")
	emit_zeros(2) /* name padding to 8 bytes */
	emit_int32(0) /* virtual size OVERWRITTEN in pe_finish_64() */
	emit_int32(4096) /* virtual address (RVA) */
	emit_int32(0) /* size of raw data OVERWRITTEN in pe_finish_64() */
	emit_int32(4096) /* pointer to raw data */
	emit_int32(0) /* pointer to relocations */
	emit_int32(0) /* pointer to line numbers */
	emit_int16(0) /* number of relocations */
	emit_int16(0) /* number of line numbers */
	# characteristics: 0x20 CODE | 0x40 INITIALIZED_DATA
	# | 0x20000000 EXECUTE | 0x40000000 READ | 0x80000000 WRITE
	emit_int32(-536870816) /* 0xE0000060 as a signed 32-bit value */


void pe_start_64():
	base_code_offset = pe_image_base()
	code_offset = base_code_offset

	pe_dos_header()
	pe_coff_header()
	pe_opt_header_pos = codepos
	pe_optional_header()
	pe_section_header_pos = codepos
	pe_section_header()
	pe_align(4096) /* headers occupy the first page; .text starts at RVA 0x1000 */

	# Support data for the entry stub. The empty args block serves as
	# argv when no runtime startup takes over: argv[0] = 0 terminates the
	# argument vector and the following zero word is an empty environment
	# vector for lib.w's environ_ptr = argv + (argc + 1) * word_size.
	pe_empty_args_vaddr = code_offset + codepos
	emit_int64(0)
	emit_int64(0)

	# ExitProcess import for the entry stub; the win64 runtime library
	# registers its own kernel32 imports through c_lib/extern.
	dyn_add_lib(c"kernel32.dll")
	pe_exit_process_slot = dyn_emit_import_slot()
	dyn_add_import(c"ExitProcess", pe_exit_process_slot)

	# Entry stub. The loader calls AddressOfEntryPoint with no arguments,
	# so the stub materializes the W entry contract (argc, argv pushed
	# with argv on top) with argc = 0 and the empty block, then calls the
	# entry function pe_finish_64() selects. lib/__arch__/win64/syscalls.w
	# provides _win_start, which rebuilds real argc/argv from
	# GetCommandLineA before chaining to _main.
	save_i(code + pe_opt_header_pos + 16, codepos, 4) /* AddressOfEntryPoint */
	emit(2, c"\x31\xc0") /* xor eax,eax */
	emit(1, c"\x50") /* push rax: argc = 0 */
	emit(1, c"\x68") /* push imm32: argv = empty args block */
	emit_int32(pe_empty_args_vaddr)
	emit(5, c"\xe8....") /* call [entry function], patched in pe_finish_64() */
	entry_call_disp_pos = codepos - 4
	/* if the entry function returns, its result is the exit code */
	emit(2, c"\x89\xc1") /* mov ecx,eax */
	emit(4, c"\x48\x83\xec\x28") /* sub rsp,40: shadow space + alignment */
	emit(3, c"\xff\x14\x25") /* call qword ptr [abs32] */
	emit_int32(pe_exit_process_slot)
	emit(1, c"\xcc") /* int3: ExitProcess never returns */

	define_asm_functions_x64_portable()


/*
Import tables, drained from the shared dynamic registry at finish time.

Every import already owns an 8-byte slot inside the code image (emitted
inline next to its shim by dyn_emit_import_slot, followed by a zero
terminator word), and all emitted code reaches the function through that
slot. Those slots are scattered between shims, so instead of one
descriptor per DLL with a contiguous IAT, one IMAGE_IMPORT_DESCRIPTOR is
emitted per import whose FirstThunk points at the import's own slot and
whose lookup table holds that single name. Loaders resolve duplicate DLL
names from the module cache, so repeating kernel32.dll per import only
costs a few bytes of directory.
*/
void pe_emit_imports():
	if (dyn_import_count == 0):
		return

	# Hint/name entries (2-byte hint + NUL-terminated name, 2-aligned).
	char* hint_rvas = malloc(dyn_import_count * 4)
	int i = 0
	while (i < dyn_import_count):
		pe_align(2)
		save_int(hint_rvas + i * 4, codepos)
		emit_int16(0) /* hint: 0 forces lookup by name */
		emit_string(dyn_import_name(i))
		i = i + 1

	# DLL name strings.
	char* lib_rvas = malloc(dyn_lib_count * 4)
	i = 0
	while (i < dyn_lib_count):
		save_int(lib_rvas + i * 4, codepos)
		emit_string(dyn_lib_name(i))
		i = i + 1

	# Import lookup tables: one two-entry (name RVA, terminator) table
	# per import, matching its one-entry FirstThunk slot.
	pe_align(8)
	char* ilt_rvas = malloc(dyn_import_count * 4)
	i = 0
	while (i < dyn_import_count):
		save_int(ilt_rvas + i * 4, codepos)
		emit_int64(load_int(hint_rvas + i * 4))
		emit_int64(0)
		i = i + 1

	# Import directory table: one descriptor per import plus the all-zero
	# terminator.
	pe_align(4)
	int idt_rva = codepos
	i = 0
	while (i < dyn_import_count):
		int lib = dyn_import_get_lib(i)
		if (lib < 0):
			error(c"extern import declared before any c_lib")
		emit_int32(load_int(ilt_rvas + i * 4)) /* OriginalFirstThunk */
		emit_int32(0) /* time date stamp */
		emit_int32(0) /* forwarder chain */
		emit_int32(load_int(lib_rvas + lib * 4)) /* name */
		emit_int32(dyn_import_got_vaddr(i) - code_offset) /* FirstThunk */
		i = i + 1
	emit_zeros(20)

	# Data directory entry 1: import table.
	save_i(code + pe_opt_header_pos + 120, idt_rva, 4)
	save_i(code + pe_opt_header_pos + 124, codepos - idt_rva, 4)

	free(hint_rvas)
	free(lib_rvas)
	free(ilt_rvas)


void pe_finish_64():
	pe_emit_imports()

	# Entry function: _win_start (the win64 runtime startup, which
	# parses the real command line) when _main exists for it to chain
	# to; otherwise _main / main directly, mirroring elf_finish_64().
	int t = 0
	if (sym_address(c"_main") != 0):
		t = sym_address(c"_win_start")
	if (t == 0):
		t = sym_address(c"_main")
	if (t == 0):
		t = sym_address(c"main")
	if (t == 0):
		# 'w check' on a main-less library module: not an error, and the
		# entry call stays unpatched (the output is discarded)
		if (entry_optional == 0):
			error(c"Failed to find a _main() function. Did you import lib/testing?")
	if (t != 0):
		# rel32 = target - address of the instruction after the 5-byte call
		t = t - code_offset - entry_call_disp_pos - 4
		save_int32(code + entry_call_disp_pos, t)

	# Pad the file to the alignment so SizeOfRawData is exact, then patch
	# the size fields. RVA == file offset, so SizeOfImage is file size.
	int text_virtual_size = codepos - 4096
	pe_align(pe_file_align())
	int text_raw_size = codepos - 4096
	save_i(code + pe_opt_header_pos + 4, text_raw_size, 4) /* SizeOfCode */
	save_i(code + pe_opt_header_pos + 56, codepos, 4) /* SizeOfImage */
	save_i(code + pe_section_header_pos + 8, text_virtual_size, 4) /* VirtualSize */
	save_i(code + pe_section_header_pos + 16, text_raw_size, 4) /* SizeOfRawData */

	if (write(output_fd, code, codepos) != codepos):
		error(c"could not write output file")
