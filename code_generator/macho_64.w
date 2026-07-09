/*
Mach-O (Darwin) container writer for the arm64_darwin target — Stage 4 of
docs/projects/arm64.md.

The image is dyld-loaded, not static. macOS 26 kills dyld-less executables
outright: AppleSystemPolicy SIGKILLs any main binary whose header lacks
MH_DYLDLINK (so LC_UNIXTHREAD static binaries — including Apple's own
`ld -static` output — no longer run), and dyld in turn refuses to load a
binary without LC_UUID or without at least one LC_LOAD_DYLIB (libSystem).
So the writer emits the minimal dyld-blessed set, established empirically
on macOS 26.3: __PAGEZERO / __TEXT rx / __DATA rw / __LINKEDIT segments,
zeroed LC_SYMTAB + LC_DYSYMTAB (dyld's classic-relocation fallback walks
these; zero counts make it a no-op — omitting them crashes dyld), a
LC_LOAD_DYLINKER for /usr/lib/dyld, LC_UUID, LC_BUILD_VERSION, LC_MAIN,
and LC_LOAD_DYLIB /usr/lib/libSystem.B.dylib. The runtime itself stays
raw-syscall (no libSystem symbol is bound for it); dyld maps libSystem
from the shared cache and runs its initializers before _main. Programs
that use c_lib / extern get their imports bound through the classic
LC_DYLD_INFO_ONLY commands macho_dynamic.w appends.

The output is unsigned; `codesign -s -` on the Mac adds the ad-hoc
CodeDirectory until macho_sign.w (Phase 5) lands, and the 1024-byte pad
after the load commands is where macho_dynamic.w appends import load
commands, with the rest the headroom codesign_allocate needs to insert
LC_CODE_SIGNATURE without moving the text. Remember the vnode gotcha when
re-signing in place: the kernel caches signature state per inode, so a
previously-executed path must be replaced (write to a new file + rename),
not overwritten.

Addressing: the image is mandatorily PIE, so the kernel slides it and the
entry stub's rebase walk (shared with the arm64 ELF writer) patches every
absolute pointer recorded in the rebase table. That walk computes the slide
as runtime-adr minus linked-address-literal, so the *linked* addresses only
have to be self-consistent, not equal to the header vmaddrs: the writer
keeps the arm64 ELF's 32-bit nominal base 0x08048000 for code_offset /
data_offset / symbols (the compiler self-hosts as a 32-bit process, so
linked addresses must fit an int) while the load commands place __TEXT at
0x100000000. Both bases are 16 KB-aligned, so the effective slide is
page-congruent and adrp+add pairs stay correct. The only true 64-bit
values are in the load commands, emitted as lo/hi int32 pairs.

Layout invariant the header encodes: __DATA's vmaddr sits exactly
data_offset - code_offset (16 MB) above __TEXT's, so PC-relative distances
computed from the nominal bases match the mapped image.
*/
import code_generator.code_emitter
import code_generator.macho_dynamic


void error(char *s);                 /* diagnostics.w */
void define_asm_functions_arm64();   /* arm64_asm.w */
void a64(int w);                     /* arm64.w */
void arm64_entry_rebase_stub();      /* elf_arm64.w */
void arm64_emit_rebase_table();      /* elf_arm64.w */
int sym_address(char *s);            /* symbol_table.w */
int strlen(char *s);


# Mach-O segments load on 16 KB pages (arm64 macOS); file offsets and
# vmaddrs must stay congruent modulo this.
int macho_page_size():
	return 16384


# File positions of the __TEXT / __DATA / __LINKEDIT segment commands and
# of LC_MAIN's entryoff, so the finish pass patches sizes and offsets
# without hardcoded distances.
int macho_text_seg_pos
int macho_data_seg_pos
int macho_linkedit_seg_pos


# 16-byte fixed-width segment name field.
void macho_segname(char *s):
	int n = strlen(s)
	emit(n, s)
	emit_zeros(16 - n)


# LC_SEGMENT_64 (cmd 0x19, 72 bytes, no sections — the kernel, dyld and
# codesign only read segments). vmaddr/vmsize/fileoff/filesize are int64s
# emitted as lo/hi int32 pairs; size fields left 0 here are patched in
# finish.
void macho_segment_64(char *name, int vmaddr_lo, int vmaddr_hi, int vmsize_lo, int vmsize_hi, int prot):
	emit_int32(25)   /* LC_SEGMENT_64 */
	emit_int32(72)   /* cmdsize */
	macho_segname(name)
	emit_int32(vmaddr_lo)
	emit_int32(vmaddr_hi)
	emit_int32(vmsize_lo)
	emit_int32(vmsize_hi)
	emit_int64(0)    /* fileoff */
	emit_int64(0)    /* filesize */
	emit_int32(prot) /* maxprot */
	emit_int32(prot) /* initprot */
	emit_int32(0)    /* nsects */
	emit_int32(0)    /* flags */


void macho_start_arm64():
	# Nominal linked base: same 32-bit value the arm64 ELF writer uses, so
	# symbol addressing, the data split and the rebase machinery behave
	# identically (see the file comment for why this may differ from the
	# header's 0x100000000).
	base_code_offset = 134512640 /* 0x08048000 */
	code_offset = base_code_offset

	# The read-write data segment loads 16 MB above the image, matching
	# elf_start_arm64; global-variable storage is emitted here.
	data_offset = base_code_offset + 16777216 /* +0x1000000 */
	datapos = 0
	data_size = 4096
	data = malloc(data_size)

	# mach_header_64
	emit_int32(op(0xfe, 0xedfacf))  /* magic MH_MAGIC_64 */
	emit_int32(op(0x01, 0x00000c))  /* cputype CPU_TYPE_ARM64 */
	emit_int32(0)                   /* cpusubtype CPU_SUBTYPE_ARM64_ALL */
	emit_int32(2)                   /* filetype MH_EXECUTE */
	emit_int32(11)                  /* ncmds */
	emit_int32(552)                 /* sizeofcmds: 4*72+24+80+32+24+24+24+56 */
	emit_int32(op(0x00, 0x200085))  /* flags MH_NOUNDEFS | MH_DYLDLINK
	                                   | MH_TWOLEVEL | MH_PIE; without
	                                   MH_DYLDLINK the process is killed
	                                   by AppleSystemPolicy */
	emit_int32(0)                   /* reserved */

	# __PAGEZERO: 4 GB of unmapped low addresses (vmsize 0x100000000).
	macho_segment_64(c"__PAGEZERO", 0, 0, 0, 1, 0)

	# __TEXT covers the headers and all emitted code from file offset 0;
	# r-x (Apple Silicon refuses w+x). Sizes patched in finish.
	macho_text_seg_pos = codepos
	macho_segment_64(c"__TEXT", 0, 1, 0, 0, 5)

	# __DATA: rw globals + rebase table, exactly 16 MB above __TEXT to
	# match the nominal data_offset - code_offset distance.
	macho_data_seg_pos = codepos
	macho_segment_64(c"__DATA", 16777216, 1, 0, 0, 3)

	# __LINKEDIT: empty until signing; codesign_allocate grows it in place.
	macho_linkedit_seg_pos = codepos
	macho_segment_64(c"__LINKEDIT", 16777216, 1, 0, 0, 1)

	# LC_SYMTAB + LC_DYSYMTAB, all zero. dyld's fixup pass reads these
	# when a binary has no chained-fixups/dyld-info commands; zero counts
	# mean "nothing to relocate". Omitting the commands crashes dyld in
	# forEachRebase_Relocations.
	emit_int32(2)      /* LC_SYMTAB */
	emit_int32(24)     /* cmdsize */
	emit_zeros(16)     /* symoff nsyms stroff strsize */
	emit_int32(11)     /* LC_DYSYMTAB */
	emit_int32(80)     /* cmdsize */
	emit_zeros(72)

	# LC_LOAD_DYLINKER: /usr/lib/dyld (13 chars + NUL after the 12-byte
	# fixed part, padded to 32).
	emit_int32(14)     /* LC_LOAD_DYLINKER */
	emit_int32(32)     /* cmdsize */
	emit_int32(12)     /* name lc_str offset */
	emit_string(c"/usr/lib/dyld")
	emit_zeros(32 - 12 - 14)

	# LC_UUID: required by dyld. A fixed value is sufficient (dyld checks
	# presence, not uniqueness); a content hash can replace it when
	# macho_sign.w brings SHA-256 in Phase 5.
	emit_int32(27)     /* LC_UUID */
	emit_int32(24)     /* cmdsize */
	emit(16, c"w-arm64-darwin.0")

	# LC_BUILD_VERSION: platform macOS, minos = sdk = 12.0.
	emit_int32(50)     /* LC_BUILD_VERSION */
	emit_int32(24)     /* cmdsize */
	emit_int32(1)      /* platform PLATFORM_MACOS */
	emit_int32(786432) /* minos 12.0.0 (0x000c0000) */
	emit_int32(786432) /* sdk 12.0.0 */
	emit_int32(0)      /* ntools */

	# LC_MAIN: dyld calls the entry with the C ABI. entryoff is patched
	# once the pad below places the stub.
	emit_int32(op(0x80, 0x000028))  /* LC_MAIN */
	emit_int32(24)                  /* cmdsize */
	int macho_entry_off_pos = codepos
	emit_int64(0)                   /* entryoff, patched below */
	emit_int64(0)                   /* stacksize: default */

	# LC_LOAD_DYLIB /usr/lib/libSystem.B.dylib (26 chars + NUL after the
	# 24-byte fixed part, padded to 56). dyld refuses a main executable
	# with no dylibs; no symbol is bound from it.
	emit_int32(12)     /* LC_LOAD_DYLIB */
	emit_int32(56)     /* cmdsize */
	emit_int32(24)     /* name lc_str offset */
	emit_int32(2)      /* timestamp */
	emit_int32(65536)  /* current version 1.0.0 */
	emit_int32(65536)  /* compatibility version 1.0.0 */
	emit_string(c"/usr/lib/libSystem.B.dylib")
	emit_zeros(56 - 24 - 27)

	# Headerpad: free space after the load commands, where
	# macho_emit_dynamic appends LC_LOAD_DYLIB / LC_DYLD_INFO_ONLY for
	# imports and codesign_allocate inserts the 16-byte LC_CODE_SIGNATURE
	# without relinking.
	macho_pad_pos = codepos
	macho_pad_size = 1024
	emit_zeros(1024)

	# Entry stub, called by dyld as main(argc in x0, argv in x1, ...).
	# Adopt sp as the W evaluation stack (x28) and push argc then argv,
	# recreating the [argv][argc] top-of-stack contract the ELF entry
	# builds from the kernel stack. The rebase walk runs before _main so
	# every recorded data pointer is slid before user code reads it. x18
	# is reserved on Darwin and never touched.
	save_int64(code + macho_entry_off_pos, codepos)
	a64(op(0x91, 0x0003fc))   # mov x28, sp
	a64(op(0xf8, 0x1f8f80))   # str x0, [x28, #-8]!  (argc)
	a64(op(0xf8, 0x1f8f81))   # str x1, [x28, #-8]!  (argv)
	arm64_entry_rebase_stub()
	arm64_entry_bl_pos = codepos
	a64(op(0x94, 0x000000))   # bl _main  (offset patched in finish)
	# exit(_main's return value): Darwin exit is BSD syscall 1, number in
	# x16, svc #0x80. (Bypasses dyld's atexit machinery — W has none.)
	a64(op(0xd2, 0x800030))   # movz x16, #1
	a64(op(0xd4, 0x001001))   # svc #0x80

	define_asm_functions_arm64()


void macho_finish_arm64():
	# The rebase table lands at the end of the data segment, after every
	# data cell it lists has been reserved.
	arm64_emit_rebase_table()

	int t = sym_address(c"_main")
	if (t == 0):
		t = sym_address(c"main")
	if (t == 0):
		error(c"Failed to find a _main() function. Did you import lib/testing?")

	# Patch the bl: imm26 = (target - bl_vaddr) / 4.
	int bl_vaddr = code_offset + arm64_entry_bl_pos
	int offset = t - bl_vaddr
	save_int32(code + arm64_entry_bl_pos, op(0x94, 0x000000) | ((offset >> 2) & op(0x03, 0xffffff)))

	# Pad the text to a page boundary; __DATA's file offset must be
	# page-congruent with its vmaddr (both end up 16 KB-aligned).
	while ((codepos % macho_page_size()) != 0):
		emit_int8(0)
	int text_size = codepos

	# Pad the data segment to a page as well, so __LINKEDIT starts aligned.
	int data_pad = datapos % macho_page_size()
	if (data_pad != 0):
		emit_data_zeros(macho_page_size() - data_pad)
	int data_size_padded = datapos

	# Imports (c_lib / extern): append their load commands into the
	# headerpad and build the bind stream that becomes __LINKEDIT's
	# payload. A no-op for import-free programs.
	macho_emit_dynamic(text_size, data_size_padded)

	# __TEXT: fileoff 0, vmsize = filesize = padded text.
	save_int64(code + macho_text_seg_pos + 32, text_size)  /* vmsize */
	save_int64(code + macho_text_seg_pos + 48, text_size)  /* filesize */

	# __DATA follows the text in the file.
	save_int64(code + macho_data_seg_pos + 32, data_size_padded) /* vmsize */
	save_int64(code + macho_data_seg_pos + 40, text_size)        /* fileoff */
	save_int64(code + macho_data_seg_pos + 48, data_size_padded) /* filesize */

	# __LINKEDIT: tail of the file (vmaddr hi word 1 was emitted at start;
	# patch the low word past __DATA). Zero-length unless a bind stream
	# gives it a payload.
	save_int32(code + macho_linkedit_seg_pos + 24, 16777216 + data_size_padded)
	save_int64(code + macho_linkedit_seg_pos + 40, text_size + data_size_padded)
	if (macho_bind_size > 0):
		int linkedit_vm = macho_bind_size + macho_page_size() - 1
		linkedit_vm = linkedit_vm - (linkedit_vm % macho_page_size())
		save_int64(code + macho_linkedit_seg_pos + 32, linkedit_vm)       /* vmsize */
		save_int64(code + macho_linkedit_seg_pos + 48, macho_bind_size)   /* filesize */

	write(output_fd, code, codepos)
	write(output_fd, data, datapos)
	if (macho_bind_size > 0):
		write(output_fd, macho_bind_buf, macho_bind_size)
