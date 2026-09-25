import code_generator.code_emitter
import lib.sha256


# Machine independent:
void elf_header(int cpu_class):
	/* NIDENT: 16 bytes */
	emit(4, c"\x7f\x45\x4c\x46") /* magic */
	emit_int8(cpu_class) /* class: 0: none, 1: 32 bit, 2: 64 bit. */
	emit_int8(1) /* data encoding: 0: none, 1: Least signficiant, 2: Most significant */
	emit_int8(1) /* version: always 1 */
	emit_int8(0) /* OS ABI: 0: none (usually used), 1: HP-UX, 2: NetBSD, 3: Linux */
	emit_int8(0) /* ABI VERSION */
	emit_zeros(7) /* padding */



# --- GNU build-id note (issue #378) ---
# Every ELF image carries an NT_GNU_BUILD_ID note right after the program
# headers, described by its own PT_NOTE program header. Sitting in the
# first file page keeps it inside the page the kernel copies into a core
# dump (coredump_filter bit 4, "ELF headers", on by default), so
# tools/wcore.w can match a core against the binary that produced it.
# The id is a content hash of the finished image, not a random or
# timestamped value, so the self-host fixpoint (wv3 == wv4 == wv5) holds.

void elf_dyn_patch_phdr(int index, int type, int flags, int off, int size, int align);   /* elf_dynamic.w */

int build_id_note_pos   /* file offset of the note, 0 = not emitted */

# File offset of the ELF header the debugging symbols hang off: 0 for
# the ELF targets, where it is the image's own header. The PE writer
# embeds a stand-in ELF64 header at the start of .text (pe_start_64) so
# emit_debugging_symbols can reuse the ELF section layout unchanged;
# e_shoff and every sh_offset are then relative to that header, which
# is where lib/stack_trace.w finds it walking down from a code address.
int debug_elf_origin


# Index of the PT_NOTE program header; slots 0-1 are the text and data
# loads and 2-4 are reserved for the dynamic-linking headers.
int elf_build_id_phdr_index():
	return 5


int elf_build_id_size():
	return 20


# Note header (namesz, descsz, type) + "GNU\0" + the id.
int elf_build_id_note_size():
	return 16 + elf_build_id_size()


# Emit the note with a zero id at codepos and point the PT_NOTE program
# header at it. Called right after the program header table, before the
# entry stub; the writers add elf_build_id_note_size() to e_entry.
void elf_emit_build_id_note():
	build_id_note_pos = codepos
	emit_int32(4)                      /* namesz */
	emit_int32(elf_build_id_size())    /* descsz */
	emit_int32(3)                      /* type: NT_GNU_BUILD_ID */
	emit(3, c"GNU")
	emit_int8(0)
	emit_zeros(elf_build_id_size())
	elf_dyn_patch_phdr(elf_build_id_phdr_index(), 4, 4, build_id_note_pos, elf_build_id_note_size(), 4)


# Fill in the id: the first 20 bytes of sha256(sha256(image) ||
# sha256(data)), hashed while the id field is still zero. Skipped when the
# output is discarded ('w check').
void elf_fill_build_id():
	if ((build_id_note_pos == 0) || entry_optional):
		return
	char* digests = malloc(64)
	sha256(code, codepos, digests)
	int n = 32
	if (datapos > 0):
		sha256(data, datapos, &digests[32])
		n = 64
	char* id = malloc(32)
	sha256(digests, n, id)
	int i = 0
	while (i < elf_build_id_size()):
		code[build_id_note_pos + 16 + i] = id[i]
		i = i + 1
	free(id)
	free(digests)


# Write the finished image: code (padded to the data segment's page when
# there is one) then data, after the build-id is filled in.
void elf_write_image():
	elf_fill_build_id()
	if (write(output_fd, code, codepos) != codepos):
		error(c"could not write output file")
	if (datapos > 0):
		if (write(output_fd, data, datapos) != datapos):
			error(c"could not write output file")


# The static ELF writers' shared layout (elf_32.w, elf_64.w,
# elf_arm64.w): ELF32 (is64 = 0) or ELF64 fields, one ET_EXEC with the
# entry stub right after the program header table and the build-id note.

# Number of program headers: a read-execute text load, a read-write data
# load (W^X, docs/projects/wx_split.md), three slots reserved for
# PT_INTERP / PT_DYNAMIC when the program imports shared libraries (they
# stay PT_NULL, ignored, otherwise), and the build-id PT_NOTE.
int elf_phdr_count():
	return 6


void elf_emit_word(int is64, int v):
	if (is64):
		emit_int64(v)
	else:
		emit_int32(v)


void elf_save_word(int is64, int pos, int v):
	if (is64):
		save_int64(code + pos, v)
	else:
		save_int32(code + pos, v)


# The ELF header after the ident (elf_header); machine is 3 (x86), 62
# (x86-64) or 183 (AArch64).
void elf_header_fields(int machine, int is64):
	int header_size = 36 + 16
	int program_header_size = 32
	int section_header_size = 40
	if (is64):
		header_size = 48 + 16
		program_header_size = 56
		section_header_size = 64
	emit_int16(2) /* type: ET_EXEC */
	emit_int16(machine)
	emit_int32(1) /* version */
	elf_emit_word(is64, base_code_offset + header_size + program_header_size * elf_phdr_count() + elf_build_id_note_size()) /* entry */
	elf_emit_word(is64, header_size) /* program header offset */
	elf_emit_word(is64, 0) /* section header offset */
	emit_int32(0) /* flags */
	emit_int16(header_size) /* size of this elf header */
	emit_int16(program_header_size) /* size per program header */
	emit_int16(elf_phdr_count()) /* number of program headers */
	emit_int16(section_header_size) /* size per section header */
	emit_int16(0) /* number of section headers */
	emit_int16(0) /* section header string table index */


# One program header (type 0 NULL, 1 LOAD, ...; flags: RX text = 5, RW
# data = 6). offset/filesz/memsz are patched in elf_patch_load_segments.
void elf_phdr(int is64, int type, int flags):
	emit_int32(type)
	if (is64):
		emit_int32(flags)
	elf_emit_word(is64, 0) /* offset */
	elf_emit_word(is64, base_code_offset) /* vaddr */
	elf_emit_word(is64, base_code_offset) /* paddr */
	elf_emit_word(is64, 0) /* filesz */
	elf_emit_word(is64, 0) /* memsz */
	if (is64 == 0):
		emit_int32(flags)
	elf_emit_word(is64, 4096) /* align */


# phdr[0] text (R+X), phdr[1] data (R+W, patched in
# elf_patch_load_segments); the next three start as PT_NULL and are
# filled in by elf_emit_dynamic() when there are imports; the last is the
# build-id PT_NOTE, whose note follows the table.
void elf_phdr_table(int is64):
	phdr_table_pos = codepos
	elf_phdr(is64, 1, 5)
	elf_phdr(is64, 0, 6)
	for i in range(4):
		elf_phdr(is64, 0, 0)
	elf_emit_build_id_note()


# The ELF header, program headers and build-id note for machine.
void elf_image_headers(int machine, int is64):
	image_begin(134512640) /* 0x08048000 */
	elf_header(1 + is64)
	elf_header_fields(machine, is64)
	elf_phdr_table(is64)


# Patch the load segments' sizes and write the image. The text segment
# (phdr[0], R+X) is offset 0 at the base, codepos bytes. The data segment
# gets its own file page after the code; its vaddr (data_offset) is
# already page-aligned and 16 MB above base, so (vaddr - file_offset)
# stays page-congruent as the loader requires. Program header field k
# (1 offset, 2 vaddr, 3 paddr, 4 filesz, 5 memsz) sits k words in.
void elf_patch_load_segments(int is64):
	int w = 4
	int phdr_size = 32
	if (is64):
		w = 8
		phdr_size = 56
	elf_save_word(is64, phdr_table_pos + 4 * w, codepos)
	elf_save_word(is64, phdr_table_pos + 5 * w, codepos)
	if (datapos > 0):
		int data_file_off = (codepos + 4095) & (0 - 4096)
		int p = phdr_table_pos + phdr_size /* phdr[1] */
		save_int32(code + p, 1) /* p_type = PT_LOAD */
		elf_save_word(is64, p + w, data_file_off)
		elf_save_word(is64, p + 2 * w, data_offset)
		elf_save_word(is64, p + 3 * w, data_offset)
		elf_save_word(is64, p + 4 * w, datapos)
		elf_save_word(is64, p + 5 * w, datapos)
		# Pad the file to the data segment's page offset, then write code
		# and data as two segments in one file.
		while (codepos < data_file_off):
			emit_int8(0)
	elf_write_image()
