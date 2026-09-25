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
LC_SYMTAB + LC_DYSYMTAB (dyld's classic-relocation fallback walks these;
omitting them crashes dyld), a LC_LOAD_DYLINKER for /usr/lib/dyld,
LC_UUID, LC_BUILD_VERSION, LC_MAIN, and LC_LOAD_DYLIB
/usr/lib/libSystem.B.dylib. The runtime itself stays
raw-syscall (no libSystem symbol is bound for it); dyld maps libSystem
from the shared cache and runs its initializers before _main. Programs
that use c_lib / extern get their imports bound through the classic
LC_DYLD_INFO_ONLY commands macho_dynamic.w appends.

The output is self-signed: macho_finish_arm64 appends an LC_CODE_SIGNATURE
into the 1024-byte headerpad (shared with macho_dynamic.w's import load
commands) and macho_sign.w writes an ad-hoc CodeDirectory into __LINKEDIT,
so a cross-compiled binary runs on the Mac with only a chmod +x — no host
`codesign` step. Remember the vnode gotcha when re-signing in place: the
kernel caches signature state per inode, so a previously-executed path must
be replaced (write to a new file + rename), not overwritten.

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
import code_generator.image
import code_generator.macho_dynamic
import code_generator.macho_sign
import lib.sha256


void error(char *s);                 /* diagnostics.w */
void define_asm_functions_arm64();   /* arm64_asm.w */
void a64(int w);                     /* arm64.w */
void macho_collect_symbols();       /* symbol_table.w */
void debug_line_emit();             /* dwarf.w */
void debug_info_emit_at(int text_start, int text_end); /* dwarf.w */
void debug_abbrev_emit();           /* dwarf.w */
void arm64_entry_rebase_stub();      /* elf_arm64.w */
void arm64_emit_rebase_table();      /* elf_arm64.w */
int sym_address(char *s);            /* symbol_table.w */
int strlen(char *s);


# Mach-O segments load on 16 KB pages (arm64 macOS); file offsets and
# vmaddrs must stay congruent modulo this.
const int macho_page_size = 16384


# File positions of the __TEXT / __DATA / __LINKEDIT segment commands and
# of LC_MAIN's entryoff, so the finish pass patches sizes and offsets
# without hardcoded distances.
int macho_text_seg_pos
int macho_data_seg_pos
int macho_linkedit_seg_pos
int macho_symtab_cmd_pos
int macho_uuid_pos
int macho_text_start


# The symbol table (issue #378): one nlist_64 per defined W function, so
# lldb, atos and the crash reporter can name code addresses. Symbols
# belong to the one section, __TEXT,__text, and are all local (N_SECT
# without N_EXT), so dyld sees nothing to export. Names carry the C
# convention's leading underscore, which debuggers strip for display.
# Built in memory and written into __LINKEDIT between the bind stream and
# the code signature, the order ld64 uses.
char* macho_sym_buf
int macho_sym_count
char* macho_str_buf
int macho_str_size
int macho_text_limit


# Size both buffers for up to cap bytes of symbol names (the caller
# passes the whole symbol table's size, which bounds both).
void macho_symbols_begin(int cap):
	macho_sym_buf = malloc(cap)
	macho_sym_count = 0
	macho_str_buf = malloc(cap + 8)
	macho_str_buf[0] = 0
	macho_str_size = 1


# Record one function symbol at a nominal (0x08048000-based) address.
# Addresses outside the finished text are skipped.
void macho_sym_add(char* name, int address):
	int offset = address - base_code_offset
	if ((offset < macho_text_start) || (offset >= macho_text_limit)):
		return
	char* entry = macho_sym_buf + macho_sym_count * 16
	save_int32(entry, macho_str_size)  /* n_strx */
	entry[4] = 14                      /* n_type N_SECT */
	entry[5] = 1                       /* n_sect: __text */
	entry[6] = 0                       /* n_desc */
	entry[7] = 0
	# n_value: __TEXT maps at 0x100000000, so the vmaddr is the text
	# offset in the low word and 1 in the high word.
	save_int32(entry + 8, offset)
	save_int32(entry + 12, 1)
	macho_sym_count = macho_sym_count + 1
	macho_str_buf[macho_str_size] = '_'
	int n = strlen(name)
	for i in range(n + 1):
		macho_str_buf[macho_str_size + 1 + i] = name[i]
	macho_str_size = macho_str_size + n + 2


# 16-byte fixed-width segment name field.
void macho_segname(char *s):
	int n = strlen(s)
	emit(n, s)
	emit_zeros(16 - n)


# An S_ATTR_DEBUG section header in __TEXT; addr/size/offset are
# patched by macho_debug_section_patch in finish.
void macho_debug_section(char* name):
	macho_segname(name)
	macho_segname(c"__TEXT")
	emit_int64(0)                   /* addr, patched */
	emit_int64(0)                   /* size, patched */
	emit_int32(0)                   /* offset, patched */
	emit_int32(0)                   /* align: 2^0 */
	emit_int32(0)                   /* reloff */
	emit_int32(0)                   /* nreloc */
	emit_int32(op(0x02, 0x000000))  /* S_ATTR_DEBUG */
	emit_zeros(12)                  /* reserved1-3 */


# Point section `index` (0 = __text) at [start, codepos) of the file,
# which __TEXT maps at 0x100000000 + offset.
void macho_debug_section_patch(int index, int start):
	int sect = macho_text_seg_pos + 72 + index * 80
	save_int64(code + sect + 32, start)               /* addr lo */
	save_int32(code + sect + 36, 1)                   /* addr hi */
	save_int64(code + sect + 40, codepos - start)     /* size */
	save_int32(code + sect + 48, start)               /* offset */


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
	# The read-write data segment loads 16 MB above the image (image_begin),
	# matching elf_start_arm64.
	image_begin(134512640) /* 0x08048000 */

	# mach_header_64
	emit_int32(op(0xfe, 0xedfacf))  /* magic MH_MAGIC_64 */
	emit_int32(op(0x01, 0x00000c))  /* cputype CPU_TYPE_ARM64 */
	# Plain arm64 processes run with the PAC keys disabled (pacia/autia
	# execute as no-ops), so --pac=full marks the slice arm64e:
	# CPU_SUBTYPE_ARM64E with the versioned-ABI bit and ptrauth ABI
	# version 1 (0x81000002 — matches what clang -arch arm64e emits for
	# a main executable on macOS 26), the ABI macOS 26 opened to third
	# parties. Nothing inside the binary follows Apple's signing schema —
	# the mark only turns the keys on for W's own convention.
	if (arm64_pac == 2):
		emit_int32(op(0x81, 0x000002))  /* CPU_SUBTYPE_ARM64E, ptrauth ABI v1 */
	else:
		emit_int32(0)               /* cpusubtype CPU_SUBTYPE_ARM64_ALL */
	emit_int32(2)                   /* filetype MH_EXECUTE */
	emit_int32(11)                  /* ncmds */
	emit_int32(872)                 /* sizeofcmds: 4*72+4*80+24+80+32+24+24+24+56 */
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
	# Four sections, all ranges patched in finish: __text spans the code
	# after the headerpad (symbols need a section to belong to, n_sect
	# 1); __debug_line, __debug_info and __debug_abbrev hold the DWARF
	# line table and its compile unit, appended after the code inside
	# __TEXT so dyld maps them and the signature covers them.
	# lib/stack_trace.w finds __debug_line by name for file:line in
	# traces; lldb uses all three.
	save_int32(code + macho_text_seg_pos + 4, 392)  /* cmdsize: 72 + 4*80 */
	save_int32(code + macho_text_seg_pos + 64, 4)   /* nsects */
	macho_segname(c"__text")
	macho_segname(c"__TEXT")
	emit_int64(0)                   /* addr, patched */
	emit_int64(0)                   /* size, patched */
	emit_int32(0)                   /* offset, patched */
	emit_int32(2)                   /* align: 2^2 */
	emit_int32(0)                   /* reloff */
	emit_int32(0)                   /* nreloc */
	emit_int32(op(0x80, 0x000400))  /* S_ATTR_PURE_INSTRUCTIONS | S_ATTR_SOME_INSTRUCTIONS */
	emit_zeros(12)                  /* reserved1-3 */
	macho_debug_section(c"__debug_line")
	macho_debug_section(c"__debug_info")
	macho_debug_section(c"__debug_abbrev")

	# __DATA: rw globals + rebase table, exactly 16 MB above __TEXT to
	# match the nominal data_offset - code_offset distance.
	macho_data_seg_pos = codepos
	macho_segment_64(c"__DATA", 16777216, 1, 0, 0, 3)

	# __LINKEDIT: bind stream + ad-hoc signature; sizes patched in finish.
	macho_linkedit_seg_pos = codepos
	macho_segment_64(c"__LINKEDIT", 16777216, 1, 0, 0, 1)

	# LC_SYMTAB + LC_DYSYMTAB, patched in finish to describe the local
	# function symbols. dyld's fixup pass reads these when a binary has no
	# chained-fixups/dyld-info commands; zero relocation counts mean
	# "nothing to relocate". Omitting the commands crashes dyld in
	# forEachRebase_Relocations.
	macho_symtab_cmd_pos = codepos
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

	# LC_UUID: required by dyld, and what lldb and crash tools match a
	# binary by. Filled in finish with a hash of the finished image, the
	# Mach-O counterpart of the ELF writers' GNU build-id.
	emit_int32(27)     /* LC_UUID */
	emit_int32(24)     /* cmdsize */
	macho_uuid_pos = codepos
	emit_zeros(16)

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
	# imports and macho_finish appends the 16-byte LC_CODE_SIGNATURE.
	macho_pad_pos = codepos
	macho_pad_size = 1024
	macho_lc_end = macho_pad_pos
	emit_zeros(1024)

	# Entry stub, called by dyld as main(argc in x0, argv in x1, ...).
	# Adopt sp as the W evaluation stack (x28) and push argc then argv,
	# recreating the [argv][argc] top-of-stack contract the ELF entry
	# builds from the kernel stack. The rebase walk runs before _main so
	# every recorded data pointer is slid before user code reads it. x18
	# is reserved on Darwin and never touched.
	save_int64(code + macho_entry_off_pos, codepos)
	macho_text_start = codepos
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

	arm64_patch_entry_bl(entry_symbol(0))

	# __text: from the entry stub to the end of the code.
	macho_text_limit = codepos
	save_int64(code + macho_text_seg_pos + 72 + 32, macho_text_start)      /* addr lo */
	save_int32(code + macho_text_seg_pos + 72 + 36, 1)                     /* addr hi */
	save_int64(code + macho_text_seg_pos + 72 + 40, codepos - macho_text_start)  /* size */
	save_int32(code + macho_text_seg_pos + 72 + 48, macho_text_start)      /* offset */

	# The DWARF line table and its compile unit, right after the code.
	int text_end = codepos
	int debug_start = codepos
	debug_line_emit()
	macho_debug_section_patch(1, debug_start)
	debug_start = codepos
	debug_info_emit_at(macho_text_start, text_end)
	macho_debug_section_patch(2, debug_start)
	debug_start = codepos
	debug_abbrev_emit()
	macho_debug_section_patch(3, debug_start)

	# Pad the text to a page boundary; __DATA's file offset must be
	# page-congruent with its vmaddr (both end up 16 KB-aligned).
	while ((codepos % macho_page_size) != 0):
		emit_int8(0)
	int text_size = codepos

	# Pad the data segment to a page as well, so __LINKEDIT starts aligned.
	int data_pad = datapos % macho_page_size
	if (data_pad != 0):
		emit_data_zeros(macho_page_size - data_pad)
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
	# patch the low word past __DATA). It holds the optional bind stream
	# and the code signature; final sizes are patched in the signing step.
	int linkedit_fileoff = text_size + data_size_padded
	save_int32(code + macho_linkedit_seg_pos + 24, 16777216 + data_size_padded)
	save_int64(code + macho_linkedit_seg_pos + 40, linkedit_fileoff)

	# The symbol table follows the bind stream (8-byte aligned), then its
	# string table (padded to 8).
	macho_collect_symbols()
	int symoff = linkedit_fileoff + ((macho_bind_size + 7) & (0 - 8))
	int stroff = symoff + macho_sym_count * 16
	int strsize = (macho_str_size + 7) & (0 - 8)
	int raw_end = linkedit_fileoff + macho_bind_size
	if (macho_sym_count > 0):
		raw_end = stroff + strsize
		save_int32(code + macho_symtab_cmd_pos + 8, symoff)
		save_int32(code + macho_symtab_cmd_pos + 12, macho_sym_count)
		save_int32(code + macho_symtab_cmd_pos + 16, stroff)
		save_int32(code + macho_symtab_cmd_pos + 20, strsize)
		# LC_DYSYMTAB: every symbol local; no external or undefined ones.
		save_int32(code + macho_symtab_cmd_pos + 24 + 12, macho_sym_count)  /* nlocalsym */
		save_int32(code + macho_symtab_cmd_pos + 24 + 16, macho_sym_count)  /* iextdefsym */
		save_int32(code + macho_symtab_cmd_pos + 24 + 24, macho_sym_count)  /* iundefsym */

	# Sign the image ad-hoc. The signature sits at a 16-byte-aligned offset
	# past the symbol table; everything before it (headers, code, data,
	# bind, symbols, alignment padding) is hashed, so this must run after
	# every other byte and load command — including the ones patched just
	# above — is final.
	int code_limit = (raw_end + 15) & (0 - 16)
	char* ident = c"w"
	int sig_size = macho_sig_length(code_limit, ident)

	# LC_CODE_SIGNATURE into the headerpad (16 bytes reserved by
	# macho_emit_dynamic's overflow check). dataoff = codeLimit.
	if (macho_lc_end + 16 > macho_pad_pos + macho_pad_size):
		error(c"Mach-O headerpad has no room for LC_CODE_SIGNATURE")
	save_int32(code + macho_lc_end + 0, 29)          /* LC_CODE_SIGNATURE */
	save_int32(code + macho_lc_end + 4, 16)          /* cmdsize */
	save_int32(code + macho_lc_end + 8, code_limit)  /* dataoff */
	save_int32(code + macho_lc_end + 12, sig_size)   /* datasize */
	save_int32(code + 16, load_int32(code + 16) + 1)   /* ncmds++ */
	save_int32(code + 20, load_int32(code + 20) + 16)  /* sizeofcmds += 16 */

	# __LINKEDIT now spans the bind stream + alignment pad + signature.
	int linkedit_filesize = code_limit + sig_size - linkedit_fileoff
	int linkedit_vm = linkedit_filesize + macho_page_size - 1
	linkedit_vm = linkedit_vm - (linkedit_vm % macho_page_size)
	save_int64(code + macho_linkedit_seg_pos + 32, linkedit_vm)          /* vmsize */
	save_int64(code + macho_linkedit_seg_pos + 48, linkedit_filesize)    /* filesize */

	# Assemble the hashed file image contiguously (code buffer, then the
	# separate data buffer, then the bind stream, then alignment zeros) and
	# hash it into the CodeDirectory.
	char* img = malloc(code_limit)
	for p in range(text_size):
		img[p] = code[p]
	for di in range(data_size_padded):
		img[text_size + di] = data[di]
	for zi in range(linkedit_fileoff, code_limit):
		img[zi] = 0
	int bi = 0
	while (bi < macho_bind_size):
		img[linkedit_fileoff + bi] = macho_bind_buf[bi]
		bi = bi + 1
	int si = 0
	while (si < macho_sym_count * 16):
		img[symoff + si] = macho_sym_buf[si]
		si = si + 1
	si = 0
	while ((macho_sym_count > 0) && (si < macho_str_size)):
		img[stroff + si] = macho_str_buf[si]
		si = si + 1

	# LC_UUID: the first 16 bytes of sha256 over the image with the UUID
	# still zero, so identical inputs give identical UUIDs.
	char* digest = malloc(32)
	sha256(img, code_limit, digest)
	for ui in range(16):
		img[macho_uuid_pos + ui] = digest[ui]
	free(digest)

	macho_build_signature(img, code_limit, text_size, ident)

	if (write(output_fd, img, code_limit) != code_limit):
		error(c"could not write output file")
	if (write(output_fd, macho_sig_buf, macho_sig_size) != macho_sig_size):
		error(c"could not write output file")
	free(img)
