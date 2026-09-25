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
