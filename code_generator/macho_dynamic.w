/*
Dynamic imports for the Mach-O writer (c_lib / extern on arm64_darwin).

Classic dyld-info encoding: one LC_LOAD_DYLIB per c_lib plus an
LC_DYLD_INFO_ONLY whose bind opcode stream tells dyld to write each
import's resolved address into its GOT slot in __DATA before LC_MAIN
runs. macOS 26.3 still accepts this pre-chained-fixups encoding for main
executables, including across an ad-hoc re-sign (established by the
probe binary, docs/projects/graphics.md).

The appended load commands land in the zero headerpad macho_64.w
reserves after its fixed command set, so nothing in the file moves; the
bind stream is appended after __DATA as the __LINKEDIT payload.

Division of labor with the entry stub's rebase walk: rebase_off/size
stay 0 and the stub keeps sliding the image's own absolute pointers;
dyld only binds imports. dyn_emit_import_slot reserves GOT slots as
plain data zeros that never enter the compiler rebase table, so the two
mechanisms touch disjoint cells — the walk cannot corrupt a slot dyld
has already bound.
*/
import code_generator.code_emitter
import code_generator.dynamic_registry


int strlen(char *s);
int strcmp(char *a, char *b);
void error(char *s);
int op(int msb, int low);   /* arm64.w */


# Set by macho_start_arm64: file position of the zero headerpad that
# follows the fixed load commands, and its byte size.
int macho_pad_pos
int macho_pad_size

# The bind opcode stream, written to the end of the file as __LINKEDIT's
# payload by macho_finish_arm64 (size stays 0 when nothing is imported).
char* macho_bind_buf
int macho_bind_size

# File offset of the next free load-command byte (past the fixed set and
# any dynamic-linking commands). macho_sign.w appends LC_CODE_SIGNATURE
# here. Initialized to macho_pad_pos in macho_start_arm64.
int macho_lc_end


# --- bind stream writer ---

void macho_bw_int8(int b):
	macho_bind_buf[macho_bind_size] = b
	macho_bind_size = macho_bind_size + 1


void macho_bw_uleb(int v):
	while (v >= 128):
		macho_bw_int8((v & 127) | 128)
		v = v >> 7
	macho_bw_int8(v)


void macho_bw_cstr(char *s):
	int i = 0
	while (s[i]):
		macho_bw_int8(s[i])
		i = i + 1
	macho_bw_int8(0)


# --- load-command writer (into the headerpad, which is already zeroed) ---

int macho_lc_pos

void macho_lc_int32(int v):
	save_int32(code + macho_lc_pos, v)
	macho_lc_pos = macho_lc_pos + 4


/*
Append the dynamic-linking load commands and build the bind stream.
Called from macho_finish_arm64 once text_size and data_size_padded are
final (they fix bind_off = the file position right after __DATA). A
no-op for programs that import nothing, keeping the static image
byte-identical.
*/
void macho_emit_dynamic(int text_size, int data_size_padded):
	if ((dyn_lib_count == 0) & (dyn_has_imports() == 0)):
		return

	macho_lc_pos = macho_pad_pos
	int added_cmds = 0

	# dyld ordinal for each c_lib: libSystem is already loaded by the
	# fixed command set as ordinal 1; every other library gets its own
	# LC_LOAD_DYLIB appended here, numbered upward from 2 in load-command
	# order (MH_TWOLEVEL binds name lookups to their ordinal's image).
	char* ordinals = 0
	if (dyn_lib_count > 0):
		ordinals = malloc(dyn_lib_count * 4)
	int next_ordinal = 2
	int i = 0
	while (i < dyn_lib_count):
		char* path = dyn_lib_name(i)
		if (strcmp(path, c"/usr/lib/libSystem.B.dylib") == 0):
			save_i(ordinals + i * 4, 1, 4)
		else:
			save_i(ordinals + i * 4, next_ordinal, 4)
			next_ordinal = next_ordinal + 1
			int len = strlen(path)
			int cmdsize = (24 + len + 1 + 7) & (0 - 8)
			macho_lc_int32(12)      /* LC_LOAD_DYLIB */
			macho_lc_int32(cmdsize)
			macho_lc_int32(24)      /* name lc_str offset */
			macho_lc_int32(2)       /* timestamp */
			macho_lc_int32(65536)   /* current version 1.0.0 */
			macho_lc_int32(65536)   /* compatibility version 1.0.0 */
			int ci = 0
			while (ci < len):
				code[macho_lc_pos + ci] = path[ci]
				ci = ci + 1
			macho_lc_pos = macho_lc_pos + (cmdsize - 24)  /* NUL + pad stay zero */
			added_cmds = added_cmds + 1
		i = i + 1

	if (dyn_has_imports()):
		# Upper bound: every import costs its name plus a fixed-size
		# opcode tail (ordinal + symbol + type + segment/offset + bind).
		int cap = 16
		i = 0
		while (i < dyn_import_count):
			cap = cap + strlen(dyn_import_name(i)) + 24
			i = i + 1
		macho_bind_buf = malloc(cap)
		macho_bind_size = 0

		i = 0
		while (i < dyn_import_count):
			int lib = dyn_import_get_lib(i)
			int ordinal = 1  /* extern before any c_lib: libSystem */
			if (lib >= 0):
				ordinal = load_i(ordinals + lib * 4, 4)
			if (ordinal <= 15):
				macho_bw_int8(16 | ordinal)  /* SET_DYLIB_ORDINAL_IMM */
			else:
				macho_bw_int8(32)            /* SET_DYLIB_ORDINAL_ULEB */
				macho_bw_uleb(ordinal)
			int flags = 0
			if (dyn_import_get_binding(i) == 2):
				flags = 1                    /* BIND_SYMBOL_FLAGS_WEAK_IMPORT */
			macho_bw_int8(64 | flags)       /* SET_SYMBOL_TRAILING_FLAGS_IMM */
			macho_bw_int8('_')              /* Mach-O C symbols carry a _ */
			macho_bw_cstr(dyn_import_name(i))
			macho_bw_int8(80 | 1)           /* SET_TYPE_IMM, BIND_TYPE_POINTER */
			macho_bw_int8(112 | 2)          /* SET_SEGMENT_AND_OFFSET_ULEB, __DATA = segment 2 */
			macho_bw_uleb(dyn_import_got_vaddr(i) - data_offset)
			macho_bw_int8(144)              /* DO_BIND */
			i = i + 1
		macho_bw_int8(0)                    /* DONE */

		# LC_DYLD_INFO_ONLY: binds only; rebasing stays with the entry
		# stub (see the file comment).
		macho_lc_int32(op(0x80, 0x000022))
		macho_lc_int32(48)  /* cmdsize */
		macho_lc_int32(0)   /* rebase_off */
		macho_lc_int32(0)   /* rebase_size */
		macho_lc_int32(text_size + data_size_padded)  /* bind_off */
		macho_lc_int32(macho_bind_size)               /* bind_size */
		macho_lc_int32(0)   /* weak_bind_off */
		macho_lc_int32(0)   /* weak_bind_size */
		macho_lc_int32(0)   /* lazy_bind_off */
		macho_lc_int32(0)   /* lazy_bind_size */
		macho_lc_int32(0)   /* export_off */
		macho_lc_int32(0)   /* export_size */
		added_cmds = added_cmds + 1

		# The image now has undefined (imported) symbols.
		save_int32(code + 24, op(0x00, 0x200084))  /* flags &= ~MH_NOUNDEFS */

	# Patch ncmds / sizeofcmds for the appended commands. codesign still
	# needs 16 headerpad bytes to insert LC_CODE_SIGNATURE.
	int used = macho_lc_pos - macho_pad_pos
	if (used > macho_pad_size - 16):
		error(c"Mach-O load commands overflow the headerpad")
	if (added_cmds > 0):
		save_int32(code + 16, load_int32(code + 16) + added_cmds)
		save_int32(code + 20, load_int32(code + 20) + used)

	# LC_CODE_SIGNATURE (macho_sign.w) appends after whatever we used.
	macho_lc_end = macho_lc_pos

	if (ordinals != 0):
		free(ordinals)
